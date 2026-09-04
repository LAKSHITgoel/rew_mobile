// Orchestrates a measurement: generate the sweep, play+capture through the audio
// backend, deconvolve to a frequency response, and (for EQ) fit parametric bands.
// Ties together the native DSP (Rewcore) and the audio backend (mock or native).
//
// The heavy DSP runs in a background isolate. It must: a measurement is a pair of
// ~500k-point FFTs and takes several seconds on a phone, and Android declares the
// app "not responding" after about five seconds of a blocked main thread — which
// is exactly what happened the first time this was used in the car.
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/audio_backend.dart';
import '../ffi/rewcore.dart';
import '../models/measurement.dart';
import '../models/mic_calibration.dart';

/// Which part of a measurement is running, so the app can say what the silence
/// or the sweep it is hearing actually means.
enum MeasurePhase {
  sweep('Playing the sweep', 'Keep the microphone still.'),
  noiseFloor('Measuring the background noise',
      'Nothing will play — stay quiet for a moment.');

  const MeasurePhase(this.title, this.detail);
  final String title;
  final String detail;
}

/// Raised when a capture is not fit to be measured. Carries the assessment so
/// the UI can say exactly what went wrong and what to change.
class BadCaptureException implements Exception {
  BadCaptureException(this.quality);
  final CaptureQuality quality;

  @override
  String toString() => quality.problem ?? 'The recording could not be used.';
}

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
    int? points,
  }) : points = points ?? 0;

  final double fs, f1, f2, durationSec, fMin, fMax, smoothFrac;

  /// 0 means "derive it from the smoothing", which is almost always what you
  /// want; a fixed count is kept for tests.
  final int points;

  /// How many log-spaced points to report.
  ///
  /// This used to be a flat 96 across 20 Hz – 20 kHz: under 10 points per
  /// octave, coarser than the 1/24-octave smoothing it was displaying, so the
  /// curve was resolution-limited by the plotting grid rather than by the
  /// measurement. Detail that REW shows was being averaged away before it was
  /// ever drawn.
  ///
  /// Sampling at twice the smoothing width keeps every feature the smoothing
  /// preserves — 1/24 octave over ~10 octaves gives ~480 points.
  int get gridPoints {
    if (points > 0) return points;
    final octaves = (math.log(fMax / fMin) / math.ln2).abs();
    final perOctave = 2.0 * (smoothFrac <= 0 ? 48.0 : smoothFrac);
    return (octaves * perOctave).round().clamp(96, 2400);
  }

  MeasurementConfig copyWith({double? smoothFrac, int? points}) =>
      MeasurementConfig(
        fs: fs,
        f1: f1,
        f2: f2,
        durationSec: durationSec,
        fMin: fMin,
        fMax: fMax,
        smoothFrac: smoothFrac ?? this.smoothFrac,
        points: points ?? (this.points > 0 ? this.points : null),
      );
}

/// Display/analysis smoothing, in fractions of an octave. REW offers the same
/// ladder; 1/24 is the usual working choice for car audio, 1/3 shows only the
/// broad tonal balance you would actually EQ.
enum Smoothing {
  none(0, 'None'),
  oct48(48, '1/48 octave'),
  oct24(24, '1/24 octave'),
  oct12(12, '1/12 octave'),
  oct6(6, '1/6 octave'),
  oct3(3, '1/3 octave');

  const Smoothing(this.fraction, this.label);
  final double fraction;
  final String label;
}

class MeasurementService {
  MeasurementService(this._core, this._audio,
      {this.config = const MeasurementConfig(),
      this.libraryPath,
      Duration? captureTimeout,
      this.calibration})
      : captureTimeout = captureTimeout ??
            Duration(seconds: (config.durationSec + 20).round());

  final Rewcore _core;

  /// The native core, for analyses that need it directly — the polarity check
  /// works on responses already measured, so it has nothing to capture.
  Rewcore get core => _core;
  final AudioBackend _audio;
  /// Mutable so the user can change smoothing (and with it the point
  /// density) between measurements, the way REW lets you.
  MeasurementConfig config;

  /// Where a background isolate should load the native library from. Null means
  /// "resolve the usual way", which is what the app does on a device; tests pass
  /// an explicit path because a plain Dart process has no linked-in symbols.
  final String? libraryPath;

  /// How long to wait for the backend to hand back a capture before giving up.
  /// Unbounded waiting is what left the UI stuck "busy" with a Measure button
  /// that silently ignored taps.
  final Duration captureTimeout;

