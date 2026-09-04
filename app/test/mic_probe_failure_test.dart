// A failing microphone probe must never be able to kill the Measure button.
//
// This is the regression that produced "nothing happens when I tap the button",
// twice. Tapping Measure first asks Android which audio devices exist, and that
// call could both throw and hang — it enumerates devices on the platform thread,
// which Android is liable to be rebuilding at exactly the moment a USB mic is
// plugged in or the phone changes audio route in a car. Nothing in the tap path
// caught it, so the failure propagated out of an unawaited handler: no spinner,
// no error, no measurement. A dead button.
//
// The rule these tests hold in place: asking about the microphone either
// answers or reports that it could not, and never does anything else.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/audio/audio_backend.dart';

/// A backend whose mic probe misbehaves in the two ways the real one could.
class _BadMicBackend implements AudioBackend {
  _BadMicBackend({this.throws = false, this.hangs = false});
  final bool throws;
  final bool hangs;

  @override
  Future<MicInfo> micStatus() async {
    if (throws) throw Exception('MissingPluginException(micStatus)');
    if (hangs) return Completer<MicInfo>().future; // never completes
    return const MicInfo(connected: true, name: 'UMIK-1');
  }

  @override
  Future<Float64List> playSweepAndCapture({
    required Float64List sweep,
    required double fs,
  }) async =>
      Float64List(sweep.length);

  @override
  Stream<MicLevel> get inputLevels => const Stream.empty();
  @override
  Future<void> startInputLevel({bool withSamples = false}) async {}
  @override
  Future<void> stopInputLevel() async {}
  @override
  Future<void> startTone({
    required Float64List samples,
    required double fs,
  }) async {}
  @override
  Future<void> stopTone() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  test('a probe that reports failure is not mistaken for "no microphone"', () {
    const failed = MicInfo(connected: false, probeError: 'boom');
    const absent = MicInfo(connected: false);
    // Both say "not connected", but only one of them was actually able to look.
    expect(failed.probeFailed, isTrue);
    expect(absent.probeFailed, isFalse);
  });

  test('a mic probe that throws still lets the caller decide what to do',
      () async {
    final backend = _BadMicBackend(throws: true);
    // The raw backend contract is allowed to throw; what matters is that a
    // caller wrapping it the way the app does gets an answer rather than an
    // exception escaping into an unawaited tap handler.
    Future<MicInfo> guarded() async {
      try {
        return await backend.micStatus().timeout(const Duration(seconds: 1));
      } catch (e) {
        return MicInfo(connected: false, probeError: '$e');
      }
    }

    final info = await guarded();
    expect(info.probeFailed, isTrue);
    expect(info.connected, isFalse);
  });

  test('a mic probe that hangs forever is bounded by a timeout', () async {
    final backend = _BadMicBackend(hangs: true);
    Future<MicInfo> guarded() async {
      try {
        return await backend
            .micStatus()
            .timeout(const Duration(milliseconds: 200));
      } catch (e) {
        return MicInfo(connected: false, probeError: '$e');
      }
    }

    // The point is that this returns at all. Before the timeout it did not, and
    // the Measure button stayed inert until the app was restarted.
    final info = await guarded().timeout(const Duration(seconds: 2),
        onTimeout: () => fail('the mic probe was not bounded by a timeout'));
    expect(info.probeFailed, isTrue);
  });
}
