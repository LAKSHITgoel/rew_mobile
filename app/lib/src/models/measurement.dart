// Plain data models shared across the app. Kept JSON-serializable so projects
// (a saved car tune) can be persisted and reopened.

/// A magnitude frequency response sampled on a (log) frequency grid.
class FreqResponse {
  FreqResponse(this.freqHz, this.magDb, [this.phaseDeg = const []])
      : assert(freqHz.length == magDb.length);

  final List<double> freqHz;
  final List<double> magDb;

  /// Unwrapped phase in degrees. Empty where phase is not meaningful (e.g. after
  /// power-averaging spatially separated captures, which discards it).
  final List<double> phaseDeg;

  bool get hasPhase => phaseDeg.length == freqHz.length;
  bool get isEmpty => freqHz.isEmpty;
  int get length => freqHz.length;

  Map<String, dynamic> toJson() =>
      {'freqHz': freqHz, 'magDb': magDb, 'phaseDeg': phaseDeg};

  factory FreqResponse.fromJson(Map<String, dynamic> j) => FreqResponse(
        (j['freqHz'] as List).map((e) => (e as num).toDouble()).toList(),
        (j['magDb'] as List).map((e) => (e as num).toDouble()).toList(),
        ((j['phaseDeg'] ?? const []) as List)
            .map((e) => (e as num).toDouble())
            .toList(),
      );
}

/// What a capture looked like before anything was inferred from it.
class CaptureQuality {
  const CaptureQuality({
    required this.peak,
    required this.rmsDbfs,
    required this.clippedFraction,
    required this.silentFraction,
    required this.clipped,
    required this.tooQuiet,
    required this.mostlySilent,
  });

  final double peak;
  final double rmsDbfs;
  final double clippedFraction;
  final double silentFraction;
  final bool clipped;
  final bool tooQuiet;
  final bool mostlySilent;

  bool get usable => !clipped && !tooQuiet && !mostlySilent;

  /// What went wrong and what to do about it. A bad measurement must never
  /// become a recommendation, so this is phrased as an instruction.
  String? get problem {
    if (clipped) {
      return 'The recording clipped (${(clippedFraction * 100).toStringAsFixed(1)}% '
          'of it hit full scale). Every level in the result would be wrong. '
          'Turn the system volume down and measure again.';
    }
    if (tooQuiet) {
      return 'The recording came back at ${rmsDbfs.toStringAsFixed(1)} dBFS — '
          'far too quiet to measure anything. Check the mic is plugged in and '
          'the sweep is actually playing through the car, then turn the volume up.';
    }
    if (mostlySilent) {
      return '${(silentFraction * 100).round()}% of the recording is silence, so '
          'the sweep mostly did not arrive. Usually this means a different '
          'channel was playing than the one being measured, or the audio '
          'dropped out mid-sweep.';
    }
    return null;
  }
}

/// The two curves a measurement produces: one to look at, one to fit against.
class MeasuredCurves {
  const MeasuredCurves({required this.display, required this.analysis});

  /// Smoothed however the user asked. This is what is drawn and exported.
  final FreqResponse display;

  /// Smoothed at a fixed fine setting, whatever the display is set to. The EQ
  /// fitter reads this: deciding filters from a heavily smoothed curve hides
  /// the shape of what is being corrected.
  final FreqResponse analysis;
}

/// A capture: its magnitude response plus how loud it actually was.
///
/// The level is what lets you match drivers to each other and confirm you
/// measured at a sane volume; it is dBFS, which becomes dB SPL once an offset
/// has been calibrated (differences between channels need no offset at all).
class Measurement {
  const Measurement({
    required this.response,
    required this.levelDbfs,
    this.noiseFloor,
    this.spreadDb = const [],
    this.quality,
    FreqResponse? analysis,
  }) : _analysis = analysis;

  /// What the raw capture looked like. Null for measurements made before this
  /// was checked.
  final CaptureQuality? quality;

  final FreqResponse? _analysis;

