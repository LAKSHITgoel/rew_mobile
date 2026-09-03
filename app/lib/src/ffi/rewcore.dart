// High-level, memory-safe Dart wrapper around the rewcore FFI bindings. All the
// calloc/free bookkeeping lives here so the rest of the app deals only in Dart
// lists and model objects.
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/measurement.dart';
import '../models/mic_calibration.dart';
import 'rewcore_bindings.dart';

class Rewcore {
  Rewcore._(this._b);

  final RewcoreBindings _b;

  /// Opens the native library and resolves symbols. Throws if unavailable
  /// (e.g. running pure-Dart tests without the native lib linked).
  factory Rewcore.open({String? libraryPath}) =>
      Rewcore._(RewcoreBindings(RewcoreBindings.open(libraryPath: libraryPath)));

  String version() => _b.rewVersion().cast<Utf8>().toDartString();

  /// Generate an exponential sine sweep to play through the car.
  Float64List generateSweep({
    double fs = 48000,
    double f1 = 20,
    double f2 = 20000,
    double durationSec = 3,
  }) {
    final needed = _b.rewGenerateSweep(fs, f1, f2, durationSec, ffi.nullptr, 0);
    final out = calloc<ffi.Double>(needed);
    try {
      final n = _b.rewGenerateSweep(fs, f1, f2, durationSec, out, needed);
      return Float64List.fromList(out.asTypedList(n));
    } finally {
      calloc.free(out);
    }
  }

  /// RMS level of a captured buffer in dBFS (full-scale sine = -3.01 dBFS).
  double rmsDbfs(Float64List samples) {
    if (samples.isEmpty) return -240;
    final buf = calloc<ffi.Double>(samples.length);
    try {
      buf.asTypedList(samples.length).setAll(0, samples);
      return _b.rewRmsDbfs(buf, samples.length);
    } finally {
      calloc.free(buf);
    }
  }

  /// One loopable block of pink noise, optionally band-limited. Used as the
  /// centring signal for manual time alignment.
  Float64List generateNoise({
    double fs = 48000,
    double durationSec = 2,
    double fLo = 0,
    double fHi = 0,
    double amplitude = 0.3,
    int seed = 1,
  }) {
    final needed = _b.rewGenerateNoise(
        fs, durationSec, fLo, fHi, amplitude, seed, ffi.nullptr, 0);
    final out = calloc<ffi.Double>(needed);
    try {
      final n = _b.rewGenerateNoise(
          fs, durationSec, fLo, fHi, amplitude, seed, out, needed);
      return Float64List.fromList(out.asTypedList(n));
    } finally {
      calloc.free(out);
    }
  }