  /// UMIK-1 calibration applied to every measurement (null = none loaded).
  /// Supplied at construction from the app-level store, so a service built
  /// anywhere — the wizard, the polarity check, a measurement asked for over
  /// MCP — is calibrated without having to be told.
  MicCalibration? calibration;

  // Sweeps are cached per band; regenerating a 3 s sweep on every measurement of
  // an averaged set would be wasteful.
  final Map<String, Future<Float64List>> _sweeps = {};

  /// The stimulus for [band]. The swept range is deliberately a little wider than
  /// the analysed range, so the sweep's fade-in/out never lands on a band edge.
  Future<Float64List> sweepFor(SweepBand band) {
    // On failure the entry is dropped: a cached rejected Future would make every
    // later measurement fail identically until the app was restarted.
    return _sweeps.putIfAbsent(band.label, () {
      final fs = config.fs;
      final dur = config.durationSec;
      final f1 = (band.fLo / 1.1).clamp(10.0, fs / 2);
      final f2 = (band.fHi * 1.1).clamp(20.0, fs * 0.45);
      final lib = libraryPath;
      final future = Isolate.run(() => Rewcore.open(libraryPath: lib)
          .generateSweep(fs: fs, f1: f1, f2: f2, durationSec: dur));
      future.catchError((Object e) {
        _sweeps.remove(band.label);
        throw e;
      });
      return future;
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
    final lib = libraryPath;
    final noise = await Isolate.run(() => Rewcore.open(libraryPath: lib)
        .generateNoise(fs: fs, durationSec: 2, fLo: fLo, fHi: fHi, amplitude: 0.3));
    await _audio.startTone(samples: noise, fs: fs);
  }

  /// Run a single capture over [band]: magnitude response plus captured level.
  /// Measures the car's own noise the same way the sweep is measured: capture
  /// while playing silence, then run the identical analysis against the same
  /// stimulus. The result lands in the same units as a measurement, so
  /// subtracting the two gives a real signal-to-noise ratio per frequency.
  ///
  /// This is the difference between a curve and a measurement. In the car,
  /// engine, HVAC and road noise swamp the sweep above a few hundred Hz unless
  /// it is played loudly, and a Bluetooth link running SBC drops everything
  /// above roughly 11 kHz — both of which the old code drew as if they were the
  /// response of the speakers.
  Future<FreqResponse> measureNoiseFloor({SweepBand band = SweepBand.full}) async {
    final stimulus = await sweepFor(band);
    final silence = Float64List(stimulus.length);

    final recorded = await _audio
        .playSweepAndCapture(sweep: silence, fs: config.fs)
        .timeout(
      captureTimeout,
      onTimeout: () => throw TimeoutException(
          'The microphone did not return any audio while measuring the noise '
          'floor. Check it is still plugged in, then try again.'),
    );

    final fs = config.fs;
    final smooth = config.smoothFrac;
    final pts = config.gridPoints;
    final fLo = band.fLo;
    final fHi = band.fHi;
    final cal = calibration;
    final lib = libraryPath;

    return Isolate.run(() => Rewcore.open(libraryPath: lib).measureFr(
          emitted: stimulus,
          recorded: recorded,
          fs: fs,
          fMin: fLo,
          fMax: fHi,
          smoothFrac: smooth,
          points: pts,
          calibration: cal,
        ));
  }

  Future<Measurement> measureOnce({
    SweepBand band = SweepBand.full,
    FreqResponse? noiseFloor,
  }) async {
    final stimulus = await sweepFor(band);

    // Hard limit on the capture. The native side blocks in AudioRecord.read(),
    // which never returns if the mic has gone away — and a capture that never
    // returns leaves the UI stuck "busy" with a dead Measure button, which is
    // exactly how this failed in the field. Fail loudly instead of hanging.
    final recorded = await _audio
        .playSweepAndCapture(sweep: stimulus, fs: config.fs)
        .timeout(
      captureTimeout,
      onTimeout: () => throw TimeoutException(
          'The microphone did not return any audio. Check it is still plugged '
          'in, then try again.'),
    );

    // Everything below is seconds of FFT work, so it happens off the main
    // isolate; blocking the UI thread here is what triggers an ANR.
    final fs = config.fs;
    final smooth = config.smoothFrac;
    final pts = config.gridPoints;
    final fLo = band.fLo;
    final fHi = band.fHi;
    final cal = calibration;
    final lib = libraryPath;

    return Isolate.run(() {
      final core = Rewcore.open(libraryPath: lib);

      // Check the capture before inferring anything from it. A clipped, silent
      // or near-empty recording produces a confident-looking curve and
      // completely wrong advice, and none of that is visible on the plot
      // afterwards.
      final quality = core.assessCapture(recorded, fs);
      if (!quality.usable) {
        throw BadCaptureException(quality);
      }

      final level = core.rmsDbfs(recorded);
      final curves = core.measureCurves(
        emitted: stimulus,
        recorded: recorded,
        fs: fs,
        fMin: fLo,
        fMax: fHi,
        smoothFrac: smooth,
        points: pts,
        calibration: cal,
      );
      return Measurement(
          response: curves.display,
          analysis: curves.analysis,
          levelDbfs: level,
          noiseFloor: noiseFloor,
          quality: quality);
    });
  }

  /// [measureOnce] with the noise floor attached.
  Future<Measurement> measureWithNoiseFloor(
      {SweepBand band = SweepBand.full}) async {
    final noise = await measureNoiseFloor(band: band);
    final m = await measureOnce(band: band);
    return Measurement(
        response: m.response, levelDbfs: m.levelDbfs, noiseFloor: noise);
  }

  /// Recommend crossover edges from a single driver's measured response.
  CrossoverRecommendation recommendCrossover(FreqResponse driver) =>
      _core.recommendCrossover(driver);

  /// Run [n] captures (e.g. around the listening position) and power-average them.
  Future<Measurement> measureAveraged(int n,
      {SweepBand band = SweepBand.full,
      bool withNoiseFloor = true,
      void Function(MeasurePhase phase, int done, int total)? onPhase}) async {
    // Sweeps first, noise floor last.
    //
    // The noise floor is a full-length recording of silence, so measuring it
    // first meant roughly eight seconds passed between pressing Measure and
    // any sound at all — long enough to look broken, and long enough that
    // people press the button again. The order does not matter to the result:
    // the two captures are independent.
    final all = <FreqResponse>[];
    final allAnalysis = <FreqResponse>[];
    var levelSum = 0.0;
    for (var i = 0; i < n; i++) {
      onPhase?.call(MeasurePhase.sweep, i, n);
      final m = await measureOnce(band: band);
      all.add(m.response);
      allAnalysis.add(m.analysisResponse);
      levelSum += m.levelDbfs;
    }

    // Once per set: the car's noise does not change between mic positions, and
    // it costs a whole extra capture.
    FreqResponse? noise;
    if (withNoiseFloor) {
      onPhase?.call(MeasurePhase.noiseFloor, n, n);
      noise = await measureNoiseFloor(band: band);
    }
    // Keep how much the captures disagreed, not just their average: it is what
    // separates a property of the car from something that happened once.
    final lib = libraryPath;
    final spread = allAnalysis.length < 2
        ? <double>[]
        : await Isolate.run(
            () => Rewcore.open(libraryPath: lib).responseSpread(allAnalysis));

    return Measurement(
        response: _powerAverage(all),
        analysis: _powerAverage(allAnalysis),
        levelDbfs: levelSum / n,
        noiseFloor: noise,
        spreadDb: spread);
  }

  Future<EqResult> fitEq(FreqResponse measured,
      {int maxBands = 10,
      SweepBand band = SweepBand.full,
      double targetPercentile = 0.25,
      double maxCutDb = 6.0,
      List<bool>? valid,
      List<double>? spreadDb,
      TargetShape target = const TargetShape()}) {
    final fs = config.fs;
    final fLo = band.fLo;
    final fHi = band.fHi;
    final lib = libraryPath;
    return Isolate.run(() => Rewcore.open(libraryPath: lib).fitPeqFlat(
          measured: measured,
          fs: fs,
          fMin: fLo,
          fMax: fHi,
          maxBands: maxBands,
          targetPercentile: targetPercentile,
          maxCutDb: maxCutDb,
          valid: valid,
          spreadDb: spreadDb,
          target: target,
        ));
  }

  /// [fitEq] over only the part of [m] that cleared the noise.
  Future<EqResult> fitEqFor(Measurement m,
          {int maxBands = 10,
          SweepBand band = SweepBand.full,
          double targetPercentile = 0.25,
          double maxCutDb = 6.0,
          double minSnrDb = 10,
          TargetShape target = const TargetShape()}) =>
      fitEq(m.analysisResponse,
          maxBands: maxBands,
          band: band,
          targetPercentile: targetPercentile,
          maxCutDb: maxCutDb,
          valid: m.noiseFloor == null ? null : m.trustworthy(minSnrDb: minSnrDb),
          spreadDb: m.spreadDb.isEmpty ? null : m.spreadDb,
          target: target);

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