  /// The curve the EQ fitter should read: smoothed at a fixed fine setting
  /// rather than at whatever the display is set to. Falls back to [response]
  /// for measurements made before the two were separated.
  FreqResponse get analysisResponse => _analysis ?? response;

  /// Per-point standard deviation across the repeated captures that were
  /// averaged into [response]. Empty when only one capture was taken, which is
  /// itself meaningful: nothing has been shown to repeat.
  final List<double> spreadDb;
  final FreqResponse response;
  final double levelDbfs;

  /// The same analysis run on a capture with nothing played, so it lands in the
  /// same units as [response]: what the car's own noise (engine, HVAC, road,
  /// the Bluetooth link) would have looked like had it been the signal.
  ///
  /// Everything the sweep did not clear is not a measurement of the car — it is
  /// a picture of the noise. Without this the app drew that noise as if it were
  /// a response and then recommended EQ from it.
  final FreqResponse? noiseFloor;

  /// Signal-to-noise in dB at each point of [response], or null if no noise
  /// floor was captured.
  List<double>? get snrDb {
    final nf = noiseFloor;
    if (nf == null || nf.length != response.length) return null;
    return [
      for (var i = 0; i < response.length; i++) response.magDb[i] - nf.magDb[i]
    ];
  }

  /// Points whose SNR clears [minSnrDb]. These are the only ones worth fitting
  /// EQ to or drawing conclusions from.
  List<bool> trustworthy({double minSnrDb = 10}) {
    final snr = snrDb;
    if (snr == null) return List<bool>.filled(response.length, true);
    return [for (final v in snr) v >= minSnrDb];
  }

  /// The contiguous band, starting from the low end, over which the measurement
  /// clears [minSnrDb] — i.e. how far up the sweep actually got. A Bluetooth
  /// link using SBC typically gives out somewhere around 11 kHz, which reads as
  /// a response that "stops" partway up.
  ({double fLo, double fHi})? usableBand({double minSnrDb = 10}) {
    final ok = trustworthy(minSnrDb: minSnrDb);
    if (snrDb == null || response.isEmpty) return null;
    final lo = ok.indexOf(true);
    if (lo < 0) return null;
    // Walk down from the top for the first point that still has signal either
    // side of it. A single failing point is a null in the response, not the end
    // of the usable range; a run of them is where the sweep stopped arriving.
    var hi = lo;
    for (var i = ok.length - 1; i > lo; i--) {
      if (!ok[i]) continue;
      final neighboursOk = (i > 0 && ok[i - 1]) || (i + 1 < ok.length && ok[i + 1]);
      if (neighboursOk) {
        hi = i;
        break;
      }
    }
    return (fLo: response.freqHz[lo], fHi: response.freqHz[hi]);
  }
}

/// The shape the system is being aimed at.
///
/// Flat is not the goal in a car: a small cabin, an off-centre seat and a
/// windscreen close to your ears mean a literally flat response measures right
/// and sounds thin and bright. "Measurement tells you what the system is doing;
/// the target curve expresses what you want it to do."
class TargetShape {
  const TargetShape({
    this.bassShelfDb = 0,
    this.bassShelfHz = 80,
    this.bassShelfWidthOct = 1.5,
    this.tiltDbPerOctave = 0,
    this.tiltPivotHz = 1000,
  });

  final double bassShelfDb;
  final double bassShelfHz;
  final double bassShelfWidthOct;
  final double tiltDbPerOctave;
  final double tiltPivotHz;

  TargetShape copyWith({double? bassShelfDb, double? tiltDbPerOctave}) =>
      TargetShape(
        bassShelfDb: bassShelfDb ?? this.bassShelfDb,
        bassShelfHz: bassShelfHz,
        bassShelfWidthOct: bassShelfWidthOct,
        tiltDbPerOctave: tiltDbPerOctave ?? this.tiltDbPerOctave,
        tiltPivotHz: tiltPivotHz,
      );

