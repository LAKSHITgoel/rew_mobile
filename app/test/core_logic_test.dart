// Unit tests for the app's pure-Dart logic (no FFI / no platform channels).
// Run with `flutter test` on a machine with the Flutter SDK.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/models/measurement.dart';
import 'package:rew_mobile/src/models/mic_calibration.dart';
import 'package:rew_mobile/src/models/project.dart';
import 'package:rew_mobile/src/services/crossover_calc.dart';
import 'package:rew_mobile/src/services/dsp_math.dart';
import 'package:rew_mobile/src/services/project_store.dart';
import 'package:rew_mobile/src/services/time_align.dart';

void main() {
  group('crossover_calc', () {
    test('Linkwitz-Riley sum is flat', () {
      final s = summation(
          2500, XoverSlope.linkwitzRiley24, XoverSlope.linkwitzRiley24);
      expect(s.maxDeviationDb, lessThan(0.01));
    });

    test('each branch is -6 dB at the crossover', () {
      final lp = lowpassMag(2500, 2500, XoverSlope.linkwitzRiley24);
      expect(20 * (math.log(lp) / math.ln10), closeTo(-6.02, 0.05));
    });
  });

  group('dsp_math', () {
    test('peaking magnitude hits its gain at the band center', () {
      expect(
          peakingMagnitudeDb(evalHz: 1000, f0: 1000, fs: 48000, gainDb: 6, q: 2),
          closeTo(6.0, 0.05));
      // Far from center the effect is negligible.
      expect(
          peakingMagnitudeDb(evalHz: 50, f0: 1000, fs: 48000, gainDb: 6, q: 2),
          closeTo(0.0, 0.3));
    });

    test('EQ preview cancels a bump at its center', () {
      final freq = <double>[];
      final mag = <double>[];
      for (var i = 0; i < 101; i++) {
        final f = 20 * math.pow(1000.0 / 20, i / 100).toDouble();
        freq.add(f);
        // Measured curve = an +8 dB bump centered at 1 kHz.
        mag.add(peakingMagnitudeDb(
            evalHz: f, f0: 1000, fs: 48000, gainDb: 8, q: 2));
      }
      final measured = FreqResponse(freq, mag);
      final corrected = applyEqPreview(
          measured, const [PeqBand(freqHz: 1000, gainDb: -8, q: 2)], 48000);
      // Find the point nearest 1 kHz and check it's ~flat after correction.
      var best = 0;
      for (var i = 1; i < freq.length; i++) {
        if ((freq[i] - 1000).abs() < (freq[best] - 1000).abs()) best = i;
      }
      expect(corrected.magDb[best].abs(), lessThan(0.5));
    });
  });

  group('MicCalibration.parse', () {
    test('parses points and sensitivity', () {
      final cal = MicCalibration.parse(
          '* Sens Factor =-1.50dB\n20 0.5\n1000 0.0\n20000 -2.0\n');
      expect(cal.freqHz.length, 3);
      expect(cal.sensitivityDbFs, closeTo(-1.5, 1e-9));
      expect(cal.gainDb.last, closeTo(-2.0, 1e-9));
    });

    test('parses the real miniDSP quoted header', () {
      // Real UMIK-1 files start with a quoted header, not a comment marker.
      final cal = MicCalibration.parse(
          '"Sens Factor =-0.989dB, SERNO: 7165152"\n'
          '10.054\t-4.3217\n'
          '1000.000\t0.0000\n');
      expect(cal.freqHz.length, 2);
      expect(cal.sensitivityDbFs, closeTo(-0.989, 1e-9));
      expect(cal.gainDb.first, closeTo(-4.3217, 1e-9));
    });

    test('handles comma separators and comments', () {
      final cal = MicCalibration.parse('# header\n20,0.5\n1000,1.0\n');
      expect(cal.freqHz, [20, 1000]);
      expect(cal.gainDb, [0.5, 1.0]);
    });
  });

  group('time alignment', () {
    test('speed of sound tracks temperature', () {
      expect(speedOfSound(celsius: 20), closeTo(343.4, 0.1));
      expect(speedOfSound(celsius: 0), closeTo(331.3, 0.1));
      expect(speedOfSound(celsius: 35), greaterThan(speedOfSound(celsius: 15)));
    });

    test('farthest driver is the reference and gets no delay', () {
      final d = delaysFromDistancesCm({'near': 100, 'far': 200});
      expect(d['far'], 0.0);
      // 1 m of extra path at ~343.4 m/s is ~2.91 ms.
      expect(d['near'], closeTo(2.912, 0.01));
    });

    test('delays are clamped to what the DSP accepts', () {
      final d = delaysFromDistancesCm({'a': 1, 'b': 100000}, maxDelayMs: 20);
      expect(d['a'], 20.0);
    });

    test('ignores missing or nonsensical distances', () {
      final d = delaysFromDistancesCm({'a': 0, 'b': -5, 'c': 150});
      expect(d.keys, ['c']);
      expect(d['c'], 0.0);
    });
  });

  group('SweepBand', () {
    test('presets cover the drivers and are ordered low->high', () {
      expect(SweepBand.presets, contains(SweepBand.tweeter));
      expect(SweepBand.sub.fHi, lessThan(SweepBand.tweeter.fLo));
      for (final b in SweepBand.presets) {
        expect(b.fLo, lessThan(b.fHi));
      }
    });

    test('only the full-range band trips the tweeter warning', () {
      expect(SweepBand.full.isFullRange, isTrue);
      expect(SweepBand.tweeter.isFullRange, isFalse); // starts at 2 kHz
      expect(SweepBand.sub.isFullRange, isFalse);     // stops at 200 Hz
    });
  });

  group('JSON round-trips', () {
    test('FreqResponse', () {
      final fr = FreqResponse([20, 100, 1000], [-1, 0, 2]);
      final back = FreqResponse.fromJson(fr.toJson());
      expect(back.freqHz, fr.freqHz);
      expect(back.magDb, fr.magDb);
    });

    test('TuneProject with bands and crossovers', () {
      final p = TuneProject(
        id: '1',
        name: 'Car',
        createdAt: DateTime.parse('2026-01-01T00:00:00.000'),
        eqBands: {
          'system': const [PeqBand(freqHz: 80, gainDb: -3, q: 1.5)]
        },
        crossovers: [
          CrossoverSetting(
              channelId: 'fl_tweeter',
              highPassHz: 2500,
              lowPassHz: null,
              slope: XoverSlope.linkwitzRiley24)
        ],
      );
      final back = TuneProject.fromJson(p.toJson());
      expect(back.name, 'Car');
      expect(back.eqBands['system']!.first.freqHz, 80);
      expect(back.crossovers.first.highPassHz, 2500);
      expect(back.crossovers.first.slope, XoverSlope.linkwitzRiley24);
    });
  });

  group('MemoryProjectStore', () {
    test('save, list, delete', () async {
      final store = MemoryProjectStore();
      final p =
          TuneProject(id: 'a', name: 'A', createdAt: DateTime(2026, 1, 1));
      await store.save(p);
      expect((await store.list()).length, 1);
      await store.delete('a');
      expect((await store.list()), isEmpty);
    });
  });
}
