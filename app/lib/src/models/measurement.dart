// Plain data models shared across the app. Kept JSON-serializable so projects
// (a saved car tune) can be persisted and reopened.

/// A magnitude frequency response sampled on a (log) frequency grid.
class FreqResponse {
  FreqResponse(this.freqHz, this.magDb)
      : assert(freqHz.length == magDb.length);

  final List<double> freqHz;
  final List<double> magDb;

  bool get isEmpty => freqHz.isEmpty;
  int get length => freqHz.length;

  Map<String, dynamic> toJson() => {'freqHz': freqHz, 'magDb': magDb};

  factory FreqResponse.fromJson(Map<String, dynamic> j) => FreqResponse(
        (j['freqHz'] as List).map((e) => (e as num).toDouble()).toList(),
        (j['magDb'] as List).map((e) => (e as num).toDouble()).toList(),
      );
}

/// One parametric EQ band, as entered into the DSP's own app.
class PeqBand {
  const PeqBand({required this.freqHz, required this.gainDb, required this.q});

  final double freqHz;
  final double gainDb;
  final double q;

  Map<String, dynamic> toJson() => {'freqHz': freqHz, 'gainDb': gainDb, 'q': q};

  factory PeqBand.fromJson(Map<String, dynamic> j) => PeqBand(
        freqHz: (j['freqHz'] as num).toDouble(),
        gainDb: (j['gainDb'] as num).toDouble(),
        q: (j['q'] as num).toDouble(),
      );
}

/// The result of fitting parametric EQ to a measurement.
class EqResult {
  const EqResult({
    required this.bands,
    required this.initialErrorDb,
    required this.finalErrorDb,
  });

  final List<PeqBand> bands;
  final double initialErrorDb;
  final double finalErrorDb;
}

/// A frequency band to sweep and analyse.
///
/// Limiting the sweep to the driver under test matters for safety as much as
/// accuracy: a full-range sweep into a tweeter can destroy it, and sweeping a
/// sub above its passband just measures the rest of the car.
class SweepBand {
  const SweepBand(this.label, this.fLo, this.fHi);

  final String label;
  final double fLo;
  final double fHi;

  static const full = SweepBand('Full range · 20 Hz – 20 kHz', 20, 20000);
  static const sub = SweepBand('Subwoofer · 20 – 200 Hz', 20, 200);
  static const midbass = SweepBand('Mid / woofer · 50 Hz – 2 kHz', 50, 2000);
  static const midrange = SweepBand('Midrange · 200 Hz – 5 kHz', 200, 5000);
  static const tweeter = SweepBand('Tweeter · 2 – 20 kHz', 2000, 20000);

  /// True when the band starts low enough to endanger a tweeter.
  bool get isFullRange => fLo <= 100 && fHi >= 10000;

  static const presets = <SweepBand>[full, sub, midbass, midrange, tweeter];
}

/// Suggested crossover edges for one measured driver (from rewcore).
class CrossoverRecommendation {
  const CrossoverRecommendation({this.highPassHz, this.lowPassHz});
  final double? highPassHz;
  final double? lowPassHz;
}

/// Crossover slope options, mirroring rewcore's `Slope`.
enum XoverSlope { butterworth12, linkwitzRiley24, linkwitzRiley48 }

extension XoverSlopeLabel on XoverSlope {
  String get label => switch (this) {
        XoverSlope.butterworth12 => 'Butterworth 12 dB/oct',
        XoverSlope.linkwitzRiley24 => 'Linkwitz-Riley 24 dB/oct',
        XoverSlope.linkwitzRiley48 => 'Linkwitz-Riley 48 dB/oct',
      };
}

/// A speaker channel in the car, isolated (soloed in the DSP app) for measuring.
class Channel {
  const Channel(this.id, this.name);
  final String id;
  final String name;

  static const List<Channel> defaults = [
    Channel('fl_tweeter', 'Front L Tweeter'),
    Channel('fl_mid', 'Front L Midrange'),
    Channel('fr_tweeter', 'Front R Tweeter'),
    Channel('fr_mid', 'Front R Midrange'),
    Channel('rl', 'Rear L (coax)'),
    Channel('rr', 'Rear R (coax)'),
    Channel('sub', 'Subwoofer'),
  ];
}
