// Small Dart-side DSP helpers for interactive previews (the authoritative math is
// rewcore in C++; these mirror it for drawing predicted curves without a round trip).
import 'dart:math' as math;

import '../models/measurement.dart';

/// Magnitude (dB) at [evalHz] of an RBJ peaking biquad centered at [f0].
/// (Center and evaluation frequency are distinct — a band shapes the whole curve.)
double peakingMagnitudeDb({
  required double evalHz,
  required double f0,
  required double fs,
  required double gainDb,
  required double q,
}) {
  final a = math.pow(10, gainDb / 40).toDouble();
  final w0 = 2 * math.pi * f0 / fs;
  final cw = math.cos(w0), sw = math.sin(w0);
  final alpha = sw / (2 * q);
  final a0 = 1 + alpha / a;
  final b0 = (1 + alpha * a) / a0;
  final b1 = (-2 * cw) / a0;
  final b2 = (1 - alpha * a) / a0;
  final a1 = (-2 * cw) / a0;
  final a2 = (1 - alpha / a) / a0;

  final w = 2 * math.pi * evalHz / fs;
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

/// What the EQ does to a measured response.
class EqPreview {
  const EqPreview(this.predicted, this.levelChangeDb);

  /// The predicted curve, shifted so its level matches the measured one.
  final FreqResponse predicted;

  /// How much quieter (negative) the EQ actually makes the system. Cut-oriented
  /// EQ always costs level; you make it back on the DSP's output gain.
  final double levelChangeDb;
}

/// Predicted response after applying a cascade of PEQ bands to [measured].
///
/// By default the result is LEVEL-MATCHED to the measured curve. Without that,
/// a cut-oriented fit just draws a lower copy of the input and looks like it is
/// only turning things down — the flattening is invisible because the eye reads
/// the offset, not the shape. The offset is reported separately instead.
EqPreview applyEqPreview(FreqResponse measured, List<PeqBand> bands, double fs,
    {bool levelMatch = true}) {
  final raw = List<double>.filled(measured.length, 0);
  for (var i = 0; i < measured.length; i++) {
    var db = measured.magDb[i];
    for (final b in bands) {
      db += peakingMagnitudeDb(
          evalHz: measured.freqHz[i], f0: b.freqHz, fs: fs, gainDb: b.gainDb, q: b.q);
    }
    raw[i] = db;
  }

  // Average the shift over the usable band only, so a dead region cannot skew it.
  final sorted = List<double>.from(measured.magDb)..sort();
  final passband = sorted.isEmpty
      ? 0.0
      : sorted.sublist((sorted.length * 3) ~/ 4).reduce((a, b) => a + b) /
          (sorted.length - (sorted.length * 3) ~/ 4);
  var sum = 0.0;
  var n = 0;
  for (var i = 0; i < measured.length; i++) {
    if (measured.magDb[i] < passband - 25) continue;
    sum += raw[i] - measured.magDb[i];
    n++;
  }
  final offset = n > 0 ? sum / n : 0.0;

  final shown = levelMatch
      ? [for (final v in raw) v - offset]
      : raw;
  return EqPreview(
      FreqResponse(List<double>.from(measured.freqHz), shown), offset);
}