  Map<String, dynamic> toJson() => {
        'bassShelfDb': bassShelfDb,
        'bassShelfHz': bassShelfHz,
        'bassShelfWidthOct': bassShelfWidthOct,
        'tiltDbPerOctave': tiltDbPerOctave,
        'tiltPivotHz': tiltPivotHz,
      };

  factory TargetShape.fromJson(Map<String, dynamic> j) => TargetShape(
        bassShelfDb: (j['bassShelfDb'] as num?)?.toDouble() ?? 0,
        bassShelfHz: (j['bassShelfHz'] as num?)?.toDouble() ?? 80,
        bassShelfWidthOct: (j['bassShelfWidthOct'] as num?)?.toDouble() ?? 1.5,
        tiltDbPerOctave: (j['tiltDbPerOctave'] as num?)?.toDouble() ?? 0,
        tiltPivotHz: (j['tiltPivotHz'] as num?)?.toDouble() ?? 1000,
      );
}

/// Target families. Preference, not physics — which is exactly why they are
/// presets the listener picks rather than something the app decides.
enum TargetPreset {
  reference(
    'Reference',
    'Flat through the mids and top. Technically neutral; in most cars it '
        'sounds thin and a little bright.',
    TargetShape(),
  ),
  smooth(
    'Smooth (low fatigue)',
    'A modest bass shelf and a gentle downward tilt. The safe default for long '
        'drives — full, without the top end wearing on you.',
    TargetShape(bassShelfDb: 4, tiltDbPerOctave: -0.35),
  ),
  warm(
    'Warm',
    'More bass and a steeper tilt. Forgiving of road noise and bright '
        'recordings, at the cost of some detail.',
    TargetShape(bassShelfDb: 6, tiltDbPerOctave: -0.5),
  ),
  energetic(
    'Energetic',
    'Bass lift with the top end largely kept. Lively and detailed; less '
        'forgiving of harsh recordings.',
    TargetShape(bassShelfDb: 4, tiltDbPerOctave: -0.15),
  ),
  custom(
    'Custom',
    'Set the bass shelf and tilt yourself.',
    TargetShape(bassShelfDb: 4, tiltDbPerOctave: -0.3),
  );

  const TargetPreset(this.label, this.description, this.shape);
  final String label;
  final String description;
  final TargetShape shape;
}

/// Why the fitter placed a band, or refused to. Mirrors PeqReason in
/// core/include/rewcore/peq.hpp — keep the codes in step.
enum PeqReason {
  broadExcess(1),
  narrowExcess(2),
  broadDeficit(3),
  cutLimited(4),
  declinedNarrowNull(10),
  declinedNoOutput(11),
  declinedUnrepeatable(12),
  declinedNoImprovement(13),
  unknown(0);

  const PeqReason(this.code);
  final int code;

  /// Short phrasing for the expert view.
  String get short => switch (this) {
        PeqReason.broadExcess => 'broad repeatable excess',
        PeqReason.narrowExcess => 'narrow excess',
        PeqReason.broadDeficit => 'broad dip',
        PeqReason.cutLimited => 'excess deeper than one filter should hold',
        PeqReason.declinedNarrowNull => 'likely acoustic cancellation',
        PeqReason.declinedNoOutput => 'driver does not play here',
        PeqReason.declinedUnrepeatable => 'moved between captures',
        PeqReason.declinedNoImprovement => 'correcting it made things worse',
        PeqReason.unknown => 'unclassified',
      };

