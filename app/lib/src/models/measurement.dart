import 'dart:typed_data';
import 'dart:math' as math;

// Plain data models shared across the app. Kept JSON-serializable so projects
// (a saved car tune) can be persisted and reopened.

/// A magnitude frequency response sampled on a (log) frequency grid.
class FreqResponse {
  FreqResponse(this.freqHz, this.magDb, [this.phaseDeg = const []])
      : assert(freqHz.length == magDb.length);

  /// Nothing measured — distinct from a measurement that came back flat.
  const FreqResponse.empty()
      : freqHz = const [],
        magDb = const [],
        phaseDeg = const [];

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

/// How successive spectra are combined, mirroring rewcore::RtaAveraging.
enum RtaAveraging {
  none(0, 'None', 'Every block as it arrives. Twitchy, but shows transients.'),
  exponential(1, 'Exponential',
      'A running average that forgets. The usual choice.'),
  forever(2, 'Forever',
      'Averages everything since you cleared it — for a settled picture of a '
          'steady signal.');

  const RtaAveraging(this.code, this.label, this.description);
  final int code;
  final String label;
  final String description;
}

/// Level weighting, mirroring rewcore::SplWeighting.
enum SplWeighting {
  z(0, 'Z (unweighted)', 'The raw level, all frequencies counted equally.'),
  a(1, 'A', 'Follows how little the ear makes of bass. What noise figures '
      'are normally quoted in.'),
  c(2, 'C', 'Nearly flat, rolling off only the extremes. Better for loud '
      'sound and for bass.');

