// Drives the real-time analyser from the live microphone stream.
//
// Kept separate from the wizard: the RTA is not part of the tuning sequence,
// it is an instrument you pick up when something needs looking at — a rattle
// while you tap the trim, a mode while you move the mic, or simply how much
// engine and road noise you are fighting before trusting any measurement.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/audio_backend.dart';
import '../ffi/rewcore.dart';
import '../models/measurement.dart';

/// How the spectrum is presented. These mirror what REW offers, and each
/// answers a different question.
enum RtaSpeed {
  fast(0.6, 'Fast', 'Follows the sound closely. Use it while moving the mic '
      'or hunting a rattle.'),
  medium(0.25, 'Medium', 'A steadier picture. The usual choice.'),
  slow(0.08, 'Slow', 'Heavily averaged, for judging overall balance against a '
      'target rather than watching it move.');

  const RtaSpeed(this.averaging, this.label, this.description);
  final double averaging;
  final String label;
  final String description;
}

class RtaController extends ChangeNotifier {
  RtaController({required this.audio, required this.core});

  final AudioBackend audio;
  final Rewcore core;

  RtaSession? _session;
  StreamSubscription<MicLevel>? _sub;

  bool get running => _session != null;

  FreqResponse spectrum = FreqResponse(const [], const []);
  FreqResponse peak = FreqResponse(const [], const []);
  double levelDbfs = -240;
  String? error;

  bool showPeakHold = true;
  bool pinkWeighted = true;
  double smoothFrac = 6;
  RtaSpeed speed = RtaSpeed.medium;

  /// SPL offset from the wizard's calibration, when one has been done, so the
  /// readout is a real number rather than dBFS.
  double? splOffsetDb;

  double? get splDb => splOffsetDb == null ? null : levelDbfs + splOffsetDb!;

  // Drawing every block would repaint far faster than anyone can read. Audio is
  // still pushed into the analyser at full rate — only the redraw is throttled.
  DateTime _lastPaint = DateTime.fromMillisecondsSinceEpoch(0);
  static const _paintInterval = Duration(milliseconds: 120);

  Future<void> start() async {
    if (running) return;
    error = null;
    try {
      _session = core.openRta(
        fs: 48000,
        fftSize: 16384,
        averaging: speed.averaging,
        smoothFrac: smoothFrac,
        pinkWeighted: pinkWeighted,
      );
      _sub = audio.inputLevels.listen(_onLevel, onError: (Object e) {
        error = '$e';
        notifyListeners();
      });
      await audio.startInputLevel(withSamples: true);
    } catch (e) {
      error = '$e';
      await stop();
    }
    notifyListeners();
  }

  void _onLevel(MicLevel level) {
    final session = _session;
    if (session == null || !session.isOpen) return;

    levelDbfs = level.rmsDb;
    final samples = level.samples;
    if (samples != null && samples.isNotEmpty) {
      session.push(samples);
    }

    final now = DateTime.now();
    if (now.difference(_lastPaint) < _paintInterval) return;
    _lastPaint = now;

    spectrum = session.spectrum();
    if (showPeakHold) peak = session.peakHold();
    notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await audio.stopInputLevel();
    } catch (_) {
      // Stopping a stream that has already gone is not an error worth showing.
    }
    _session?.close();
    _session = null;
    notifyListeners();
  }

  void resetPeak() {
    _session?.reset(averaging: false, peakHold: true);
    peak = FreqResponse(const [], const []);
    notifyListeners();
  }

  /// Changing any of these rebuilds the analyser, since fftSize, weighting and
  /// smoothing are fixed for its lifetime.
  Future<void> reconfigure({
    RtaSpeed? speed,
    bool? pinkWeighted,
    double? smoothFrac,
    bool? showPeakHold,
  }) async {
    this.speed = speed ?? this.speed;
    this.pinkWeighted = pinkWeighted ?? this.pinkWeighted;
    this.smoothFrac = smoothFrac ?? this.smoothFrac;
    this.showPeakHold = showPeakHold ?? this.showPeakHold;

    if (running) {
      await stop();
      await start();
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _session?.close();
    _session = null;
    super.dispose();
  }
}
