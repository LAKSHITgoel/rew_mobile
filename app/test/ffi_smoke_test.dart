// Validates the Dart FFI bindings against the REAL compiled rewcore library.
// This is the only place the Dart<->C ABI marshaling is exercised end-to-end
// (signatures, pointer/array marshaling, out-params), so it catches binding bugs
// that `flutter analyze` cannot. The same C ABI is used on Android and iOS.
//
// Build the library first (from the repo root):
//   cmake -S packages/rewcore_ffi/src -B build-ffi -DCMAKE_BUILD_TYPE=Release
//   cmake --build build-ffi -j
// The test skips itself if the library isn't present.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/ffi/rewcore.dart';
import 'package:rew_mobile/src/models/measurement.dart';
import 'package:rew_mobile/src/models/mic_calibration.dart';

String? _findLib() {
  final ext = Platform.isMacOS ? 'dylib' : (Platform.isWindows ? 'dll' : 'so');
  final name = Platform.isWindows ? 'rewcore_ffi.$ext' : 'librewcore_ffi.$ext';
  for (final dir in ['../build-ffi', 'build-ffi', '../build', 'build']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}

/// Direct-form-I biquad, to synthesize a "recording" through a known filter.
List<double> _applyPeaking(List<double> x, double f0, double fs, double gainDb, double q) {
  final a = math.pow(10, gainDb / 40).toDouble();
  final w0 = 2 * math.pi * f0 / fs;
  final cw = math.cos(w0), sw = math.sin(w0);
  final alpha = sw / (2 * q);
  final a0 = 1 + alpha / a;
  final b0 = (1 + alpha * a) / a0, b1 = (-2 * cw) / a0, b2 = (1 - alpha * a) / a0;
  final a1 = (-2 * cw) / a0, a2 = (1 - alpha / a) / a0;
  final y = List<double>.filled(x.length, 0);
  double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
  for (var n = 0; n < x.length; n++) {
    final o = b0 * x[n] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1; x1 = x[n]; y2 = y1; y1 = o; y[n] = o;
  }
  return y;
}

double _at(FreqResponse fr, double f) {
  var best = 0;
  for (var i = 1; i < fr.length; i++) {
    if ((fr.freqHz[i] - f).abs() < (fr.freqHz[best] - f).abs()) best = i;
  }
  return fr.magDb[best];
}

void main() {
  final libPath = _findLib();
  if (libPath == null) {
    test('rewcore FFI (skipped: library not built)', () {}, skip: true);
    return;
  }
  late Rewcore core;
  setUpAll(() => core = Rewcore.open(libraryPath: libPath));

  test('rew_version returns a version string', () {
    expect(core.version(), isNotEmpty);
  });

  test('rew_generate_sweep returns the expected sample count', () {
    final sweep = core.generateSweep(fs: 48000, f1: 50, f2: 18000, durationSec: 1);
    expect(sweep.length, 48000);
    expect(sweep.any((v) => v != 0), isTrue);
  });

  test('rew_measure_fr recovers a known biquad through the real DSP', () {
    const fs = 48000.0;
    final sweep = core.generateSweep(fs: fs, f1: 50, f2: 18000, durationSec: 1);
    // System under test: +6 dB peak at 1 kHz, Q 2, plus a decay tail.
    final padded = <double>[...sweep, ...List<double>.filled(4096, 0)];
    final recorded = Float64List.fromList(_applyPeaking(padded, 1000, fs, 6, 2));
    final fr = core.measureFr(
        emitted: sweep, recorded: recorded, fs: fs, fMin: 50, fMax: 18000, points: 96);
    expect(fr.length, greaterThan(0));
    expect(_at(fr, 1000), closeTo(6.0, 1.5)); // the boost is recovered
    expect(_at(fr, 200), closeTo(0.0, 1.5));  // flat away from it
  });

  test('rew_measure_fr applies the mic calibration (array marshaling)', () {
    const fs = 48000.0;
    final sweep = core.generateSweep(fs: fs, f1: 50, f2: 18000, durationSec: 1);
    final plain = core.measureFr(
        emitted: sweep, recorded: sweep, fs: fs, fMin: 50, fMax: 18000, points: 48);
    final cal = MicCalibration(freqHz: [20, 20000], gainDb: [3, 3]);
    final calibrated = core.measureFr(
        emitted: sweep, recorded: sweep, fs: fs, fMin: 50, fMax: 18000,
        points: 48, calibration: cal);
    final mid = plain.length ~/ 2;
    // A flat +3 dB mic curve pulls the measured response down 3 dB.
    expect(plain.magDb[mid] - calibrated.magDb[mid], closeTo(3.0, 0.3));
  });

  test('measureFr returns unwrapped phase for a known delay', () {
    const fs = 48000.0;
    final sweep = core.generateSweep(fs: fs, f1: 50, f2: 18000, durationSec: 1);
    // Delay the "recording" by a known number of samples.
    const d = 48; // 1 ms at 48 kHz
    final rec = Float64List(sweep.length + d);
    for (var i = 0; i < sweep.length; i++) {
      rec[i + d] = sweep[i];
    }
    // Raw phase (no time referencing) so the delay itself is measurable.
    final fr = core.measureFr(
        emitted: sweep,
        recorded: rec,
        fs: fs,
        fMin: 200,
        fMax: 8000,
        points: 64,
        timeReferencePhase: false);
    expect(fr.hasPhase, isTrue);

    // Unwrapped phase of a pure delay is a straight ramp: recover the delay.
    double phaseAt(double f) {
      var best = 0;
      for (var i = 1; i < fr.length; i++) {
        if ((fr.freqHz[i] - f).abs() < (fr.freqHz[best] - f).abs()) best = i;
      }
      return fr.phaseDeg[best];
    }
    final slope = (phaseAt(4000) - phaseAt(1000)) / (4000 - 1000);
    final delaySamples = -slope / 360 * fs;
    expect(delaySamples, closeTo(d.toDouble(), 2.0));
  });

  test('rew_rms_dbfs matches the -3.01 dBFS full-scale-sine convention', () {
    final sine = Float64List(4800);
    for (var i = 0; i < sine.length; i++) {
      sine[i] = math.sin(2 * math.pi * 100 * i / 48000);
    }
    expect(core.rmsDbfs(sine), closeTo(-3.01, 0.02));

    final half = Float64List.fromList(sine.map((v) => v * 0.5).toList());
    // Level differences are what channel matching relies on.
    expect(core.rmsDbfs(sine) - core.rmsDbfs(half), closeTo(6.02, 0.02));
  });

  test('rew_fit_peq_flat returns bands and real error metrics (out-params)', () {
    // A bumpy response built from two known features.
    final freq = <double>[], mag = <double>[];
    for (var i = 0; i < 200; i++) {
      final f = 20 * math.pow(1000.0, i / 199).toDouble();
      freq.add(f);
      mag.add(_peakDb(f, 90, 7, 1.0) + _peakDb(f, 4000, -6, 2.0));
    }
    final res = core.fitPeqFlat(
        measured: FreqResponse(freq, mag), fs: 48000, maxBands: 10);
    expect(res.bands, isNotEmpty);
    expect(res.initialErrorDb, greaterThan(1.0));
    expect(res.finalErrorDb, lessThan(res.initialErrorDb));
  });

  test('rew_recommend_crossover finds a driver band edges (bitmask + out-params)', () {
    // Band-limited driver: LR24 high-passed at 500 Hz, low-passed at 5 kHz.
    final freq = <double>[], mag = <double>[];
    for (var i = 0; i < 200; i++) {
      final f = 20 * math.pow(1000.0, i / 199).toDouble();
      final hp = math.pow(f / 500, 4) / (1 + math.pow(f / 500, 4));
      final lp = 1 / (1 + math.pow(f / 5000, 4));
      freq.add(f);
      mag.add(20 * (math.log(hp * lp) / math.ln10));
    }
    final rec = core.recommendCrossover(FreqResponse(freq, mag));
    expect(rec.highPassHz, isNotNull);
    expect(rec.lowPassHz, isNotNull);
    expect(rec.highPassHz!, inInclusiveRange(400, 620));
    expect(rec.lowPassHz!, inInclusiveRange(4000, 6200));
  });
}

/// Magnitude (dB) of a peaking filter centered at [f0], evaluated at [f].
double _peakDb(double f, double f0, double gainDb, double q) {
  const fs = 48000.0;
  final a = math.pow(10, gainDb / 40).toDouble();
  final w0 = 2 * math.pi * f0 / fs;
  final alpha = math.sin(w0) / (2 * q);
  final a0 = 1 + alpha / a;
  final b0 = (1 + alpha * a) / a0, b1 = (-2 * math.cos(w0)) / a0,
      b2 = (1 - alpha * a) / a0;
  final a1 = (-2 * math.cos(w0)) / a0, a2 = (1 - alpha / a) / a0;
  final w = 2 * math.pi * f / fs;
  final nRe = b0 + b1 * math.cos(w) + b2 * math.cos(2 * w);
  final nIm = -(b1 * math.sin(w) + b2 * math.sin(2 * w));
  final dRe = 1 + a1 * math.cos(w) + a2 * math.cos(2 * w);
  final dIm = -(a1 * math.sin(w) + a2 * math.sin(2 * w));
  return 20 * (math.log(math.sqrt(nRe * nRe + nIm * nIm) /
      math.sqrt(dRe * dRe + dIm * dIm)) / math.ln10);
}
