// Exercises MeasurementService end-to-end, including the BACKGROUND ISOLATE the
// DSP runs in. That path had no coverage: on a device it is the only way a
// measurement happens, but a plain Dart process cannot resolve the native
// library the way the app does, so the isolate silently had to be taken on
// trust. It is injected here instead.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/audio/mock_audio_backend.dart';
import 'package:rew_mobile/src/ffi/rewcore.dart';
import 'package:rew_mobile/src/models/measurement.dart';
import 'package:rew_mobile/src/services/measurement_service.dart';

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
    test('measurement pipeline (skipped: library not built)', () {}, skip: true);
    return;
  }

  late MeasurementService service;
  setUp(() {
    service = MeasurementService(
      Rewcore.open(libraryPath: lib),
      MockAudioBackend(),
      libraryPath: lib,
    );
  });

  test('measureOnce completes through the isolate and returns a real curve',
      () async {
    final m = await service.measureOnce(band: SweepBand.full);
    expect(m.response.length, greaterThan(10));
    expect(m.response.freqHz.first, closeTo(20, 1));
    expect(m.levelDbfs, lessThan(0));
    // The mock injects a bass hump; the curve must not be flat or empty.
    final span = m.response.magDb.reduce((a, b) => a > b ? a : b) -
        m.response.magDb.reduce((a, b) => a < b ? a : b);
    expect(span, greaterThan(3));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a second measurement works too (cached sweep Future is reusable)',
      () async {
    await service.measureOnce(band: SweepBand.full);
    final second = await service.measureOnce(band: SweepBand.full);
    expect(second.response.length, greaterThan(10));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('measureAveraged and fitEq run through isolates', () async {
    final m = await service.measureAveraged(2, band: SweepBand.full);
    final eq = await service.fitEq(m.response, maxBands: 6);
    expect(eq.bands, isNotEmpty);
    expect(eq.finalErrorDb, lessThanOrEqualTo(eq.initialErrorDb));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a band-limited sweep is measured over that band only', () async {
    final m = await service.measureOnce(band: SweepBand.tweeter);
    expect(m.response.freqHz.first, closeTo(SweepBand.tweeter.fLo, 50));
    expect(m.response.freqHz.last, closeTo(SweepBand.tweeter.fHi, 200));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
