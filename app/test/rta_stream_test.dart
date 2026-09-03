// The RTA end to end from the audio stream, with the mock backend standing in
// for the mic. Covers the wiring most likely to break silently: that samples
// actually reach the analyser, and that leaving the screen releases the mic.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/audio/mock_audio_backend.dart';
import 'package:rew_mobile/src/ffi/rewcore.dart';
import 'package:rew_mobile/src/wizard/rta_controller.dart';

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
    test('RTA stream (skipped: library not built)', () {}, skip: true);
    return;
  }

  test('live samples reach the analyser and produce a spectrum', () async {
    final c = RtaController(
      audio: MockAudioBackend(),
      core: Rewcore.open(libraryPath: lib),
    );
    addTearDown(c.dispose);

    await c.start();
    expect(c.running, isTrue);

    // The mock emits a block every 50 ms; 16384 samples at 2400 per block needs
    // about seven of them before the first spectrum exists.
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (c.spectrum.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(c.spectrum.isEmpty, isFalse,
        reason: 'no spectrum arrived: samples are not reaching the analyser');
    expect(c.spectrum.length, greaterThan(50));
    expect(c.levelDbfs, lessThan(0));

    await c.stop();
    expect(c.running, isFalse);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('stopping releases the analyser, and stopping twice is safe', () async {
    final c = RtaController(
      audio: MockAudioBackend(),
      core: Rewcore.open(libraryPath: lib),
    );
    addTearDown(c.dispose);

    await c.start();
    await c.stop();
    // A second stop must not touch the freed native analyser — the swept
    // measurement needs the mic back afterwards, so this path runs every time.
    await c.stop();
    expect(c.running, isFalse);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('changing settings while running keeps it running', () async {
    final c = RtaController(
      audio: MockAudioBackend(),
      core: Rewcore.open(libraryPath: lib),
    );
    addTearDown(c.dispose);

    await c.start();
    await c.reconfigure(speed: RtaSpeed.fast, pinkWeighted: false);
    expect(c.running, isTrue);
    expect(c.speed, RtaSpeed.fast);
    expect(c.pinkWeighted, isFalse);
    await c.stop();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
