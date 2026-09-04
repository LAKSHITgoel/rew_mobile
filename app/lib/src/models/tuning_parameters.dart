// Every heuristic the tuning engine uses, in one named, serialisable place.
//
// This is what makes "the app learns over time" possible without a model ever
// writing DSP. The measurement maths stays in core/, deterministic and covered
// by tests; what can change is the handful of judgement calls sitting on top of
// it — how deep a cut is worth making, how much repeatability to demand, where
// the flat target sits. Those are opinions, they were arrived at by argument
// rather than derivation, and they are exactly what evidence from real cars
// should be allowed to revise.
//
// A proposal to change them is validated before it is adopted (see
// TuningParameters.problems), and adopting one is the user's decision.
class TuningParameters {
  const TuningParameters({
    this.maxCutDb = 6.0,
    this.maxBoostDb = 3.0,
    this.targetPercentile = 0.25,
    this.minSnrDb = 10.0,
    this.maxSpreadDb = 3.0,
    this.maxBands = 10,
    this.analysisSmoothFrac = 24.0,
    this.averagingPositions = 3,
  });

  /// Deepest cut a single band may apply. Past this the excess is reported as a
  /// channel level trim instead, because a very deep cut mutes a channel rather
  /// than correcting it.
  final double maxCutDb;

  /// Deepest boost. Kept low: a boost costs headroom everywhere, and a dip in a
  /// car is usually cancellation that swallows it.
  final double maxBoostDb;

  /// Where the flat target sits in the usable band's level distribution. Lower
  /// cuts peaks harder — flatter, but quieter overall.
  final double targetPercentile;

  /// How far above the noise floor a point must be to be worth correcting.
  final double minSnrDb;

  /// How much a feature may move between repeated captures and still be treated
  /// as a property of the car.
  final double maxSpreadDb;

  final int maxBands;

  /// Smoothing the fitter reads, independent of what is displayed.
  final double analysisSmoothFrac;

  /// Mic positions averaged per measurement.
  final int averagingPositions;

  static const TuningParameters defaults = TuningParameters();

  TuningParameters copyWith({
    double? maxCutDb,
    double? maxBoostDb,
    double? targetPercentile,
    double? minSnrDb,
    double? maxSpreadDb,
    int? maxBands,
    double? analysisSmoothFrac,
    int? averagingPositions,
  }) =>
      TuningParameters(
        maxCutDb: maxCutDb ?? this.maxCutDb,
        maxBoostDb: maxBoostDb ?? this.maxBoostDb,
        targetPercentile: targetPercentile ?? this.targetPercentile,
        minSnrDb: minSnrDb ?? this.minSnrDb,
        maxSpreadDb: maxSpreadDb ?? this.maxSpreadDb,
        maxBands: maxBands ?? this.maxBands,
        analysisSmoothFrac: analysisSmoothFrac ?? this.analysisSmoothFrac,
        averagingPositions: averagingPositions ?? this.averagingPositions,
      );

  /// Why a proposed set is not safe to adopt, or empty if it is.
  ///
  /// A model proposing changes is proposing them from a few dozen car
  /// measurements, and a plausible-sounding number can still be one that ruins
  /// a system — a 12 dB boost limit will burn an amplifier into a cancellation
  /// null however good the reasoning sounded. These bounds are not opinions
  /// that learning may revise; they are the edges of what the app will do.
  List<String> problems() {
    final out = <String>[];
    void check(bool ok, String message) {
      if (!ok) out.add(message);
    }

    check(maxCutDb > 0 && maxCutDb <= 12,
        'Deepest cut must be between 0 and 12 dB (got $maxCutDb).');
    check(maxBoostDb >= 0 && maxBoostDb <= 6,
        'Deepest boost must be between 0 and 6 dB (got $maxBoostDb). A larger '
        'boost burns headroom into a dip that is usually cancellation.');
    check(targetPercentile > 0 && targetPercentile < 1,
        'Target percentile must be between 0 and 1 (got $targetPercentile).');
    check(minSnrDb >= 3 && minSnrDb <= 30,
        'Signal-to-noise gate must be between 3 and 30 dB (got $minSnrDb). '
        'Below 3 dB the app would fit to noise.');
    check(maxSpreadDb > 0 && maxSpreadDb <= 12,
        'Repeatability limit must be between 0 and 12 dB (got $maxSpreadDb).');
    check(maxBands >= 1 && maxBands <= 31,
        'Band count must be between 1 and 31 (got $maxBands).');
    check(analysisSmoothFrac >= 3 && analysisSmoothFrac <= 96,
        'Analysis smoothing must be between 1/3 and 1/96 octave.');
    check(averagingPositions >= 1 && averagingPositions <= 10,
        'Averaged positions must be between 1 and 10.');
    return out;
  }

  bool get isValid => problems().isEmpty;

  /// The fields that differ from [other], for showing a proposal as a diff.
  Map<String, ({Object from, Object to})> diff(TuningParameters other) {
    final a = toJson(), b = other.toJson();
    final out = <String, ({Object from, Object to})>{};
    for (final k in a.keys) {
      if (a[k] != b[k]) out[k] = (from: a[k]!, to: b[k]!);
    }
    return out;
  }

  Map<String, Object> toJson() => {
        'maxCutDb': maxCutDb,
        'maxBoostDb': maxBoostDb,
        'targetPercentile': targetPercentile,
        'minSnrDb': minSnrDb,
        'maxSpreadDb': maxSpreadDb,
        'maxBands': maxBands,
        'analysisSmoothFrac': analysisSmoothFrac,
        'averagingPositions': averagingPositions,
      };

  factory TuningParameters.fromJson(Map<String, dynamic> j) => TuningParameters(
        maxCutDb: (j['maxCutDb'] as num?)?.toDouble() ?? defaults.maxCutDb,
        maxBoostDb: (j['maxBoostDb'] as num?)?.toDouble() ?? defaults.maxBoostDb,
        targetPercentile: (j['targetPercentile'] as num?)?.toDouble() ??
            defaults.targetPercentile,
        minSnrDb: (j['minSnrDb'] as num?)?.toDouble() ?? defaults.minSnrDb,
        maxSpreadDb:
            (j['maxSpreadDb'] as num?)?.toDouble() ?? defaults.maxSpreadDb,
        maxBands: (j['maxBands'] as num?)?.toInt() ?? defaults.maxBands,
        analysisSmoothFrac: (j['analysisSmoothFrac'] as num?)?.toDouble() ??
            defaults.analysisSmoothFrac,
        averagingPositions: (j['averagingPositions'] as num?)?.toInt() ??
            defaults.averagingPositions,
      );
}