  const SplWeighting(this.code, this.label, this.description);
  final int code;
  final String label;
  final String description;
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
    this.distortion,
    FreqResponse? analysis,
  }) : _analysis = analysis;

  /// Harmonic distortion from the sweep, when it was analysed. For an averaged
  /// measurement this is the first capture rather than a combination of them:
  /// harmonic level relative to the fundamental hardly moves with the
  /// microphone, so there is little to gain by averaging it. Null for anything
  /// measured before this existed.
  final DistortionAnalysis? distortion;

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

  /// The target as a curve on the same grid as a measurement, so it can be
  /// drawn against it. Mirrors makeTarget() in core/src/peq.cpp — the shape has
  /// to be the same one the fitter aims at, or the chart would be showing a
  /// different promise than the app is keeping.
  FreqResponse curveLike(FreqResponse like, {double alignAtDb = 0}) {
    final mag = <double>[];
    for (final f in like.freqHz) {
      var db = 0.0;
      if (bassShelfDb != 0 && f > 0) {
        final width = bassShelfWidthOct <= 0 ? 0.1 : bassShelfWidthOct;
        final x = (math.log(f / bassShelfHz) / math.ln2) / (width * 0.5);
        // tanh, matching the core: a hard corner would hand the fitter an edge
        // of its own making to chase.
        final t = (math.exp(2 * x) - 1) / (math.exp(2 * x) + 1);
        db += bassShelfDb * 0.5 * (1 - t);
      }
      if (tiltDbPerOctave != 0 && f > tiltPivotHz) {
        db += tiltDbPerOctave * (math.log(f / tiltPivotHz) / math.ln2);
      }
      mag.add(db + alignAtDb);
    }
    return FreqResponse(List<double>.from(like.freqHz), mag);
  }

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

  /// The recommendation in plain language, for someone who does not read
  /// frequency response plots. Same finding as [expertLine], said differently —
  /// the app should never have a finding it can only express one way.
  String beginnerLine() {
    final where = freqHz < 250
        ? 'the bass'
        : freqHz < 800
            ? 'the lower midrange'
            : freqHz < 2500
                ? 'the midrange, where voices sit'
                : freqHz < 7000
                    ? 'the presence range, where sibilance and detail sit'
                    : 'the top end';
    final action = gainDb < 0
        ? 'has too much energy'
        : 'is a little weak';
    final size = gainDb.abs() >= 4
        ? 'clearly'
        : gainDb.abs() >= 2
            ? 'noticeably'
            : 'slightly';
    final fix = gainDb < 0
        ? 'Cut it by ${(-gainDb).toStringAsFixed(1)} dB.'
        : 'Lift it by ${gainDb.toStringAsFixed(1)} dB.';
    return '${_hz(freqHz)} — $where $size $action. $fix';
  }

  /// The same finding for someone who wants the numbers.
  String expertLine() =>
      '${_hz(freqHz)}  ${gainDb >= 0 ? '+' : ''}${gainDb.toStringAsFixed(1)} dB  '
      'Q ${q.toStringAsFixed(2)}  ·  ${reason.short}  ·  $strength'
      '${confidence > 0 ? ' (${(confidence * 100).round()}%)' : ''}';

  static String _hz(double f) => f >= 1000
      ? '${(f / 1000).toStringAsFixed(f >= 10000 ? 0 : 1)} kHz'
      : '${f.round()} Hz';

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

  // The reason and confidence are saved with the band. Without them a reopened
  // tune could still be typed into a DSP but no longer explained — and anything
  // reviewing it later, human or model, would be told "unclassified" for
  // recommendations the app had perfectly good grounds for.
  Map<String, dynamic> toJson() => {
        'freqHz': freqHz,
        'gainDb': gainDb,
        'q': q,
        'reason': reason.code,
        'confidence': confidence,
      };

  factory PeqBand.fromJson(Map<String, dynamic> j) => PeqBand(
        freqHz: (j['freqHz'] as num).toDouble(),
        gainDb: (j['gainDb'] as num).toDouble(),
        q: (j['q'] as num).toDouble(),
        reason: peqReasonFromCode((j['reason'] as num?)?.toInt() ?? 0),
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
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
/// What to do about polarity at a crossover. Mirrors rewcore::PolarityAdvice.
enum PolarityAdvice {
  keep(1),
  invert(2),
  inconclusive(3),
  suspectDestructive(4),
  unknown(0);

  const PolarityAdvice(this.code);
  final int code;

  String get headline => switch (this) {
        PolarityAdvice.keep => 'Polarity looks right',
        PolarityAdvice.invert => 'Invert one of these drivers',
        PolarityAdvice.inconclusive => 'Too close to call',
        PolarityAdvice.suspectDestructive => 'These two are fighting each other',
        PolarityAdvice.unknown => '',
      };
}

PolarityAdvice polarityAdviceFromCode(int code) =>
    PolarityAdvice.values.firstWhere((a) => a.code == code,
        orElse: () => PolarityAdvice.unknown);

/// Whether two drivers work together through their crossover.
class SummationResult {
  const SummationResult({
    required this.valid,
    required this.haveInverted,
    required this.advice,
    required this.overlapLoHz,
    required this.overlapHiHz,
    required this.measuredDb,
    required this.invertedDb,
    required this.coherentDb,
    required this.powerDb,
    required this.deficitDb,
    required this.invertedGainDb,
    required this.confidence,
  });

  const SummationResult.notEnoughOverlap()
      : valid = false,
        haveInverted = false,
        advice = PolarityAdvice.inconclusive,
        overlapLoHz = 0,
        overlapHiHz = 0,
        measuredDb = 0,
        invertedDb = 0,
        coherentDb = 0,
        powerDb = 0,
        deficitDb = 0,
        invertedGainDb = 0,
        confidence = 0;

  final bool valid;
  final bool haveInverted;
  final PolarityAdvice advice;
  final double overlapLoHz, overlapHiHz;
  final double measuredDb, invertedDb, coherentDb, powerDb;
  final double deficitDb, invertedGainDb, confidence;

  /// What it means and what to do, in plain language.
  String get explanation {
    if (!valid) {
      return 'These two drivers barely overlap, so there is nothing to say '
          'about how they combine. Polarity only matters where both are '
          'playing — check a pair that shares a crossover.';
    }
    final band = '${overlapLoHz.round()}–${overlapHiHz.round()} Hz';
    switch (advice) {
      case PolarityAdvice.keep:
        return haveInverted
            ? 'Through $band the pair is ${(-invertedGainDb).toStringAsFixed(1)} dB '
                'louder as wired than with one inverted, so leave it alone.'
            : 'Through $band the pair sums to within '
                '${deficitDb.toStringAsFixed(1)} dB of a perfect sum, which is '
                'normal. Nothing suggests a polarity problem.';
      case PolarityAdvice.invert:
        return 'Through $band the pair is ${invertedGainDb.toStringAsFixed(1)} dB '
            'louder with one driver inverted. Flip the polarity of one of them '
            'in the DSP — it does not matter which — and re-measure.';
      case PolarityAdvice.suspectDestructive:
        return 'Through $band the pair is ${deficitDb.toStringAsFixed(1)} dB '
            'below what two drivers summing properly would give, so they are '
            'partly cancelling. Measure again with one inverted to find out '
            'whether polarity is the cause.';
      case PolarityAdvice.inconclusive:
        return 'Through $band the two polarities are within '
            '${invertedGainDb.abs().toStringAsFixed(1)} dB of each other, which '
            'is too close to call. Either is defensible; trust your ears, or '
            'try a different crossover point.';
      case PolarityAdvice.unknown:
        return '';
    }
  }

  String get strength => confidence >= 0.6
      ? 'confident'
      : confidence >= 0.35
          ? 'reasonable'
          : 'low confidence';
}

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

/// Harmonic distortion, as it comes back from one sweep.
///
/// Distortion is what a magnitude response cannot show. A door speaker can
/// measure flat at 80 Hz and still be audibly breaking up there, because the
/// energy it is adding comes out at 160 and 240 Hz, not at 80 — where the
/// response curve is looking. Read next to the fundamental it tells you the
/// difference between a dip worth equalising and a driver already at its limit,
/// which is the one case where more EQ makes things worse rather than better.
class DistortionAnalysis {
  const DistortionAnalysis({
    required this.fundamental,
    required this.harmonics,
    required this.thdPercent,
    required this.worstThdPercent,
    required this.worstThdHz,
  });

  const DistortionAnalysis.empty()
      : fundamental = const FreqResponse.empty(),
        harmonics = const [],
        thdPercent = const FreqResponse.empty(),
        worstThdPercent = 0,
        worstThdHz = 0;

  /// The linear response, for reference on the same axes.
  final FreqResponse fundamental;

  /// `harmonics[0]` is the 2nd, `[1]` the 3rd, and so on. Each is plotted
  /// against the fundamental frequency that produced it, not the frequency the
  /// energy came out at — that is what makes them readable next to the response.
  final List<FreqResponse> harmonics;

  /// Total harmonic distortion as a percentage of the fundamental.
  final FreqResponse thdPercent;

  final double worstThdPercent;
  final double worstThdHz;

  bool get isEmpty => fundamental.isEmpty;

  /// THD at a given frequency, or 0 where there is no measurement.
  double thdAt(double hz) {
    if (thdPercent.isEmpty) return 0;
    var best = 0;
    var bestDelta = double.infinity;
    for (var i = 0; i < thdPercent.length; ++i) {
      final d = (thdPercent.freqHz[i] - hz).abs();
      if (d < bestDelta) {
        bestDelta = d;
        best = i;
      }
    }
    return thdPercent.magDb[best];
  }
}

/// The measurement in the time domain: what arrived, when.
///
/// A frequency response cannot distinguish a level problem from a timing one,
/// and in a car most of what makes bass sound slow is timing. This is where a
/// resonance that keeps ringing after the note has stopped becomes visible —
/// and that is a thing EQ can reduce the level of but never actually fix.
class ImpulseView {
  const ImpulseView({
    required this.samples,
    required this.timeMs,
    required this.step,
    required this.energyDb,
    required this.peakIndex,
    required this.inverted,
  });

  const ImpulseView.empty()
      : samples = const [],
        timeMs = const [],
        step = const [],
        energyDb = const [],
        peakIndex = 0,
        inverted = false;

  /// Normalised so the arrival is 1.0, which makes two measurements comparable
  /// without knowing what level either was taken at.
  final List<double> samples;

  /// Milliseconds relative to the arrival — negative before it, zero at it.
  final List<double> timeMs;

  /// Running sum of the impulse response. A correctly polarised system steps
  /// up first; an inverted one steps down.
  final List<double> step;

  /// Energy-time curve, dB below the peak.
  final List<double> energyDb;

  final int peakIndex;

  /// The arrival is negative-going: the system as measured is inverted.
  final bool inverted;

  bool get isEmpty => samples.isEmpty;
}

/// Successive spectra taken at increasing delays after the arrival — the
/// "waterfall". Where one frequency is still present after everything around
/// it has fallen away, that is a resonance.
class WaterfallView {
  const WaterfallView({
    required this.freqHz,
    required this.timeMs,
    required this.slices,
  });

  const WaterfallView.empty()
      : freqHz = const [],
        timeMs = const [],
        slices = const [];

  final List<double> freqHz;

  /// How long after the arrival each slice starts.
  final List<double> timeMs;

  /// `slices[t][f]`, in dB relative to the loudest point of the first slice.
  final List<List<double>> slices;

  bool get isEmpty => slices.isEmpty;

  /// The frequency that is still loudest once [afterMs] has passed, and how far
  /// down it is. This is the number worth quoting: "at 60 ms, 78 Hz is still
  /// only 9 dB down" says more than a picture does.
  ({double freqHz, double levelDb, double timeMs})? ringing({double afterMs = 50}) {
    if (isEmpty) return null;
    var slice = slices.length - 1;
    for (var i = 0; i < timeMs.length; i++) {
      if (timeMs[i] >= afterMs) {
        slice = i;
        break;
      }
    }
    var best = 0;
    for (var i = 1; i < slices[slice].length; i++) {
      if (slices[slice][i] > slices[slice][best]) best = i;
    }
    return (
      freqHz: freqHz[best],
      levelDb: slices[slice][best],
      timeMs: timeMs[slice],
    );
  }
}

/// Which span of the decay a band's number was actually fitted over.
///
/// This is not pedantry. A true RT60 needs 60 dB of clean decay, which a car
/// never gives you — the road and HVAC noise arrive long before that. What is
/// measured is the slope over the first 20 or 30 dB, extrapolated. Saying which
/// keeps the number honest.
enum DecayBasis {
  none('not measurable', 'The decay never rose far enough above the noise to '
      'measure a slope at all.'),
  t10('T10', 'Fitted over only 10 dB of decay — indicative, not a measurement.'),
  t20('T20', 'Fitted over 20 dB of decay and extrapolated to 60.'),
  t30('T30', 'Fitted over 30 dB of decay and extrapolated to 60.');

  const DecayBasis(this.label, this.explanation);
  final String label;
  final String explanation;

  static DecayBasis fromCode(int code) => switch (code) {
        1 => DecayBasis.t10,
        2 => DecayBasis.t20,
        3 => DecayBasis.t30,
        _ => DecayBasis.none,
      };
}

class BandDecay {
  const BandDecay({
    required this.centerHz,
    required this.rt60Sec,
    required this.edtSec,
    required this.basis,
    required this.straightness,
    required this.usableRangeDb,
  });

  final double centerHz;
  final double rt60Sec;

  /// Early decay time — the slope over the first 10 dB. In a small space this
  /// is closer to what is heard than the late decay is, and a large gap between
  /// the two is itself the finding: something is ringing on.
  final double edtSec;

  final DecayBasis basis;

  /// How straight the decay was over the fitted span, 0..1. Below about 0.9 a
  /// line has been drawn through something that is not a straight decay.
  final double straightness;

  final double usableRangeDb;

  bool get trustworthy =>
      basis == DecayBasis.t20 || basis == DecayBasis.t30
          ? straightness >= 0.9
          : false;
}

class DecayReport {
  const DecayReport({required this.bands, required this.averageRt60Sec});
  const DecayReport.empty()
      : bands = const [],
        averageRt60Sec = 0;

  final List<BandDecay> bands;
  final double averageRt60Sec;

  bool get isEmpty => bands.isEmpty;

  /// The band that rings longest among those actually measured well enough to
  /// say so. In a car this is nearly always in the bass, and it is the one
  /// worth acting on.
  BandDecay? get worst {
    BandDecay? out;
    for (final b in bands) {
      if (!b.trustworthy) continue;
      if (out == null || b.rt60Sec > out.rt60Sec) out = b;
    }
    return out;
  }
}


/// What was played and what came back, for the analyses that start from the
/// deconvolution rather than from a frequency response.
///
/// Held in memory for the most recent measurement only. It is large — a 5.5 s
/// sweep at 48 kHz is a couple of megabytes per channel — and it is not part of
/// a saved tune, so opening a time-domain view on an old measurement means
/// measuring again.
class RawCapture {
  const RawCapture({
    required this.emitted,
    required this.recorded,
    required this.fs,
    required this.band,
  });

  final Float64List emitted;
  final Float64List recorded;
  final double fs;
  final SweepBand band;
}

/// Whether the volume is right to measure at.
///
/// The step that was missing, and the one that decides whether everything
/// downstream is worth anything. Too quiet and the sweep never clears the car's
/// own noise, so the top of the response is a picture of road and HVAC noise —
/// which the EQ fitter will then cheerfully correct. Too loud and the input
/// clips or the drivers distort. Both produce a curve that looks entirely
/// plausible, which is exactly the problem.
enum LevelVerdict {
  noSignal,
  clipping,
  tooLoud,
  tooQuiet,
  marginal,
  good;

  static LevelVerdict fromCode(int code) => switch (code) {
        1 => LevelVerdict.clipping,
        2 => LevelVerdict.tooLoud,
        3 => LevelVerdict.tooQuiet,
        4 => LevelVerdict.marginal,
        5 => LevelVerdict.good,
        _ => LevelVerdict.noSignal,
      };

  String get headline => switch (this) {
        LevelVerdict.noSignal => 'Nothing came back',
        LevelVerdict.clipping => 'The input is clipping',
        LevelVerdict.tooLoud => 'No headroom left',
        LevelVerdict.tooQuiet => 'Too quiet to measure',
        LevelVerdict.marginal => 'Usable, but only just',
        LevelVerdict.good => 'Level is good',
      };

  /// What to do about it, in the terms of the thing actually being turned.
  String get advice => switch (this) {
        LevelVerdict.noSignal =>
          'The microphone heard essentially nothing. Check that the phone is '
              'still the selected source in the car, that the right channel is '
              'unmuted in the DSP app, and that the mic is plugged in.',
        LevelVerdict.clipping =>
          'The capture hit full scale, which means the recording was overloaded '
              'and the response above it is invented. Turn the car down and '
              'check again — a clipped measurement cannot be salvaged in '
              'software.',
        LevelVerdict.tooLoud =>
          'Nothing clipped, but there is no room left for a louder passage or a '
              'resonant peak. Come down a few steps so the next capture has '
              'somewhere to go.',
        LevelVerdict.tooQuiet =>
          'The sweep is barely above the car\'s own noise, so most of what would '
              'be measured is road, HVAC and hiss rather than speakers. Turn the '
              'car up and check again.',
        LevelVerdict.marginal =>
          'Enough to measure the bass and midrange, but the top of the band runs '
              'into the noise. Turning up helps if there is room; if the reach '
              'does not improve, the limit is the wireless codec rather than '
              'the volume, and nothing on the car\'s volume knob will move it.',
        LevelVerdict.good =>
          'Plenty of signal above the noise and headroom to spare. Leave the '
              'volume exactly where it is — changing it between measurements '
              'makes them incomparable, and on some head units it changes the '
              'processing too.',
      };
}

class LevelCheck {
  const LevelCheck({
    required this.verdict,
    required this.peakDbfs,
    required this.rmsDbfs,
    required this.medianSnrDb,
    required this.usableToHz,
    required this.suggestedChangeDb,
  });

  const LevelCheck.noSignal()
      : verdict = LevelVerdict.noSignal,
        peakDbfs = -240,
        rmsDbfs = -240,
        medianSnrDb = 0,
        usableToHz = 0,
        suggestedChangeDb = 12;

  final LevelVerdict verdict;
  final double peakDbfs;
  final double rmsDbfs;

  /// Median signal-to-noise across the band.
  final double medianSnrDb;

  /// Highest frequency the sweep still clears the noise at. In a car this is
  /// the number that matters: a Bluetooth link running SBC and a sweep played
  /// too quietly both look like a response that simply stops partway up.
  final double usableToHz;

  /// How much louder or quieter to play it. A direction and a rough size — the
  /// car's volume control is not calibrated in dB, so it cannot be more than
  /// that.
  final double suggestedChangeDb;

  bool get readyToMeasure =>
      verdict == LevelVerdict.good || verdict == LevelVerdict.marginal;
}
