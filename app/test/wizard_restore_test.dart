// Reopening a saved tune must put the measurement back on screen. The data was
// being persisted correctly and then simply not read back, so a reopened tune
// showed its EQ table above an empty space where its graph belonged.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/audio/mock_audio_backend.dart';
import 'package:rew_mobile/src/models/measurement.dart';
import 'package:rew_mobile/src/models/project.dart';
import 'package:rew_mobile/src/services/measurement_service.dart';
import 'package:rew_mobile/src/services/project_store.dart';
import 'package:rew_mobile/src/ffi/rewcore.dart';
import 'package:rew_mobile/src/wizard/wizard_controller.dart';

String? _findLib() {
  final ext = Platform.isMacOS ? 'dylib' : (Platform.isWindows ? 'dll' : 'so');
  final name = Platform.isWindows ? 'rewcore_ffi.$ext' : 'librewcore_ffi.$ext';
  for (final dir in ['../build-ffi', 'build-ffi']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}

void main() {
  final lib = _findLib();
  if (lib == null) {
    test('wizard restore (skipped: library not built)', () {}, skip: true);
    return;
  }
  final core = Rewcore.open(libraryPath: lib);
  test('a saved measurement and EQ come back when the tune is reopened', () {
    final project = TuneProject(
        id: 't1', name: 'nexon', createdAt: DateTime(2026, 9, 3))
      ..measured['system'] = FreqResponse([20, 100, 1000], [-3, 0, -6])
      ..levelsDbfs['system'] = -14.8
      ..eqBands['system'] = [
        const PeqBand(freqHz: 51, gainDb: -6, q: 3),
      ];

    final c = WizardController(
      service: MeasurementService(core, MockAudioBackend()),
      store: MemoryProjectStore(),
      project: project,
    );

    expect(c.lastMeasurement, isNotNull);
    expect(c.lastMeasurement!.length, 3);
    expect(c.lastMeasurementFull?.levelDbfs, -14.8);
    expect(c.lastEq?.bands.single.freqHz, 51);
  });

  test('the target curve is saved with the tune and restored', () {
    // The target is the listener's preference, not a property of the car:
    // silently reverting it on reopen would change every recommendation.
    final project = TuneProject(
        id: 't3', name: 'warm car', createdAt: DateTime(2026, 9, 4))
      ..targetPresetName = 'warm';

    final round = TuneProject.fromJson(project.toJson());
    expect(round.targetPresetName, 'warm');

    final c = WizardController(
      service: MeasurementService(core, MockAudioBackend()),
      store: MemoryProjectStore(),
      project: round,
    );
    expect(c.targetPreset, TargetPreset.warm);
    expect(c.targetShape.bassShelfDb, TargetPreset.warm.shape.bassShelfDb);
  });

  test('a tune saved before target curves existed defaults sensibly', () {
    // Older saved tunes have no target field at all.
    final json = TuneProject(
            id: 't4', name: 'old', createdAt: DateTime(2026, 9, 1))
        .toJson()
      ..remove('targetPreset')
      ..remove('customTarget');
    final restored = TuneProject.fromJson(json);
    expect(restored.targetPresetName, 'smooth');
  });

  test('the beginner/expert choice is saved with the tune', () {
    final project = TuneProject(
        id: 't5', name: 'expert', createdAt: DateTime(2026, 9, 4))
      ..expertMode = true;
    final round = TuneProject.fromJson(project.toJson());
    expect(round.expertMode, isTrue);

    final c = WizardController(
      service: MeasurementService(core, MockAudioBackend()),
      store: MemoryProjectStore(),
      project: round,
    );
    expect(c.expertMode, isTrue);
  });

  test('a tune with nothing measured yet stays empty', () {
    final c = WizardController(
      service: MeasurementService(core, MockAudioBackend()),
      store: MemoryProjectStore(),
      project: TuneProject(
          id: 't2', name: 'fresh', createdAt: DateTime(2026, 9, 3)),
    );
    expect(c.lastMeasurement, isNull);
    expect(c.lastEq, isNull);
  });
}
