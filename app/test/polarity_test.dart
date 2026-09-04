// Polarity through the real compiled core, on responses shaped like a genuine
// 2-way crossover. The verdict has to be right on both a correctly wired pair
// and a reversed one — advice to flip a driver that was fine is worse than no
// advice at all.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/ffi/rewcore.dart';
import 'package:rew_mobile/src/models/measurement.dart';

String? _findLib() {
  final ext = Platform.isMacOS ? 'dylib' : (Platform.isWindows ? 'dll' : 'so');
  final name = Platform.isWindows ? 'rewcore_ffi.$ext' : 'librewcore_ffi.$ext';
  for (final dir in ['../build-ffi', 'build-ffi']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}

/// A 4th-order Linkwitz-Riley pair crossed at [fc], as magnitudes.
({FreqResponse a, FreqResponse b, FreqResponse sum, FreqResponse inverted})
    _pair(double fc) {
  final hz = <double>[];
  final lo = <double>[];
  final hi = <double>[];
  final sum = <double>[];
  final inv = <double>[];
  for (var i = 0; i < 240; i++) {
    final t = i / 239;
    final f = math.exp(math.log(20) + t * (math.log(20000) - math.log(20)));
    // LR4 magnitude: squared 2nd-order Butterworth.
    final r = f / fc;
    final lp = 1 / (1 + math.pow(r, 4).toDouble());
    final hp = math.pow(r, 4).toDouble() / (1 + math.pow(r, 4).toDouble());
    hz.add(f);
    lo.add(20 * math.log(lp + 1e-12) / math.ln10);
    hi.add(20 * math.log(hp + 1e-12) / math.ln10);
    sum.add(20 * math.log(lp + hp + 1e-12) / math.ln10);
    inv.add(20 * math.log((lp - hp).abs() + 1e-12) / math.ln10);
  }
  return (
    a: FreqResponse(hz, lo),
    b: FreqResponse(hz, hi),
    sum: FreqResponse(hz, sum),
    inverted: FreqResponse(hz, inv),
  );
}

void main() {
  final lib = _findLib();
  if (lib == null) {
    test('polarity (skipped: library not built)', () {}, skip: true);
    return;
  }
  late Rewcore core;
  setUpAll(() => core = Rewcore.open(libraryPath: lib));

  test('the struct layout agrees with the C side', () {
    expect(core.peqRequestLayoutMatches(), isTrue);
  });

  test('a correctly wired pair is left alone', () {
    final p = _pair(2000);
    final r = core.analyzeSummation(
        a: p.a, b: p.b, both: p.sum, bothInverted: p.inverted);
    expect(r.valid, isTrue);
    expect(r.advice, PolarityAdvice.keep);
    expect(r.haveInverted, isTrue);
    // Inverting would make it worse, so the gain from inverting is negative.
    expect(r.invertedGainDb, lessThan(0));
    expect(r.overlapLoHz, lessThan(2000));
    expect(r.overlapHiHz, greaterThan(2000));
    expect(r.explanation, contains('leave it alone'));
  });

  test('a reversed driver is caught, and the advice says what to do', () {
    final p = _pair(2000);
    // The pair as wired is the cancelling one; inverting fixes it.
    final r = core.analyzeSummation(
        a: p.a, b: p.b, both: p.inverted, bothInverted: p.sum);
    expect(r.advice, PolarityAdvice.invert);
    expect(r.invertedGainDb, greaterThan(1.5));
    expect(r.explanation, contains('Flip the polarity'));
    expect(r.confidence, greaterThan(0.2));
  });

  test('without the inverted measurement, cancellation is still flagged', () {
    final p = _pair(2000);
    final r = core.analyzeSummation(a: p.a, b: p.b, both: p.inverted);
    expect(r.haveInverted, isFalse);
    expect(r.advice, PolarityAdvice.suspectDestructive);
    // And it asks for the measurement that would settle it.
    expect(r.explanation, contains('with one inverted'));
  });

  test('drivers that barely overlap are refused, not guessed at', () {
    // A subwoofer and a tweeter share no useful band.
    final hz = <double>[];
    final sub = <double>[];
    final tw = <double>[];
    final both = <double>[];
    for (var i = 0; i < 240; i++) {
      final t = i / 239;
      final f = math.exp(math.log(20) + t * (math.log(20000) - math.log(20)));
      final s = f < 100 ? 0.0 : -60.0 * math.log(f / 100) / math.ln2;
      final w = f > 5000 ? 0.0 : -60.0 * math.log(5000 / f) / math.ln2;
      hz.add(f);
      sub.add(s);
      tw.add(w);
      both.add(math.max(s, w));
    }
    final r = core.analyzeSummation(
      a: FreqResponse(hz, sub),
      b: FreqResponse(hz, tw),
      both: FreqResponse(hz, both),
    );
    expect(r.valid, isFalse);
    expect(r.explanation, contains('barely overlap'));
  });

  test('mismatched grids are refused rather than misread', () {
    final p = _pair(2000);
    final short = FreqResponse([100, 200], [0, 0]);
    final r = core.analyzeSummation(a: p.a, b: short, both: p.sum);
    expect(r.valid, isFalse);
  });
}
