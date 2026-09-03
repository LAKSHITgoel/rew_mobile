// Exercises MeasurementService end-to-end, including the BACKGROUND ISOLATE the
// DSP runs in. That path had no coverage: on a device it is the only way a
// measurement happens, but a plain Dart process cannot resolve the native
// library the way the app does, so the isolate silently had to be taken on
// trust. It is injected here instead.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

  // Regression: the native capture blocks in AudioRecord.read(), which never
  // returns if the USB mic goes away mid-sweep. Without a timeout the Future
  // never completed, the wizard's `busy` flag latched on, and every Measure
  // button stayed disabled — reported from the car as "nothing happens when I
  // tap the button".
  test('a capture that never returns fails instead of hanging forever',
      () async {
    final stalled = MeasurementService(
      Rewcore.open(libraryPath: lib),
      _StalledBackend(),
      libraryPath: lib,
      captureTimeout: const Duration(milliseconds: 300),
    );
    await expectLater(
      stalled.measureOnce(band: SweepBand.full),
      throwsA(isA<TimeoutException>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a failed capture does not poison later measurements', () async {
    final flaky = _FlakyBackend();
    final svc = MeasurementService(
      Rewcore.open(libraryPath: lib),
      flaky,
      libraryPath: lib,
      captureTimeout: const Duration(seconds: 30),
    );
    await expectLater(svc.measureOnce(band: SweepBand.full), throwsA(anything));
    // The sweep cache holds Futures; a rejected one used to be handed to every
    // later call, so the app could only be recovered by restarting it.
    final m = await svc.measureOnce(band: SweepBand.full);
    expect(m.response.length, greaterThan(10));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// A backend whose capture never completes, like a mic that was unplugged.
class _StalledBackend extends MockAudioBackend {
  @override
  Future<Float64List> playSweepAndCapture(
          {required Float64List sweep, required double fs}) =>
      Completer<Float64List>().future;
}

/// Fails the first capture, then behaves.
class _FlakyBackend extends MockAudioBackend {
  int _calls = 0;
  @override
  Future<Float64List> playSweepAndCapture(
      {required Float64List sweep, required double fs}) {
    if (_calls++ == 0) {
      return Future.error(StateError('microphone returned no audio'));
    }
    return super.playSweepAndCapture(sweep: sweep, fs: fs);
  }
}
