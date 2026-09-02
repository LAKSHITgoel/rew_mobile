// Orchestrates a measurement: generate the sweep, play+capture through the audio
// backend, deconvolve to a frequency response, and (for EQ) fit parametric bands.
// Ties together the native DSP (Rewcore) and the audio backend (mock or native).
import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/audio_backend.dart';
import '../ffi/rewcore.dart';
import '../models/measurement.dart';
import '../models/mic_calibration.dart';

class MeasurementConfig {
  const MeasurementConfig({
    this.fs = 48000,
    // Sweep slightly WIDER than the analysed band: the sweep's fade in/out kills
    // energy at its own extremes, so if f1/f2 equalled fMin/fMax the response at the
    // band edges would be a fade artifact rather than a measurement.
    this.f1 = 18,
    this.f2 = 22000,
    this.durationSec = 3,
    this.fMin = 20,
    this.fMax = 20000,
    this.smoothFrac = 24,
    this.points = 96,
  });

  final double fs, f1, f2, durationSec, fMin, fMax, smoothFrac;
  final int points;
}

class MeasurementService {
  MeasurementService(this._core, this._audio, {this.config = const MeasurementConfig()});

  final Rewcore _core;
  final AudioBackend _audio;
  final MeasurementConfig config;

  /// UMIK-1 calibration applied to every measurement (null = none loaded).
  MicCalibration? calibration;

  Float64List? _sweep;
  Float64List get sweep =>
      _sweep ??= _core.generateSweep(
        fs: config.fs,
        f1: config.f1,
        f2: config.f2,
        durationSec: config.durationSec,
      );

  Future<MicInfo> micStatus() => _audio.micStatus();

  /// Run a single capture and return its magnitude response.
  Future<FreqResponse> measureOnce() async {
    final recorded =
        await _audio.playSweepAndCapture(sweep: sweep, fs: config.fs);
    return _core.measureFr(
      emitted: sweep,
      recorded: recorded,
      fs: config.fs,
      fMin: config.fMin,
      fMax: config.fMax,
      smoothFrac: config.smoothFrac,
      points: config.points,
      calibration: calibration,
    );
  }

  /// Recommend crossover edges from a single driver's measured response.
  CrossoverRecommendation recommendCrossover(FreqResponse driver) =>
      _core.recommendCrossover(driver);

  /// Run [n] captures (e.g. around the listening position) and power-average them.
  Future<FreqResponse> measureAveraged(int n) async {
    final all = <FreqResponse>[];
    for (var i = 0; i < n; i++) {
      all.add(await measureOnce());
    }
    return _powerAverage(all);
  }

  EqResult fitEq(FreqResponse measured, {int maxBands = 10}) {
    return _core.fitPeqFlat(
      measured: measured,
      fs: config.fs,
      fMin: config.fMin,
      fMax: config.fMax,
      maxBands: maxBands,
    );
  }

  static FreqResponse _powerAverage(List<FreqResponse> ms) {
    if (ms.isEmpty) return FreqResponse([], []);
    final freq = ms.first.freqHz;
    final mag = List<double>.filled(freq.length, 0);
    for (var i = 0; i < freq.length; i++) {
      var power = 0.0;
      for (final m in ms) {
        final lin = math.pow(10, m.magDb[i] / 20).toDouble();
        power += lin * lin;
      }
      power /= ms.length;
      mag[i] = 10 * (math.log(power <= 0 ? 1e-24 : power) / math.ln10);
    }
    return FreqResponse(List<double>.from(freq), mag);
  }
}
