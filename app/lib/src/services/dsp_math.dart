// Small Dart-side DSP helpers for interactive previews (the authoritative math is
// rewcore in C++; these mirror it for drawing predicted curves without a round trip).
import 'dart:math' as math;

import '../models/measurement.dart';

/// Magnitude (dB) of an RBJ peaking biquad at frequency [f].
double peakingMagnitudeDb(double f, double fs, double gainDb, double q) {
  final a = math.pow(10, gainDb / 40).toDouble();
  final w0 = 2 * math.pi * f / fs;
  final cw = math.cos(w0), sw = math.sin(w0);
  final alpha = sw / (2 * q);
  final a0 = 1 + alpha / a;
  final b0 = (1 + alpha * a) / a0;
  final b1 = (-2 * cw) / a0;
  final b2 = (1 - alpha * a) / a0;
  final a1 = (-2 * cw) / a0;
  final a2 = (1 - alpha / a) / a0;

  final w = 2 * math.pi * f / fs;
  final cosw = math.cos(w), sinw = math.sin(w);
  final cos2w = math.cos(2 * w), sin2w = math.sin(2 * w);
  final numRe = b0 + b1 * cosw + b2 * cos2w;
  final numIm = -(b1 * sinw + b2 * sin2w);
  final denRe = 1 + a1 * cosw + a2 * cos2w;
  final denIm = -(a1 * sinw + a2 * sin2w);
  final num = math.sqrt(numRe * numRe + numIm * numIm);
  final den = math.sqrt(denRe * denRe + denIm * denIm);
  return 20 * (math.log(num / den) / math.ln10);
}

/// Predicted response after applying a cascade of PEQ bands to [measured].
FreqResponse applyEqPreview(FreqResponse measured, List<PeqBand> bands, double fs) {
  final out = List<double>.filled(measured.length, 0);
  for (var i = 0; i < measured.length; i++) {
    var db = measured.magDb[i];
    for (final b in bands) {
      db += peakingMagnitudeDb(measured.freqHz[i], fs, b.gainDb, b.q);
    }
    out[i] = db;
  }
  return FreqResponse(List<double>.from(measured.freqHz), out);
}