  /// What it means and what to do about it, in plain language.
  String get explanation => switch (this) {
        PeqReason.broadExcess =>
          'This range is consistently louder than the rest and the excess is '
              'wide enough to respond to EQ. Cutting it is safe.',
        PeqReason.narrowExcess =>
          'A narrow peak. Worth a gentle cut, but narrow features often shift '
              'with your head position, so treat it as optional.',
        PeqReason.broadDeficit =>
          'A wide, shallow dip — the kind a small boost genuinely lifts. Kept '
              'small on purpose: a boost costs headroom everywhere.',
        PeqReason.cutLimited =>
          'The excess is deeper than one filter should hold. Turn this '
              "channel's level down instead and keep the headroom.",
        PeqReason.declinedNarrowNull =>
          'A deep, narrow dip is almost always cancellation — two paths '
              'arriving out of step. Boosting cannot fill it, because the '
              'cancellation removes the boost too. Check crossover, polarity, '
              'driver position or integration instead.',
        PeqReason.declinedNoOutput =>
          'The driver has essentially no output here, so there is nothing to '
              'correct. This is the crossover doing its job.',
        PeqReason.declinedUnrepeatable =>
          'This moved between repeated captures, so it is not a property of '
              'the car — more likely mic position or background noise. '
              'Re-measure before treating it as real.',
        PeqReason.declinedNoImprovement =>
          'A filter here was tried and measurably worsened the response, so it '
              'was dropped. Usually this means the region is outside what the '
              'driver can play, and it wants a crossover or level change '
              'rather than EQ.',
        PeqReason.unknown => '',
      };
}

PeqReason peqReasonFromCode(int code) => PeqReason.values.firstWhere(
      (r) => r.code == code,
      orElse: () => PeqReason.unknown,
    );

/// Something the fitter deliberately left alone. Advice, not a filter.
class DeclinedFeature {
  const DeclinedFeature({required this.reason, required this.freqHz});
  final PeqReason reason;
  final double freqHz;
}

/// One parametric EQ band, as entered into the DSP's own app.
class PeqBand {
  const PeqBand({
    required this.freqHz,
    required this.gainDb,
    required this.q,
    this.reason = PeqReason.unknown,
    this.confidence = 0,
  });

  /// Why this band is recommended, and how sure the app is. A bare
  /// frequency/gain/Q is not enough to decide whether to type it into a DSP.
  final PeqReason reason;
  final double confidence;

  /// How the app frames the recommendation: high confidence is worth doing,
  /// low confidence is worth trying and listening to.
  String get strength => confidence >= 0.6
      ? 'recommended'
      : confidence >= 0.35
          ? 'optional'
          : 'low confidence — listen first';

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
    this.suggestedLevelTrimDb = 0,
    this.declined = const [],
  });

  /// Features the app saw and deliberately did not correct, with the reason.
  /// Surfacing these is the point: silence would look like the app missed them.
  final List<DeclinedFeature> declined;

  final List<PeqBand> bands;
  final double initialErrorDb;
  final double finalErrorDb;

  /// How much the fit wanted to cut beyond what one band should hold. Non-zero
  /// means: turn this channel down by this much on the DSP's level control, and
  /// keep the filters for the peaks that remain.
  final double suggestedLevelTrimDb;
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

  /// A user-defined band, labelled from its own range. Used both for a fresh
  /// custom range and for editing a preset (the edited copy is custom).
  factory SweepBand.custom(double lo, double hi) =>
      SweepBand('Custom · ${_fmtHz(lo)} – ${_fmtHz(hi)}', lo, hi);

  static String _fmtHz(double f) => f >= 1000
      ? '${(f / 1000).toStringAsFixed(f % 1000 == 0 ? 0 : 1)} kHz'
      : '${f.round()} Hz';

  /// Clamped to something a 48 kHz sweep can actually contain.
  static const double minHz = 10;
  static const double maxHz = 21000;
}

/// Suggested crossover edges for one measured driver (from rewcore).
/// Why a crossover edge was placed, or why none was. Mirrors
/// rewcore::CrossoverReason.
enum CrossoverReason {
  measuredRolloff(1),
  stillStrongAtLimit(2),
  notEnoughData(3),
  unknown(0);

  const CrossoverReason(this.code);
  final int code;

  String get short => switch (this) {
        CrossoverReason.measuredRolloff => 'measured roll-off',
        CrossoverReason.stillStrongAtLimit => 'still at full level here',
        CrossoverReason.notEnoughData => 'not enough usable data',
        CrossoverReason.unknown => '',
      };

