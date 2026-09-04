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
import '../models/mic_calibration.dart';

/// Number of spectra in the running average, offered the way REW offers it.
const List<int> kRtaAverageCounts = [1, 2, 4, 8, 16, 32, 64];

/// FFT lengths worth offering. Longer resolves closer modes but responds more
/// slowly, because each block covers more time.
const List<int> kRtaFftSizes = [4096, 8192, 16384, 32768, 65536];

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
  RtaAveraging averaging = RtaAveraging.exponential;
  int averageCount = 8;
  bool octaveBands = true;
  double bandsPerOctave = 24;
  SplWeighting weighting = SplWeighting.z;
  int fftSize = 16384;

  /// The UMIK-1's calibration, so the display shows the car rather than the
  /// microphone. Set from the wizard when a file has been loaded.
  MicCalibration? calibration;

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
        fftSize: fftSize,
        averaging: averaging,
        averageCount: averageCount,
        smoothFrac: smoothFrac,
        octaveBands: octaveBands,
        bandsPerOctave: bandsPerOctave,
        weighting: weighting,
        pinkWeighted: pinkWeighted,
        calibration: calibration,
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
    RtaAveraging? averaging,
    int? averageCount,
    bool? pinkWeighted,
    double? smoothFrac,
    bool? showPeakHold,
    bool? octaveBands,
    double? bandsPerOctave,
    SplWeighting? weighting,
    int? fftSize,
  }) async {
    this.averaging = averaging ?? this.averaging;
    this.averageCount = averageCount ?? this.averageCount;
    this.pinkWeighted = pinkWeighted ?? this.pinkWeighted;
    this.smoothFrac = smoothFrac ?? this.smoothFrac;
    this.showPeakHold = showPeakHold ?? this.showPeakHold;
    this.octaveBands = octaveBands ?? this.octaveBands;
    this.bandsPerOctave = bandsPerOctave ?? this.bandsPerOctave;
    this.weighting = weighting ?? this.weighting;
    this.fftSize = fftSize ?? this.fftSize;

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
