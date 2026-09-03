// Orchestrates a measurement: generate the sweep, play+capture through the audio
// backend, deconvolve to a frequency response, and (for EQ) fit parametric bands.
// Ties together the native DSP (Rewcore) and the audio backend (mock or native).
//
// The heavy DSP runs in a background isolate. It must: a measurement is a pair of
// ~500k-point FFTs and takes several seconds on a phone, and Android declares the
// app "not responding" after about five seconds of a blocked main thread — which
// is exactly what happened the first time this was used in the car.
import 'dart:isolate';
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

  // Sweeps are cached per band; regenerating a 3 s sweep on every measurement of
  // an averaged set would be wasteful.
  final Map<String, Future<Float64List>> _sweeps = {};

  /// The stimulus for [band]. The swept range is deliberately a little wider than
  /// the analysed range, so the sweep's fade-in/out never lands on a band edge.
  Future<Float64List> sweepFor(SweepBand band) {
    return _sweeps.putIfAbsent(band.label, () {
      final fs = config.fs;
      final dur = config.durationSec;
      final f1 = (band.fLo / 1.1).clamp(10.0, fs / 2);
      final f2 = (band.fHi * 1.1).clamp(20.0, fs * 0.45);
      return Isolate.run(() => Rewcore.open()
          .generateSweep(fs: fs, f1: f1, f2: f2, durationSec: dur));
    });
  }

  Future<MicInfo> micStatus() => _audio.micStatus();

  // --- live monitoring / test signals (manual checks, not measurement) ---
  Stream<MicLevel> get inputLevels => _audio.inputLevels;
  Future<void> startInputLevel() => _audio.startInputLevel();
  Future<void> stopInputLevel() => _audio.stopInputLevel();
  Future<void> stopTone() => _audio.stopTone();

  /// Play a looping band-limited pink-noise block for centring by ear.
  Future<void> startCentringNoise({double fLo = 200, double fHi = 4000}) async {
    final fs = config.fs;
    final noise = await Isolate.run(() => Rewcore.open()
        .generateNoise(fs: fs, durationSec: 2, fLo: fLo, fHi: fHi, amplitude: 0.3));
    await _audio.startTone(samples: noise, fs: fs);
  }

  /// Run a single capture over [band]: magnitude response plus captured level.
  Future<Measurement> measureOnce({SweepBand band = SweepBand.full}) async {
    final stimulus = await sweepFor(band);
    final recorded =
        await _audio.playSweepAndCapture(sweep: stimulus, fs: config.fs);

    // Everything below is seconds of FFT work, so it happens off the main
    // isolate; blocking the UI thread here is what triggers an ANR.
    final fs = config.fs;
    final smooth = config.smoothFrac;
    final pts = config.points;
    final fLo = band.fLo;
    final fHi = band.fHi;
    final cal = calibration;

    return Isolate.run(() {
      final core = Rewcore.open();
      final level = core.rmsDbfs(recorded);
      final response = core.measureFr(
        emitted: stimulus,
        recorded: recorded,
        fs: fs,
        fMin: fLo,
        fMax: fHi,
        smoothFrac: smooth,
        points: pts,
        calibration: cal,
      );
      return Measurement(response: response, levelDbfs: level);
    });
  }

  /// Recommend crossover edges from a single driver's measured response.
  CrossoverRecommendation recommendCrossover(FreqResponse driver) =>
      _core.recommendCrossover(driver);

  /// Run [n] captures (e.g. around the listening position) and power-average them.
  Future<Measurement> measureAveraged(int n,
      {SweepBand band = SweepBand.full}) async {
    final all = <FreqResponse>[];
    var levelSum = 0.0;
    for (var i = 0; i < n; i++) {
      final m = await measureOnce(band: band);
      all.add(m.response);
      levelSum += m.levelDbfs;
    }
    return Measurement(
        response: _powerAverage(all), levelDbfs: levelSum / n);
  }

  Future<EqResult> fitEq(FreqResponse measured,
      {int maxBands = 10, SweepBand band = SweepBand.full}) {
    final fs = config.fs;
    final fLo = band.fLo;
    final fHi = band.fHi;
    return Isolate.run(() => Rewcore.open().fitPeqFlat(
          measured: measured,
          fs: fs,
          fMin: fLo,
          fMax: fHi,
          maxBands: maxBands,
        ));
  }

  static FreqResponse _powerAverage(List<FreqResponse> ms) {
    if (ms.isEmpty) return FreqResponse([], []);
    // Averaging power across spatially separated captures discards phase, but a
    // single capture has nothing to average — keep its phase.
    if (ms.length == 1) return ms.first;
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
