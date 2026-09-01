// Closed-form crossover magnitudes and summation check, mirroring rewcore's
// crossover.cpp. Kept in Dart (rather than crossing the FFI) because it is simple
// math and drives an interactive preview as the user drags the crossover point.
import 'dart:math' as math;

import '../models/measurement.dart';

int _order(XoverSlope s) => switch (s) {
      XoverSlope.butterworth12 => 1,
      XoverSlope.linkwitzRiley24 => 2,
      XoverSlope.linkwitzRiley48 => 4,
    };

double lowpassMag(double f, double fc, XoverSlope s) {
  final m = _order(s);
  final r2m = math.pow(f / fc, 2 * m).toDouble();
  if (s == XoverSlope.butterworth12) return 1 / math.sqrt(1 + r2m);
  return 1 / (1 + r2m);
}

double highpassMag(double f, double fc, XoverSlope s) {
  final m = _order(s);
  final r2m = math.pow(f / fc, 2 * m).toDouble();
  if (s == XoverSlope.butterworth12) return math.sqrt(r2m) / math.sqrt(1 + r2m);
  return r2m / (1 + r2m);
}

class SummationResult {
  SummationResult(this.freqHz, this.summedDb, this.maxDeviationDb);
  final List<double> freqHz;
  final List<double> summedDb;
  final double maxDeviationDb;
}

/// Predict the coherent magnitude sum of a low driver (low-passed at [fc]) and a
/// high driver (high-passed at [fc]). Deviation from 0 dB flags a mismatch.
SummationResult summation(
  double fc,
  XoverSlope lowSlope,
  XoverSlope highSlope, {
  double fMin = 200,
  double fMax = 20000,
  int points = 160,
}) {
  final freq = <double>[];
  final summed = <double>[];
  var maxDev = 0.0;
  final logMin = math.log(fMin), logMax = math.log(fMax);
  for (var i = 0; i < points; i++) {
    final t = i / (points - 1);
    final f = math.exp(logMin + t * (logMax - logMin));
    final s = lowpassMag(f, fc, lowSlope) + highpassMag(f, fc, highSlope);
    final db = 20 * (math.log(s <= 0 ? 1e-12 : s) / math.ln10);
    freq.add(f);
    summed.add(db);
    maxDev = math.max(maxDev, db.abs());
  }
  return SummationResult(freq, summed, maxDev);
}