  /// Deconvolve a recording against the emitted sweep and return a smoothed,
  /// log-gridded magnitude response. If [calibration] is supplied, the UMIK-1 cal
  /// curve is applied so the result reflects the speakers/room, not the mic.
  /// A measurement's two curves: what to draw, and what to fit against.
  ///
  /// They are separated because the jobs disagree — heavy smoothing is right
  /// for reading tonal balance and wrong for deciding filters.
  MeasuredCurves measureCurves({
    required Float64List emitted,
    required Float64List recorded,
    double fs = 48000,
    double fMin = 20,
    double fMax = 20000,
    double smoothFrac = 24,

    /// Smoothing the EQ fitter sees, independent of what is displayed.
    double analysisSmoothFrac = 24,
    int points = 96,
    MicCalibration? calibration,
    // Removing the flight time is what makes phase readable at all: over
    // Bluetooth the path delay alone is thousands of degrees at 1 kHz.
    bool timeReferencePhase = true,
  }) {
    final em = calloc<ffi.Double>(emitted.length);
    final rec = calloc<ffi.Double>(recorded.length);
    final freqOut = calloc<ffi.Double>(points);
    final magOut = calloc<ffi.Double>(points);
    final magAnalysisOut = calloc<ffi.Double>(points);
    final phaseOut = calloc<ffi.Double>(points);

    // Optional mic calibration. A direct null-check inside the `if` promotes `cal`
    // to non-null without needing `!`, and works across SDK versions.
    ffi.Pointer<ffi.Double> calFreq = ffi.nullptr;
    ffi.Pointer<ffi.Double> calGain = ffi.nullptr;
    var calN = 0;
    final cal = calibration;
    if (cal != null && !cal.isEmpty) {
      calN = cal.freqHz.length;
      calFreq = calloc<ffi.Double>(calN);
      calGain = calloc<ffi.Double>(calN);
      calFreq.asTypedList(calN).setAll(0, cal.freqHz);
      calGain.asTypedList(calN).setAll(0, cal.gainDb);
    }
    try {
      em.asTypedList(emitted.length).setAll(0, emitted);
      rec.asTypedList(recorded.length).setAll(0, recorded);
      final req = calloc<RewMeasureRequest>();
      try {
        req.ref
          ..emitted = em
          ..recorded = rec
          ..calFreq = calFreq
          ..calGain = calGain
          ..emittedLen = emitted.length
          ..recordedLen = recorded.length
          ..calN = calN
          ..points = points
          ..fs = fs
          ..fMin = fMin
          ..fMax = fMax
          ..smoothFrac = smoothFrac
          ..analysisSmoothFrac = analysisSmoothFrac
          ..timeReferencePhase = timeReferencePhase ? 1 : 0
          ..freqOut = freqOut
          ..magOut = magOut
          ..magAnalysisOut = magAnalysisOut
          ..phaseOut = phaseOut
          ..cap = points;
        final n = _b.rewMeasureFr(req);
        final freq = List<double>.from(freqOut.asTypedList(n));
        return MeasuredCurves(
          display: FreqResponse(
            freq,
            List<double>.from(magOut.asTypedList(n)),
            List<double>.from(phaseOut.asTypedList(n)),
          ),
          analysis: FreqResponse(
            freq,
            List<double>.from(magAnalysisOut.asTypedList(n)),
          ),
        );
      } finally {
        calloc.free(req);
      }
    } finally {
      calloc.free(em);
      calloc.free(rec);
      calloc.free(freqOut);
      calloc.free(magOut);
      calloc.free(magAnalysisOut);
      calloc.free(phaseOut);
      if (calN > 0) {
        calloc.free(calFreq);
        calloc.free(calGain);
      }
    }
  }

  /// Recommend crossover edges for one measured driver response.
  CrossoverRecommendation recommendCrossover(FreqResponse driver,
      {double dropDb = 6,
      double targetAcousticDbPerOct = 24,
      double marginOctaves = 0.33}) {
    final n = driver.length;
    final freq = calloc<ffi.Double>(n);
    final mag = calloc<ffi.Double>(n);
    final out = calloc<RewCrossoverResult>();
    try {
      freq.asTypedList(n).setAll(0, driver.freqHz);
      mag.asTypedList(n).setAll(0, driver.magDb);
      _b.rewRecommendCrossover(
          freq, mag, n, dropDb, targetAcousticDbPerOct, marginOctaves, out);
      CrossoverEdge edge(RewCrossoverEdge e) => CrossoverEdge(
            present: e.present != 0,
            freqHz: e.freqHz,
            recommendedHz: e.recommendedHz,
            acousticSlopeDbPerOct: e.acousticSlopeDbPerOct,
            electricalSlopeDbPerOct: e.electricalSlopeDbPerOct,
            confidence: e.confidence,
            reason: crossoverReasonFromCode(e.reason),
          );
      return CrossoverRecommendation(
        highPass: edge(out.ref.highPass),
        lowPass: edge(out.ref.lowPass),
        passbandDb: out.ref.passbandDb,
      );
    } finally {
      calloc.free(freq);
      calloc.free(mag);
      calloc.free(out);
    }
  }

  /// Backwards-compatible shorthand for callers that only want the display
  /// curve (the FFI smoke tests, and the crossover path, which measures one
  /// driver at a time).
  FreqResponse measureFr({
    required Float64List emitted,
    required Float64List recorded,
    double fs = 48000,
    double fMin = 20,
    double fMax = 20000,
    double smoothFrac = 24,
    int points = 96,
    MicCalibration? calibration,
    bool timeReferencePhase = true,
  }) =>
      measureCurves(
        emitted: emitted,
        recorded: recorded,
        fs: fs,
        fMin: fMin,
        fMax: fMax,
        smoothFrac: smoothFrac,
        points: points,
        calibration: calibration,
        timeReferencePhase: timeReferencePhase,
      ).display;

