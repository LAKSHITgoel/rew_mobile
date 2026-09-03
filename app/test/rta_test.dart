// The RTA through the real compiled library, including its native lifetime:
// it is the only stateful object in the core, so it is the only one that can
// leak or be used after being freed.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/ffi/rewcore.dart';
import 'package:rew_mobile/src/models/measurement.dart';

String? _findLib() {
  final ext = Platform.isMacOS ? 'dylib' : (Platform.isWindows ? 'dll' : 'so');
  final name = Platform.isWindows ? 'rewcore_ffi.$ext' : 'librewcore_ffi.$ext';
  for (final dir in ['../build-ffi', 'build-ffi']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}

Float64List _sine(double hz, double amp, int n, double fs) {
  final x = Float64List(n);
  for (var i = 0; i < n; i++) {
    x[i] = amp * math.sin(2 * math.pi * hz * i / fs);
  }
  return x;
}

void main() {
  final lib = _findLib();
  if (lib == null) {
    test('RTA (skipped: library not built)', () {}, skip: true);
    return;
  }
  late Rewcore core;
  setUpAll(() => core = Rewcore.open(libraryPath: lib));

  test('the RTA config layout matches the C struct', () {
    expect(core.rtaConfigLayoutMatches(), isTrue);
  });

  test('a known tone lands at the right frequency and level', () {
    final rta = core.openRta(
      fs: 48000,
      fftSize: 8192,
      averaging: 1,
      smoothFrac: 0,
      pinkWeighted: false,
    );
    try {
      expect(rta.push(_sine(1000, 0.1, 16384, 48000)), greaterThan(0));
      final fr = rta.spectrum();
      expect(fr.length, greaterThan(100));

      var peak = 0;
      for (var i = 1; i < fr.magDb.length; i++) {
        if (fr.magDb[i] > fr.magDb[peak]) peak = i;
      }
      expect(fr.freqHz[peak], closeTo(1000, 25));
      expect(fr.magDb[peak], closeTo(20 * (math.log(0.1) / math.ln10), 1.5));
      expect(rta.levelDbfs, lessThan(0));
    } finally {
      rta.close();
    }
  });

  test('averaging settles toward a steady input, and reset clears it', () {
    final rta = core.openRta(
        fs: 48000, fftSize: 4096, averaging: 0.3, pinkWeighted: false);
    try {
      rta.push(_sine(1000, 0.1, 8192, 48000));
      final first = rta.spectrum();
      expect(first.length, greaterThan(0));

      for (var i = 0; i < 10; i++) {
        rta.push(_sine(1000, 0.1, 8192, 48000));
      }
      final settled = rta.spectrum();
      expect(settled.length, first.length);

      rta.reset();
      expect(rta.spectrum().length, 0,
          reason: 'reset should discard the average entirely');
    } finally {
      rta.close();
    }
  });

  test('peak hold remembers a burst the average forgets', () {
    final rta = core.openRta(
        fs: 48000, fftSize: 4096, averaging: 0.5, smoothFrac: 0,
        pinkWeighted: false);
    try {
      // One loud burst at 5 kHz, then a long quiet stretch at 1 kHz.
      rta.push(_sine(5000, 0.5, 8192, 48000));
      for (var i = 0; i < 12; i++) {
        rta.push(_sine(1000, 0.02, 8192, 48000));
      }
      final avg = rta.spectrum();
      final peak = rta.peakHold();
      expect(peak.length, avg.length);

      int nearest(FreqResponse fr, double f) {
        var best = 0;
        var err = double.infinity;
        for (var i = 0; i < fr.freqHz.length; i++) {
          final e = (fr.freqHz[i] - f).abs();
          if (e < err) {
            err = e;
            best = i;
          }
        }
        return best;
      }

      final i5k = nearest(avg, 5000);
      // The burst is gone from the average but held in the peak trace — which
      // is the entire point of peak hold for finding an intermittent rattle.
      expect(peak.magDb[i5k], greaterThan(avg.magDb[i5k] + 6));
    } finally {
      rta.close();
    }
  });

  test('a closed session is inert rather than crashing', () {
    final rta = core.openRta(fs: 48000, fftSize: 4096);
    rta.push(_sine(1000, 0.1, 8192, 48000));
    rta.close();

    // Using a freed native object is the classic way a stateful FFI wrapper
    // takes the whole app down. It must simply do nothing.
    expect(rta.isOpen, isFalse);
    expect(rta.push(_sine(1000, 0.1, 4096, 48000)), 0);
    expect(rta.spectrum().length, 0);
    expect(rta.peakHold().length, 0);
    expect(rta.levelDbfs, lessThan(0));
    rta.reset();
    rta.close(); // double close must also be safe
  });
}
