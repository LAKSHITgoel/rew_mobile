// The target drawn on the chart must be the same shape the fitter aims at.
// They are computed in different languages, so nothing but a test keeps them
// honest — and a chart promising one curve while the EQ chases another would
// be worse than showing no target at all.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/models/measurement.dart';

FreqResponse _grid() {
  final f = <double>[];
  for (var i = 0; i < 200; i++) {
    final t = i / 199;
    f.add(math.exp(math.log(20) + t * (math.log(20000) - math.log(20))));
  }
  return FreqResponse(f, List<double>.filled(f.length, 0));
}

double _at(FreqResponse fr, double hz) {
  var best = 0;
  var err = double.infinity;
  for (var i = 0; i < fr.length; i++) {
    final e = (math.log(fr.freqHz[i] / hz)).abs();
    if (e < err) {
      err = e;
      best = i;
    }
  }
  return fr.magDb[best];
}

void main() {
  test('a neutral target is a flat line', () {
    final curve = const TargetShape().curveLike(_grid());
    for (final v in curve.magDb) {
      expect(v, closeTo(0, 1e-9));
    }
  });

  test('the drawn curve matches the shape the fitter aims at', () {
    // Same numbers the C++ test pins: full shelf well below the corner, half of
    // it at the corner, mids untouched, and the tilt only above the pivot.
    const warm = TargetShape(
      bassShelfDb: 6,
      bassShelfHz: 80,
      tiltDbPerOctave: -0.5,
      tiltPivotHz: 1000,
    );
    final c = warm.curveLike(_grid());

    expect(_at(c, 25), closeTo(6, 0.5));
    expect(_at(c, 80), closeTo(3, 0.5));
    expect(_at(c, 500), closeTo(0, 0.4));
    expect(_at(c, 1000), closeTo(0, 0.1));
    expect(_at(c, 16000), closeTo(-2, 0.4));
    // The tilt must not reach below the pivot, or it double-counts the shelf.
    expect(_at(c, 300), greaterThan(-0.1));
  });

  test('the target can be sat on the measurement it is drawn against', () {
    const warm = TargetShape(bassShelfDb: 4, tiltDbPerOctave: -0.3);
    final plain = warm.curveLike(_grid());
    final lifted = warm.curveLike(_grid(), alignAtDb: -40);
    for (var i = 0; i < plain.length; i++) {
      expect(lifted.magDb[i], closeTo(plain.magDb[i] - 40, 1e-9));
    }
  });

  test('every preset produces a usable curve', () {
    for (final p in TargetPreset.values) {
      final c = p.shape.curveLike(_grid());
      expect(c.length, 200, reason: '${p.label} produced no curve');
      for (final v in c.magDb) {
        expect(v.isFinite, isTrue, reason: '${p.label} produced a bad value');
        expect(v.abs(), lessThan(30));
      }
    }
  });
}