  /// Asserts the Dart mirrors of the request structs agree with the C ones.
  ///
  /// A struct ABI makes a transposed argument a compile error, but it makes a
  /// mismatched layout silent corruption — the fit would simply read garbage
  /// where it expected a pointer. Checking the size catches the realistic
  /// failure (a field added on one side only) immediately.
  bool peqRequestLayoutMatches() =>
      _b.rewPeqRequestSize() == ffi.sizeOf<RewPeqRequest>() &&
      _b.rewMeasureRequestSize() == ffi.sizeOf<RewMeasureRequest>() &&
      _b.rewCrossoverResultSize() == ffi.sizeOf<RewCrossoverResult>();

  /// Check a raw capture before anything is inferred from it.
  CaptureQuality assessCapture(Float64List samples, double fs) {
    if (samples.isEmpty) {
      return const CaptureQuality(
          peak: 0,
          rmsDbfs: -240,
          clippedFraction: 0,
          silentFraction: 1,
          clipped: false,
          tooQuiet: true,
          mostlySilent: true);
    }
    final buf = calloc<ffi.Double>(samples.length);
    final out = calloc<ffi.Double>(6);
    try {
      buf.asTypedList(samples.length).setAll(0, samples);
      final flags = _b.rewAssessCapture(buf, samples.length, fs, out);
      return CaptureQuality(
        peak: out[0],
        rmsDbfs: out[1],
        clippedFraction: out[2],
        silentFraction: out[3],
        clipped: (flags & 1) != 0,
        tooQuiet: (flags & 2) != 0,
        mostlySilent: (flags & 4) != 0,
      );
    } finally {
      calloc.free(buf);
      calloc.free(out);
    }
  }

  /// Per-point standard deviation across repeated captures, in dB.
  ///
  /// Averaging captures together and keeping only the mean throws away the most
  /// useful thing repeated measurements tell you: which features held still.
  List<double> responseSpread(List<FreqResponse> captures) {
    if (captures.length < 2) {
      return List<double>.filled(
          captures.isEmpty ? 0 : captures.first.length, 0);
    }
    final n = captures.first.length;
    final flat = calloc<ffi.Double>(n * captures.length);
    final out = calloc<ffi.Double>(n);
    try {
      for (var k = 0; k < captures.length; k++) {
        if (captures[k].length != n) {
          return List<double>.filled(n, 0);
        }
        flat.asTypedList(n * captures.length).setAll(k * n, captures[k].magDb);
      }
      final count = _b.rewResponseSpread(flat, captures.length, n, out);
      return List<double>.generate(count, (i) => out[i]);
    } finally {
      calloc.free(flat);
      calloc.free(out);
    }
  }