  String get explanation => switch (this) {
        CrossoverReason.measuredRolloff =>
          'Taken from where this driver actually falls off in your car, not '
              'from what the driver is rated for.',
        CrossoverReason.stillStrongAtLimit =>
          'The driver was still at full level where the sweep ended, so it '
              'plays beyond what was measured. No crossover is suggested on '
              'this side — measure a wider band if you need one.',
        CrossoverReason.notEnoughData =>
          'Too few usable points to say anything. Check the measurement first.',
        CrossoverReason.unknown => '',
      };
}

CrossoverReason crossoverReasonFromCode(int code) =>
    CrossoverReason.values.firstWhere((r) => r.code == code,
        orElse: () => CrossoverReason.unknown);

/// One edge of a driver's usable band, with everything needed to decide what to
/// type into the DSP — and how much to trust it.
class CrossoverEdge {
  const CrossoverEdge({
    required this.present,
    required this.freqHz,
    required this.recommendedHz,
    required this.acousticSlopeDbPerOct,
    required this.electricalSlopeDbPerOct,
    required this.confidence,
    required this.reason,
  });

  const CrossoverEdge.absent(this.reason)
      : present = false,
        freqHz = 0,
        recommendedHz = 0,
        acousticSlopeDbPerOct = 0,
        electricalSlopeDbPerOct = 0,
        confidence = 0;

  final bool present;

  /// Where the response passes the -6 dB point.
  final double freqHz;

  /// The same edge with a safety margin applied, which is what to actually set:
  /// a high-pass goes above the measured edge, a low-pass below it, so the
  /// driver is not asked to work right at its limit.
  final double recommendedHz;

  /// What the driver already does on its own, in the car.
  final double acousticSlopeDbPerOct;

  /// What to set in the DSP so the acoustic result lands near the target.
  /// The difference between the two is exactly why a crossover cannot be
  /// chosen from a datasheet.
  final double electricalSlopeDbPerOct;

  final double confidence;
  final CrossoverReason reason;

  String get strength => confidence >= 0.6
      ? 'confident'
      : confidence >= 0.35
          ? 'reasonable'
          : 'low confidence — verify by ear';
}

class CrossoverRecommendation {
  const CrossoverRecommendation({
    this.highPass = const CrossoverEdge.absent(CrossoverReason.unknown),
    this.lowPass = const CrossoverEdge.absent(CrossoverReason.unknown),
    this.passbandDb = 0,
  });

  final CrossoverEdge highPass;
  final CrossoverEdge lowPass;
  final double passbandDb;

  double? get highPassHz => highPass.present ? highPass.recommendedHz : null;
  double? get lowPassHz => lowPass.present ? lowPass.recommendedHz : null;
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

/// What a driver is for. Decides the sweep band it may safely be given.
enum DriverRole { tweeter, midrange, midbass, fullRange, sub }

/// A speaker channel in the car, isolated (soloed in the DSP app) for measuring.
/// One Channel == one thing the DSP can control on its own.
class Channel {
  const Channel(this.id, this.name, [this.role = DriverRole.fullRange]);
  final String id;
  final String name;
  final DriverRole role;

  /// Fallback list used only to look up a display name for an id that is not in
  /// the current system setup (e.g. an old saved project).
  static const List<Channel> defaults = [
    Channel('fl_tweeter', 'Front L Tweeter', DriverRole.tweeter),
    Channel('fl_mid', 'Front L Midrange', DriverRole.midrange),
    Channel('fr_tweeter', 'Front R Tweeter', DriverRole.tweeter),
    Channel('fr_mid', 'Front R Midrange', DriverRole.midrange),
    Channel('rl', 'Rear L', DriverRole.fullRange),
    Channel('rr', 'Rear R', DriverRole.fullRange),
    Channel('sub', 'Subwoofer', DriverRole.sub),
  ];
}
