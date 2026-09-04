// Where the microphone's calibration lives.
//
// It belongs to the microphone, not to a car, a tune or a session — so it is
// stored once, at app level, and applied to everything that measures. Loading
// it inside one tune and losing it on restart, which is what happened before,
// meant most measurements were quietly taken with an uncalibrated UMIK-1: the
// mic's own response, several dB from flat at the extremes, was being read as
// the car's.
import 'dart:io';

import '../models/mic_calibration.dart';

class StoredCalibration {
  const StoredCalibration(this.name, this.calibration);

  /// The file it came from, so the app can show which mic this is. UMIK-1
  /// files are named for the microphone's serial number, and a calibration
  /// from a different mic is worse than none.
  final String name;
  final MicCalibration calibration;
}

abstract class CalibrationStore {
  Future<StoredCalibration?> load();
  Future<void> save(String name, String fileContents);
  Future<void> clear();
}

class FileCalibrationStore implements CalibrationStore {
  FileCalibrationStore(this.dir);
  final Directory dir;

  File get _file => File('${dir.path}/mic_calibration.txt');
  File get _nameFile => File('${dir.path}/mic_calibration_name.txt');

  @override
  Future<StoredCalibration?> load() async {
    if (!_file.existsSync()) return null;
    try {
      final cal = MicCalibration.parse(await _file.readAsString());
      if (cal.isEmpty) return null;
      final name = _nameFile.existsSync()
          ? await _nameFile.readAsString()
          : 'microphone calibration';
      return StoredCalibration(name, cal);
    } catch (_) {
      // A damaged file must not stop the app starting; it just means no
      // calibration, which the UI says plainly.
      return null;
    }
  }

  @override
  Future<void> save(String name, String fileContents) async {
    if (!dir.existsSync()) await dir.create(recursive: true);
    // The original text is kept rather than the parsed points: it is what the
    // user can check against the file the mic came with.
    await _file.writeAsString(fileContents, flush: true);
    await _nameFile.writeAsString(name, flush: true);
  }

  @override
  Future<void> clear() async {
    if (_file.existsSync()) await _file.delete();
    if (_nameFile.existsSync()) await _nameFile.delete();
  }
}

class MemoryCalibrationStore implements CalibrationStore {
  StoredCalibration? _held;

  @override
  Future<StoredCalibration?> load() async => _held;

  @override
  Future<void> save(String name, String fileContents) async {
    final cal = MicCalibration.parse(fileContents);
    _held = cal.isEmpty ? null : StoredCalibration(name, cal);
  }

  @override
  Future<void> clear() async => _held = null;
}