  /// Fit up to [maxBands] parametric EQ bands to move [measured] toward flat.
  EqResult fitPeqFlat({
    required FreqResponse measured,
    double fs = 48000,
    double fMin = 20,
    double fMax = 20000,
    int maxBands = 10,
    /// Where the flat target sits in the usable band's level distribution.
    /// Lower cuts peaks harder (flatter, quieter); higher corrects gently.
    double targetPercentile = 0.25,

    /// Deepest cut any single band may apply. Past this the excess is reported
    /// as [EqResult.suggestedLevelTrimDb] instead: a very deep cut is a channel
    /// switched off, not a correction.
    double maxCutDb = 6.0,

    /// Deepest boost any band may apply. Kept low on purpose: a boost costs
    /// headroom everywhere, and in a car the dip is usually cancellation that
    /// will swallow it anyway.
    double maxBoostDb = 3.0,

    /// Per-point trust, same length as [measured]. Points marked false are left
    /// out of the fit entirely — use it to exclude anything the sweep did not
    /// lift clear of the noise.
    List<bool>? valid,

    /// Per-point standard deviation across repeated captures, same length as
    /// [measured]. Supplying it is what lets the fitter tell a property of the
    /// car from something that happened once.
    List<double>? spreadDb,

    /// What the system is being aimed at. Flat by default, which is rarely
    /// what you want in a car.
    TargetShape target = const TargetShape(),
  }) {
    final n = measured.length;
    final freq = calloc<ffi.Double>(n);
    final mag = calloc<ffi.Double>(n);
    final fOut = calloc<ffi.Double>(maxBands);
    final gOut = calloc<ffi.Double>(maxBands);
    final qOut = calloc<ffi.Double>(maxBands);
    final errOut = calloc<ffi.Double>(4);
    final reasonOut = calloc<ffi.Int>(maxBands);
    final confOut = calloc<ffi.Double>(maxBands);
    const declinedCap = 16;
    final declinedOut = calloc<ffi.Double>(declinedCap * 2);
    final spreadPtr = spreadDb == null || spreadDb.length != n
        ? ffi.nullptr
        : calloc<ffi.Double>(n);
    final validPtr = valid == null || valid.length != n
        ? ffi.nullptr
        : calloc<ffi.UnsignedChar>(n);
    try {
      freq.asTypedList(n).setAll(0, measured.freqHz);
      mag.asTypedList(n).setAll(0, measured.magDb);
      if (validPtr != ffi.nullptr) {
        final v = validPtr.cast<ffi.Uint8>().asTypedList(n);
        for (var i = 0; i < n; i++) {
          v[i] = valid![i] ? 1 : 0;
        }
      }
      if (spreadPtr != ffi.nullptr) {
        spreadPtr.asTypedList(n).setAll(0, spreadDb!);
      }

      final req = calloc<RewPeqRequest>();
      try {
        final r = req.ref
          ..freq = freq
          ..mag = mag
          ..valid = validPtr.cast<ffi.UnsignedChar>()
          ..spread = spreadPtr.cast<ffi.Double>()
          ..n = n
          ..fs = fs
          ..fMin = fMin
          ..fMax = fMax
          ..targetPercentile = targetPercentile
          ..maxCutDb = maxCutDb
          ..maxBoostDb = maxBoostDb
          ..maxBands = maxBands
          ..bassShelfDb = target.bassShelfDb
          ..bassShelfHz = target.bassShelfHz
          ..bassShelfWidthOct = target.bassShelfWidthOct
          ..tiltDbPerOctave = target.tiltDbPerOctave
          ..tiltPivotHz = target.tiltPivotHz
          ..freqOut = fOut
          ..gainOut = gOut
          ..qOut = qOut
          ..reasonOut = reasonOut
          ..confOut = confOut
          ..declinedOut = declinedOut
          ..declinedCap = declinedCap
          ..errOut = errOut;
        assert(r.n == n);
        final count = _b.rewFitPeq(req);
      final bands = <PeqBand>[];
      for (var i = 0; i < count; i++) {
        bands.add(PeqBand(
          freqHz: fOut[i],
          gainDb: gOut[i],
          q: qOut[i],
          reason: peqReasonFromCode(reasonOut[i]),
          confidence: confOut[i],
        ));
      }
      final declined = <DeclinedFeature>[];
      final declinedCount = errOut[3].round();
      for (var i = 0; i < declinedCount && i < declinedCap; i++) {
        declined.add(DeclinedFeature(
          reason: peqReasonFromCode(declinedOut[i * 2].round()),
          freqHz: declinedOut[i * 2 + 1],
        ));
      }
        return EqResult(
          bands: bands,
          initialErrorDb: errOut[0],
          finalErrorDb: errOut[1],
          suggestedLevelTrimDb: errOut[2],
          declined: declined,
        );
      } finally {
        calloc.free(req);
      }
    } finally {
      calloc.free(freq);
      calloc.free(mag);
      calloc.free(fOut);
      calloc.free(gOut);
      calloc.free(qOut);
      calloc.free(errOut);
      calloc.free(reasonOut);
      calloc.free(confOut);
      calloc.free(declinedOut);
      if (validPtr != ffi.nullptr) calloc.free(validPtr);
      if (spreadPtr != ffi.nullptr) calloc.free(spreadPtr);
    }
  }
}
