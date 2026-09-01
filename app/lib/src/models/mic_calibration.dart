// Parsed miniDSP UMIK-1 calibration file. The format is one "freq gain [phase]" pair
// per line; lines starting with * / # / ; are comments, except a header line carrying
// "Sens Factor =<x>dB". Whitespace- or comma-separated. Mirrors rewcore's parser so
// the same file works in the app and the CLI.
class MicCalibration {
  MicCalibration({
    required this.freqHz,
    required this.gainDb,
    this.sensitivityDbFs,
  });

  final List<double> freqHz;
  final List<double> gainDb;
  final double? sensitivityDbFs;

  bool get isEmpty => freqHz.isEmpty;

  static MicCalibration parse(String text) {
    final freq = <double>[];
    final gain = <double>[];
    double? sens;

    for (var raw in text.split('\n')) {
      final line = raw.replaceAll(',', ' ').trim();
      if (line.isEmpty) continue;
      final c = line[0];
      if (c == '*' || c == '#' || c == ';') {
        final idx = line.indexOf('Sens Factor');
        if (idx >= 0) {
          final eq = line.indexOf('=', idx);
          if (eq >= 0) {
            final m = RegExp(r'[-+]?\d*\.?\d+').firstMatch(line.substring(eq + 1));
            if (m != null) sens = double.tryParse(m.group(0)!);
          }
        }
        continue;
      }
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final f = double.tryParse(parts[0]);
        final g = double.tryParse(parts[1]);
        if (f != null && g != null) {
          freq.add(f);
          gain.add(g);
        }
      }
    }
    return MicCalibration(freqHz: freq, gainDb: gain, sensitivityDbFs: sens);
  }
}
