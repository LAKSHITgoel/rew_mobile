// The microphone calibration must survive a restart and reach everything that
// measures. It did neither: it could only be loaded inside a tune and was gone
// on relaunch, so most measurements were quietly taken uncalibrated — the mic's
// own several-dB deviation read as if the car had made it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/services/calibration_store.dart';

// A miniDSP file, including the quoted header line the real ones carry.
const _umikFile = '''
"Sens Factor =-.9450dB, SERNO: 7165152"
20.000  -1.5000
100.000 -0.4000
1000.000 0.0000
10000.000 1.8000
20000.000 3.2000
''';

void main() {
  test('a calibration survives being saved and loaded again', () async {
    final dir = Directory.systemTemp.createTempSync('rew_cal');
    addTearDown(() => dir.deleteSync(recursive: true));

    final store = FileCalibrationStore(dir);
    expect(await store.load(), isNull);

    await store.save('UMIK-1 7165152', _umikFile);

    // A fresh store, as the next launch would build.
    final reopened = await FileCalibrationStore(dir).load();
    expect(reopened, isNotNull);
    expect(reopened!.name, 'UMIK-1 7165152');
    expect(reopened.calibration.isEmpty, isFalse);
    expect(reopened.calibration.freqHz.first, 20);
    expect(reopened.calibration.gainDb.last, 3.2);
  });

  test('clearing it really clears it', () async {
    final dir = Directory.systemTemp.createTempSync('rew_cal_clear');
    addTearDown(() => dir.deleteSync(recursive: true));

    final store = FileCalibrationStore(dir);
    await store.save('mic', _umikFile);
    expect(await store.load(), isNotNull);
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('a damaged file gives no calibration rather than stopping the app',
      () async {
    final dir = Directory.systemTemp.createTempSync('rew_cal_bad');
    addTearDown(() => dir.deleteSync(recursive: true));

    File('${dir.path}/mic_calibration.txt').writeAsStringSync('not a mic file');
    // Must not throw: this runs at startup, before there is any UI to show an
    // error in.
    expect(await FileCalibrationStore(dir).load(), isNull);
  });

  test('the original file text is kept, not just the parsed points', () async {
    final dir = Directory.systemTemp.createTempSync('rew_cal_text');
    addTearDown(() => dir.deleteSync(recursive: true));

    await FileCalibrationStore(dir).save('mic', _umikFile);
    // So it can be checked against the file the microphone came with.
    expect(File('${dir.path}/mic_calibration.txt').readAsStringSync(),
        contains('SERNO: 7165152'));
  });
}
