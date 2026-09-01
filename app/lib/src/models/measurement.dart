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
