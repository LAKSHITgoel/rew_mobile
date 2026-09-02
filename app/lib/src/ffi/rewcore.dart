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

  /// Deconvolve a recording against the emitted sweep and return a smoothed,
  /// log-gridded magnitude response. If [calibration] is supplied, the UMIK-1 cal
  /// curve is applied so the result reflects the speakers/room, not the mic.
  FreqResponse measureFr({
    required Float64List emitted,
    required Float64List recorded,
    double fs = 48000,
    double fMin = 20,
    double fMax = 20000,
    double smoothFrac = 24,
    int points = 96,
    MicCalibration? calibration,
  }) {
    final em = calloc<ffi.Double>(emitted.length);
    final rec = calloc<ffi.Double>(recorded.length);
    final freqOut = calloc<ffi.Double>(points);
    final magOut = calloc<ffi.Double>(points);

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
      final n = _b.rewMeasureFr(
          em, emitted.length, rec, recorded.length, fs, fMin, fMax, smoothFrac,
          points, calFreq, calGain, calN, freqOut, magOut, points);
      return FreqResponse(
        List<double>.from(freqOut.asTypedList(n)),
        List<double>.from(magOut.asTypedList(n)),
      );
    } finally {
      calloc.free(em);
      calloc.free(rec);
      calloc.free(freqOut);
      calloc.free(magOut);
      if (calN > 0) {
        calloc.free(calFreq);
        calloc.free(calGain);
      }
    }
  }

  /// Recommend crossover edges for one measured driver response.
  CrossoverRecommendation recommendCrossover(FreqResponse driver,
      {double dropDb = 6}) {
    final n = driver.length;
    final freq = calloc<ffi.Double>(n);
    final mag = calloc<ffi.Double>(n);
    final hp = calloc<ffi.Double>(1);
    final lp = calloc<ffi.Double>(1);
    try {
      freq.asTypedList(n).setAll(0, driver.freqHz);
      mag.asTypedList(n).setAll(0, driver.magDb);
      final mask = _b.rewRecommendCrossover(freq, mag, n, dropDb, hp, lp);
      return CrossoverRecommendation(
        highPassHz: (mask & 1) != 0 ? hp.value : null,
        lowPassHz: (mask & 2) != 0 ? lp.value : null,
      );
    } finally {
      calloc.free(freq);
      calloc.free(mag);
      calloc.free(hp);
      calloc.free(lp);
    }
  }

  /// Fit up to [maxBands] parametric EQ bands to move [measured] toward flat.
  EqResult fitPeqFlat({
    required FreqResponse measured,
    double fs = 48000,
    double fMin = 20,
    double fMax = 20000,
    int maxBands = 10,
  }) {
    final n = measured.length;
    final freq = calloc<ffi.Double>(n);
    final mag = calloc<ffi.Double>(n);
    final fOut = calloc<ffi.Double>(maxBands);
    final gOut = calloc<ffi.Double>(maxBands);
    final qOut = calloc<ffi.Double>(maxBands);
    final errOut = calloc<ffi.Double>(2);
    try {
      freq.asTypedList(n).setAll(0, measured.freqHz);
      mag.asTypedList(n).setAll(0, measured.magDb);
      final count = _b.rewFitPeqFlat(
          freq, mag, n, fs, fMin, fMax, maxBands, fOut, gOut, qOut, errOut);
      final bands = <PeqBand>[];
      for (var i = 0; i < count; i++) {
        bands.add(PeqBand(freqHz: fOut[i], gainDb: gOut[i], q: qOut[i]));
      }
      return EqResult(
        bands: bands,
        initialErrorDb: errOut[0],
        finalErrorDb: errOut[1],
      );
    } finally {
      calloc.free(freq);
      calloc.free(mag);
      calloc.free(fOut);
      calloc.free(gOut);
      calloc.free(qOut);
      calloc.free(errOut);
    }
  }
}
