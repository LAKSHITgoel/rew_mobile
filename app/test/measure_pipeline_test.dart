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

  test('a target curve changes what the EQ aims at', () async {
    // A perfectly flat measurement. Against a reference target there is nothing
    // to do; against a warm one the app should ask for bass, because flat is
    // not the goal in a car.
    const n = 200;
    final freq = <double>[];
    final mag = <double>[];
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      freq.add(math.exp(math.log(20) + t * (math.log(20000) - math.log(20))));
      mag.add(0);
    }
    final flat = FreqResponse(freq, mag);

    final neutral = await service.fitEq(flat,
        maxBands: 6, target: TargetPreset.reference.shape);
    expect(neutral.bands, isEmpty,
        reason: 'a flat response already meets a flat target');

    final warm = await service.fitEq(flat,
        maxBands: 6, target: TargetPreset.warm.shape);
    expect(warm.bands, isNotEmpty);
    expect(warm.bands.any((b) => b.freqHz < 150 && b.gainDb > 0.5), isTrue,
        reason: 'a warm target should ask for bass');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('target presets are ordered from neutral to most coloured', () {
    expect(TargetPreset.reference.shape.bassShelfDb, 0);
    expect(TargetPreset.warm.shape.bassShelfDb,
        greaterThan(TargetPreset.smooth.shape.bassShelfDb));
    // Energetic keeps more top end than warm does.
    expect(TargetPreset.energetic.shape.tiltDbPerOctave,
        greaterThan(TargetPreset.warm.shape.tiltDbPerOctave));
    for (final p in TargetPreset.values) {
      expect(p.description, isNotEmpty);
    }
  });

  test('display smoothing does not coarsen what the EQ fitter reads', () async {
    // Setting the display to 1/3 octave is a reading choice. It must not change
    // the curve filters are decided from, or the EQ would be fitted to a
    // picture rather than to the measurement.
    final coarse = MeasurementService(
      Rewcore.open(libraryPath: lib),
      MockAudioBackend(),
      libraryPath: lib,
      config: const MeasurementConfig(smoothFrac: 3),
    );
    final m = await coarse.measureOnce(band: SweepBand.full);
    expect(m.analysisResponse.length, m.response.length);

    var differs = false;
    for (var i = 0; i < m.response.length; i++) {
      if ((m.response.magDb[i] - m.analysisResponse.magDb[i]).abs() > 1e-9) {
        differs = true;
        break;
      }
    }
    expect(differs, isTrue,
        reason: 'the analysis curve is just the display curve again');

    // The invariant that matters: changing the display setting must leave the
    // curve the fitter reads alone. Same grid on both so they are comparable.
    final fine = MeasurementService(
      Rewcore.open(libraryPath: lib),
      MockAudioBackend(),
      libraryPath: lib,
      config: const MeasurementConfig(smoothFrac: 24, points: 240),
    );
    final broad = MeasurementService(
      Rewcore.open(libraryPath: lib),
      MockAudioBackend(),
      libraryPath: lib,
      config: const MeasurementConfig(smoothFrac: 3, points: 240),
    );
    final a = await fine.measureOnce(band: SweepBand.full);
    final b = await broad.measureOnce(band: SweepBand.full);

    var displayDiffers = false;
    for (var i = 0; i < a.response.length; i++) {
      expect(a.analysisResponse.magDb[i],
          closeTo(b.analysisResponse.magDb[i], 1e-6),
          reason: 'display smoothing leaked into the analysis curve');
      if ((a.response.magDb[i] - b.response.magDb[i]).abs() > 0.01) {
        displayDiffers = true;
      }
    }
    expect(displayDiffers, isTrue,
        reason: 'the display smoothing setting did nothing');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a crossover recommendation explains itself and separates acoustic '
      'from electrical slope', () {
    final core = Rewcore.open(libraryPath: lib);
    // A driver already rolling off steeply either side.
    const n = 200;
    final freq = <double>[];
    final mag = <double>[];
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      final f = math.exp(math.log(20) + t * (math.log(20000) - math.log(20)));
      freq.add(f);
      // ~24 dB/oct either side of a 500 Hz - 5 kHz passband.
      var db = 0.0;
      if (f < 500) db = -24 * (math.log(500 / f) / math.ln2);
      if (f > 5000) db = -24 * (math.log(f / 5000) / math.ln2);
      mag.add(db);
    }
    final rec = core.recommendCrossover(FreqResponse(freq, mag));

    expect(rec.highPass.present, isTrue);
    expect(rec.lowPass.present, isTrue);
    expect(rec.highPass.reason, CrossoverReason.measuredRolloff);

    // It must measure the driver's own roll-off rather than assume it...
    expect(rec.highPass.acousticSlopeDbPerOct, greaterThan(10));
    // ...and therefore ask the DSP for less than the full target.
    expect(rec.highPass.electricalSlopeDbPerOct, lessThan(24));

    // Margin: high-pass above the measured edge, low-pass below it.
    expect(rec.highPass.recommendedHz, greaterThan(rec.highPass.freqHz));
    expect(rec.lowPass.recommendedHz, lessThan(rec.lowPass.freqHz));

    expect(rec.highPass.confidence, greaterThan(0));
    expect(rec.highPass.strength, isNotEmpty);
  });

  test('a full-range driver gets no invented crossover', () {
    final core = Rewcore.open(libraryPath: lib);
    const n = 200;
    final freq = <double>[];
    final mag = <double>[];
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      freq.add(math.exp(math.log(20) + t * (math.log(20000) - math.log(20))));
      mag.add(0);
    }
    final rec = core.recommendCrossover(FreqResponse(freq, mag));
    expect(rec.highPass.present, isFalse);
    expect(rec.lowPass.present, isFalse);
    expect(rec.highPass.reason, CrossoverReason.stillStrongAtLimit);
    expect(rec.highPass.reason.explanation, contains('sweep'));
  });

  test('a clipped capture is refused, not measured', () async {
    final svc = MeasurementService(
      Rewcore.open(libraryPath: lib),
      _ClippedBackend(),
      libraryPath: lib,
      captureTimeout: const Duration(seconds: 30),
    );
    await expectLater(svc.measureOnce(band: SweepBand.full),
        throwsA(isA<BadCaptureException>()));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a silent capture is refused, and says what to check', () async {
    final svc = MeasurementService(
      Rewcore.open(libraryPath: lib),
      _SilentBackend(),
      libraryPath: lib,
      captureTimeout: const Duration(seconds: 30),
    );
    try {
      await svc.measureOnce(band: SweepBand.full);
      fail('a silent capture must not produce a measurement');
    } on BadCaptureException catch (e) {
      expect(e.quality.usable, isFalse);
      expect(e.toString(), isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a good capture is reported as usable', () async {
    final m = await service.measureOnce(band: SweepBand.full);
    expect(m.quality, isNotNull);
    expect(m.quality!.usable, isTrue);
    expect(m.quality!.problem, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the same finding can be said two ways, and both name the same fix', () {
    const cut = PeqBand(
        freqHz: 3200,
        gainDb: -2.8,
        q: 1.4,
        reason: PeqReason.broadExcess,
        confidence: 0.91);

    final expert = cut.expertLine();
    expect(expert, contains('3.2 kHz'));
    expect(expert, contains('-2.8'));
    expect(expert, contains('Q 1.40'));
    expect(expert, contains('broad repeatable excess'));
    expect(expert, contains('91%'));

    final plain = cut.beginnerLine();
    expect(plain, contains('3.2 kHz'));
    expect(plain, contains('presence'));
    expect(plain, contains('too much energy'));
    expect(plain, contains('Cut it by 2.8 dB'));
    // The plain wording must not leak jargon it does not explain.
    expect(plain.contains('Q '), isFalse);

    const boost = PeqBand(
        freqHz: 80,
        gainDb: 3,
        q: 1,
        reason: PeqReason.broadDeficit,
        confidence: 0.7);
    expect(boost.beginnerLine(), contains('bass'));
    expect(boost.beginnerLine(), contains('Lift it by 3.0 dB'));
  });
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

/// Returns a capture that slammed into full scale.
class _ClippedBackend extends MockAudioBackend {
  @override
  Future<Float64List> playSweepAndCapture(
      {required Float64List sweep, required double fs}) async {
    final rec = await super.playSweepAndCapture(sweep: sweep, fs: fs);
    for (var i = 0; i < rec.length; i++) {
      rec[i] = (rec[i] * 50).clamp(-1.0, 1.0);
    }
    return rec;
  }
}

/// Returns silence, as an unplugged mic or a muted channel would.
class _SilentBackend extends MockAudioBackend {
  @override
  Future<Float64List> playSweepAndCapture(
          {required Float64List sweep, required double fs}) async =>
      Float64List(sweep.length);
}

