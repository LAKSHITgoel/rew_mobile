// A record of what the app recommended and what happened next.
//
// The heuristics in TuningParameters were arrived at by argument, not by
// derivation, and they were tested against synthetic signals rather than real
// cars. This is the evidence that would let them be revised on something
// better: what was recommended, under which parameters, on a measurement of
// what quality — and, when a verification pass follows, whether it actually
// improved anything.
//
// Append-only on purpose. An entry is a thing that happened, and a record you
// can rewrite is not evidence.
import 'measurement.dart';
import 'tuning_parameters.dart';

enum JournalEvent {
  /// EQ was fitted and recommended.
  recommended,

  /// The system was re-measured after the settings were entered. This is the
  /// only entry that says whether any of it worked.
  verified,
}

class JournalEntry {
  const JournalEntry({
    required this.at,
    required this.event,
    required this.tuneId,
    required this.tuneName,
    required this.parameters,
    this.channel = 'system',
    this.targetCurve,
    this.bands = const [],
    this.initialErrorDb,
    this.finalErrorDb,
    this.suggestedLevelTrimDb,
    this.usableFromHz,
    this.usableToHz,
    this.levelDbfs,
    this.captureUsable,
    this.declined = const [],
    this.note,
  });

  final DateTime at;
  final JournalEvent event;
  final String tuneId;
  final String tuneName;
  final String channel;

  /// The parameters in force. Without these an entry cannot be interpreted:
  /// "it recommended a 6 dB cut" means something different under a 6 dB limit
  /// than under a 12 dB one.
  final TuningParameters parameters;

  final String? targetCurve;
  final List<PeqBand> bands;

  /// Flatness before and after the fit, in dB RMS. The pair is the closest
  /// thing to an objective score the app has.
  final double? initialErrorDb;
  final double? finalErrorDb;
  final double? suggestedLevelTrimDb;

  /// How much of the sweep actually cleared the noise. A recommendation made
  /// over a narrow usable band should not be read as confidently as one made
  /// over the whole range.
  final double? usableFromHz;
  final double? usableToHz;

  final double? levelDbfs;
  final bool? captureUsable;

  /// Features the fitter declined to correct, as reason codes with frequencies.
  final List<({int reason, double freqHz})> declined;

  final String? note;

  /// Did the fit improve the response? Null when there is nothing to compare.
  bool? get improved {
    final a = initialErrorDb, b = finalErrorDb;
    if (a == null || b == null) return null;
    return b < a;
  }

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'event': event.name,
        'tuneId': tuneId,
        'tuneName': tuneName,
        'channel': channel,
        'parameters': parameters.toJson(),
        if (targetCurve != null) 'targetCurve': targetCurve,
        'bands': [for (final b in bands) b.toJson()],
        if (initialErrorDb != null) 'initialErrorDb': initialErrorDb,
        if (finalErrorDb != null) 'finalErrorDb': finalErrorDb,
        if (suggestedLevelTrimDb != null)
          'suggestedLevelTrimDb': suggestedLevelTrimDb,
        if (usableFromHz != null) 'usableFromHz': usableFromHz,
        if (usableToHz != null) 'usableToHz': usableToHz,
        if (levelDbfs != null) 'levelDbfs': levelDbfs,
        if (captureUsable != null) 'captureUsable': captureUsable,
        'declined': [
          for (final d in declined) {'reason': d.reason, 'freqHz': d.freqHz}
        ],
        if (note != null) 'note': note,
      };

  factory JournalEntry.fromJson(Map<String, dynamic> j) => JournalEntry(
        at: DateTime.parse(j['at'] as String),
        event: JournalEvent.values.firstWhere(
          (e) => e.name == j['event'],
          orElse: () => JournalEvent.recommended,
        ),
        tuneId: j['tuneId'] as String? ?? '',
        tuneName: j['tuneName'] as String? ?? '',
        channel: j['channel'] as String? ?? 'system',
        parameters: TuningParameters.fromJson(
            ((j['parameters'] as Map?) ?? const {}).cast<String, dynamic>()),
        targetCurve: j['targetCurve'] as String?,
        bands: [
          for (final b in (j['bands'] as List?) ?? const [])
            PeqBand.fromJson((b as Map).cast<String, dynamic>())
        ],
        initialErrorDb: (j['initialErrorDb'] as num?)?.toDouble(),
        finalErrorDb: (j['finalErrorDb'] as num?)?.toDouble(),
        suggestedLevelTrimDb: (j['suggestedLevelTrimDb'] as num?)?.toDouble(),
        usableFromHz: (j['usableFromHz'] as num?)?.toDouble(),
        usableToHz: (j['usableToHz'] as num?)?.toDouble(),
        levelDbfs: (j['levelDbfs'] as num?)?.toDouble(),
        captureUsable: j['captureUsable'] as bool?,
        declined: [
          for (final d in (j['declined'] as List?) ?? const [])
            (
              reason: ((d as Map)['reason'] as num?)?.toInt() ?? 0,
              freqHz: (d['freqHz'] as num?)?.toDouble() ?? 0.0,
            )
        ],
        note: j['note'] as String?,
      );
}

/// A change to the heuristics, suggested from the journal.
///
/// Stored rather than applied: the model proposes, the person decides. It also
/// has to survive [TuningParameters.problems] before it can be offered at all.
class ParameterProposal {
  const ParameterProposal({
    required this.at,
    required this.parameters,
    required this.rationale,
    this.source = 'assistant',
    this.applied = false,
  });

  final DateTime at;
  final TuningParameters parameters;

  /// Why. A proposal with no argument behind it is not reviewable, and the
  /// whole point is that a person can disagree with the reasoning.
  final String rationale;

  final String source;
  final bool applied;

  ParameterProposal markApplied() => ParameterProposal(
        at: at,
        parameters: parameters,
        rationale: rationale,
        source: source,
        applied: true,
      );

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'parameters': parameters.toJson(),
        'rationale': rationale,
        'source': source,
        'applied': applied,
      };

  factory ParameterProposal.fromJson(Map<String, dynamic> j) =>
      ParameterProposal(
        at: DateTime.parse(j['at'] as String),
        parameters: TuningParameters.fromJson(
            ((j['parameters'] as Map?) ?? const {}).cast<String, dynamic>()),
        rationale: j['rationale'] as String? ?? '',
        source: j['source'] as String? ?? 'assistant',
        applied: j['applied'] as bool? ?? false,
      );
}
