// Exercises MeasurementService end-to-end, including the BACKGROUND ISOLATE the
// DSP runs in. That path had no coverage: on a device it is the only way a
// measurement happens, but a plain Dart process cannot resolve the native
// library the way the app does, so the isolate silently had to be taken on
// trust. It is injected here instead.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
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

  test('resolution follows the smoothing instead of a fixed coarse grid', () {
    // 96 points across 20 Hz - 20 kHz is under 10 per octave: coarser than the
    // 1/24-octave smoothing being displayed, so the grid, not the measurement,
    // was the limit on visible detail.
    const oneTwentyFourth = MeasurementConfig(smoothFrac: 24);
    expect(oneTwentyFourth.gridPoints, greaterThan(400));
    const third = MeasurementConfig(smoothFrac: 3);
    expect(third.gridPoints, lessThan(oneTwentyFourth.gridPoints));
    // An explicit count still wins, for tests that want a small grid.
    expect(const MeasurementConfig(points: 96).gridPoints, 96);
  });

  test('a measurement carries a noise floor and computes SNR', () async {
    final m = await service.measureWithNoiseFloor(band: SweepBand.full);
    expect(m.noiseFloor, isNotNull);
    expect(m.noiseFloor!.length, m.response.length);
    final snr = m.snrDb;
    expect(snr, isNotNull);
    expect(snr!.length, m.response.length);
    // The mock plays a real sweep against silence, so the sweep must win.
    final median = ([...snr]..sort())[snr.length ~/ 2];
    expect(median, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('EQ never recommends a cut deeper than asked, and reports the trim',
      () async {
    // A wide bass excess, the shape that produced a -12 dB subwoofer band.
    const n = 200;
    final freq = <double>[];
    final mag = <double>[];
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      final f = math.exp(math.log(20) + t * (math.log(20000) - math.log(20)));
      freq.add(f);
      mag.add(f < 80 ? 14.0 : 0.0);
    }
    final eq = await service.fitEq(FreqResponse(freq, mag), maxCutDb: 6.0);
    expect(eq.bands, isNotEmpty);
    for (final b in eq.bands) {
      expect(b.gainDb, greaterThanOrEqualTo(-6.0001));
    }
    expect(eq.suggestedLevelTrimDb, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('EQ ignores the part of the curve that is only noise', () async {
    // Everything above 500 Hz marked untrustworthy, as a Bluetooth link that
    // gives out around 11 kHz would leave it.
    const n = 200;
    final freq = <double>[];
    final mag = <double>[];
    final valid = <bool>[];
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      final f = math.exp(math.log(20) + t * (math.log(20000) - math.log(20)));
      freq.add(f);
      // A real peak low down, plus loud garbage up high.
      mag.add(f < 100 ? 10.0 : (f > 500 ? (i.isEven ? 12.0 : -12.0) : 0.0));
      valid.add(f <= 500);
    }
    final eq =
        await service.fitEq(FreqResponse(freq, mag), valid: valid, maxBands: 8);
    expect(eq.bands, isNotEmpty);
    for (final b in eq.bands) {
      expect(b.freqHz, lessThanOrEqualTo(500),
          reason: 'placed a band in the noise-only region');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('every recommended band explains itself and carries a confidence',
      () async {
    const n = 200;
    final freq = <double>[];
    final mag = <double>[];
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      final f = math.exp(math.log(20) + t * (math.log(20000) - math.log(20)));
      freq.add(f);
      // A broad, obvious excess around 1 kHz.
      final d = math.log(f / 1000) / math.ln2;
      mag.add(6 * math.exp(-d * d / 0.5));
    }
    final eq = await service.fitEq(FreqResponse(freq, mag), maxBands: 5);
    expect(eq.bands, isNotEmpty);
    for (final b in eq.bands) {
      expect(b.reason, isNot(PeqReason.unknown),
          reason: 'a band with no reason is not a recommendation');
      expect(b.confidence, greaterThan(0));
      expect(b.confidence, lessThanOrEqualTo(1));
      expect(b.reason.explanation, isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a feature that did not repeat is reported, not corrected', () async {
    const n = 200;
    final freq = <double>[];
    final mag = <double>[];
    final spread = <double>[];
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      final f = math.exp(math.log(20) + t * (math.log(20000) - math.log(20)));
      freq.add(f);
      final d = math.log(f / 5000) / math.ln2;
      mag.add(8 * math.exp(-d * d / 0.5));
      // The 5 kHz region moved wildly between captures.
      spread.add(f > 3500 && f < 7000 ? 6.0 : 0.3);
    }
    final eq = await service.fitEq(FreqResponse(freq, mag),
        maxBands: 6, spreadDb: spread);
    for (final b in eq.bands) {
      expect(b.freqHz > 3500 && b.freqHz < 7000, isFalse,
          reason: 'corrected something that did not repeat');
    }
    expect(eq.declined.any((d) => d.reason == PeqReason.declinedUnrepeatable),
        isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('boosts are capped low, because a boost costs headroom everywhere',
      () async {
    const n = 200;
    final freq = <double>[];
    final mag = <double>[];
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      final f = math.exp(math.log(20) + t * (math.log(20000) - math.log(20)));
      freq.add(f);
      // A wide, deep deficit — the tempting case for a big boost.
      final d = math.log(f / 2000) / math.ln2;
      mag.add(-10 * math.exp(-d * d / 2.0));
    }
    final eq = await service.fitEq(FreqResponse(freq, mag), maxBands: 6);
    for (final b in eq.bands) {
      expect(b.gainDb, lessThanOrEqualTo(3.0001),
          reason: 'boost exceeded the conservative cap');
    }
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
