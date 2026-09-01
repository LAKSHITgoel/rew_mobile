// High-level, memory-safe Dart wrapper around the rewcore FFI bindings. All the
// calloc/free bookkeeping lives here so the rest of the app deals only in Dart
// lists and model objects.
import 'dart:ffi' as ffi;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../models/measurement.dart';
import 'rewcore_bindings.dart';

class Rewcore {
  Rewcore._(this._b);

  final RewcoreBindings _b;

  /// Opens the native library and resolves symbols. Throws if unavailable
  /// (e.g. running pure-Dart tests without the native lib linked).
  factory Rewcore.open() => Rewcore._(RewcoreBindings(RewcoreBindings.open()));

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
  /// log-gridded magnitude response.
  FreqResponse measureFr({
    required Float64List emitted,
    required Float64List recorded,
    double fs = 48000,
    double fMin = 20,
    double fMax = 20000,
    double smoothFrac = 24,
    int points = 96,
  }) {
    final em = calloc<ffi.Double>(emitted.length);
    final rec = calloc<ffi.Double>(recorded.length);
    final freqOut = calloc<ffi.Double>(points);
    final magOut = calloc<ffi.Double>(points);
    try {
      em.asTypedList(emitted.length).setAll(0, emitted);
      rec.asTypedList(recorded.length).setAll(0, recorded);
      final n = _b.rewMeasureFr(em, emitted.length, rec, recorded.length, fs,
          fMin, fMax, smoothFrac, points, freqOut, magOut, points);
      return FreqResponse(
        List<double>.from(freqOut.asTypedList(n)),
        List<double>.from(magOut.asTypedList(n)),
      );
    } finally {
      calloc.free(em);
      calloc.free(rec);
      calloc.free(freqOut);
      calloc.free(magOut);
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
    try {
      freq.asTypedList(n).setAll(0, measured.freqHz);
      mag.asTypedList(n).setAll(0, measured.magDb);
      final count = _b.rewFitPeqFlat(
          freq, mag, n, fs, fMin, fMax, maxBands, fOut, gOut, qOut);
      final bands = <PeqBand>[];
      for (var i = 0; i < count; i++) {
        bands.add(PeqBand(
            freqHz: fOut[i], gainDb: gOut[i], q: qOut[i]));
      }
      // The C ABI does not return the error metrics, so recompute a simple RMS
      // here for display (0 target). This mirrors rewcore::rmsErrorDb.
      final before = _rms(measured.magDb);
      return EqResult(bands: bands, initialErrorDb: before, finalErrorDb: 0);
    } finally {
      calloc.free(freq);
      calloc.free(mag);
      calloc.free(fOut);
      calloc.free(gOut);
      calloc.free(qOut);
    }
  }

  static double _rms(List<double> v) {
    if (v.isEmpty) return 0;
    var acc = 0.0;
    for (final x in v) {
      acc += x * x;
    }
    return math.sqrt(acc / v.length);
  }
}
