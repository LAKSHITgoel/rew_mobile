// A real saved tune from the phone, kept as a fixture. FileProjectStore skips
// any file that fails to parse, so a change to the model does not crash the
// app — it silently loses the user's tunes, which is worse.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/models/measurement.dart';
import 'package:rew_mobile/src/models/project.dart';

void main() {
  test('a tune saved by an earlier version still loads', () {
    final file = File('test/fixtures/legacy_tune.json');
    expect(file.existsSync(), isTrue, reason: 'fixture missing');

    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final project = TuneProject.fromJson(json);

    expect(project.name, isNotEmpty);
    expect(project.measured, isNotEmpty);
    // Fields added after this file was written must fall back, not throw.
    expect(project.noiseFloors, isEmpty);
    expect(project.targetPresetName, 'smooth');
    expect(project.expertMode, isFalse);

    // And it must survive a round trip through the current format.
    final again = TuneProject.fromJson(project.toJson());
    expect(again.measured.keys, project.measured.keys);
  });

  test('a band keeps its reason and confidence across a save', () {
    const band = PeqBand(
        freqHz: 3200,
        gainDb: -2.8,
        q: 1.4,
        reason: PeqReason.broadExcess,
        confidence: 0.91);
    final back = PeqBand.fromJson(band.toJson());
    expect(back.reason, PeqReason.broadExcess);
    expect(back.confidence, closeTo(0.91, 1e-9));
    // Bands saved before reasons existed must still load, just unexplained.
    final old = PeqBand.fromJson(const {'freqHz': 100.0, 'gainDb': -1.0, 'q': 2.0});
    expect(old.reason, PeqReason.unknown);
    expect(old.confidence, 0);
  });

  test('a tune missing any optional field still loads', () {
    // Every field added from here on will be absent from files already on
    // someone's phone. Dropping each one in turn is the cheap way to be sure a
    // future addition cannot quietly delete a tune.
    final full = jsonDecode(
        File('test/fixtures/legacy_tune.json').readAsStringSync()) as Map<String, dynamic>;
    final complete = TuneProject.fromJson(full).toJson();

    for (final key in complete.keys.toList()) {
      if (key == 'id' || key == 'name' || key == 'createdAt') continue;
      final pruned = Map<String, dynamic>.from(complete)..remove(key);
      expect(() => TuneProject.fromJson(pruned), returnsNormally,
          reason: 'a tune with no "$key" field fails to load, so it would be '
              'silently skipped and appear deleted');
    }
  });
}
