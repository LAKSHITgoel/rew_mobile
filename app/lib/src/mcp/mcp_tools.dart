// The tools an LLM can call against this app, and what they return.
//
// Deliberately read-mostly. The tuning heuristics live in core/ where they are
// deterministic and covered by tests; this surface exists so a model can look
// at a real measurement and give a second opinion — disagree with a band, spot
// something the rules missed, explain a result — not so it can drive the tune.
// The app must never need a model to be reachable in order to produce one.
//
// Kept free of sockets so the whole surface can be tested without a network.
import 'dart:async';

import '../models/measurement.dart';
import '../models/project.dart';
import '../models/tuning_journal.dart';
import '../models/tuning_parameters.dart';

/// What the tools are allowed to reach. The app supplies this; tests supply a
/// fake, which is the point of the indirection.
abstract class McpContext {
  Future<List<TuneProject>> listTunes();
  Future<TuneProject?> getTune(String id);

  /// Runs a real measurement on the current tune. This plays audio through the
  /// car, so it is the one tool here with a physical effect.
  Future<Measurement> measure({String? tuneId, int positions});

  /// The live analyser's current spectrum, if it is running.
  FreqResponse? rtaSpectrum();
  double? rtaLevelDbfs();

  /// What the app recommended in past sessions, and whether it worked.
  Future<List<JournalEntry>> journal({int limit});

  /// The heuristics currently in force.
  Future<TuningParameters> parameters();

  /// Record a suggested change. Stored for the user to review and apply — it
  /// does not take effect here.
  Future<void> proposeParameters(ParameterProposal proposal);
}

class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Future<Object?> Function(Map<String, dynamic> args) handler;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

/// Curves are hundreds of points and a model does not need every one of them to
/// form an opinion. Thinning on a log grid keeps the shape while keeping the
/// reply small enough to reason over.
List<Map<String, dynamic>> _thin(FreqResponse fr, {int maxPoints = 96}) {
  if (fr.isEmpty) return const [];
  final step = (fr.length / maxPoints).ceil().clamp(1, fr.length);
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < fr.length; i += step) {
    out.add({
      'hz': double.parse(fr.freqHz[i].toStringAsFixed(1)),
      'db': double.parse(fr.magDb[i].toStringAsFixed(2)),
    });
  }
  return out;
}

Map<String, dynamic> _bandJson(PeqBand b) => {
      'hz': double.parse(b.freqHz.toStringAsFixed(1)),
      'gainDb': double.parse(b.gainDb.toStringAsFixed(2)),
      'q': double.parse(b.q.toStringAsFixed(2)),
      'reason': b.reason.short,
      'why': b.reason.explanation,
      'confidence': double.parse(b.confidence.toStringAsFixed(3)),
      'strength': b.strength,
    };

List<McpTool> buildTools(McpContext ctx) => [
      McpTool(
        name: 'list_tunes',
        description:
            'List the saved car tunes: id, name, when it was made, how many '
            'channels were measured and how many EQ bands it holds.',
        inputSchema: const {'type': 'object', 'properties': {}},
        handler: (_) async {
          final tunes = await ctx.listTunes();
          return {
            'tunes': [
              for (final t in tunes)
                {
                  'id': t.id,
                  'name': t.name,
                  'createdAt': t.createdAt.toIso8601String(),
                  'measured': t.measured.keys.toList(),
                  'eqBands': t.eqBands.map((k, v) => MapEntry(k, v.length)),
                  'targetCurve': t.targetPresetName,
                }
            ]
          };
        },
      ),
      McpTool(
        name: 'get_measurement',
        description:
            'The measured frequency response for one channel of a tune, with '
            'the noise floor captured alongside it. Everything the sweep did '
            'not lift clear of that floor is noise, not a measurement of the '
            'car, and should not be reasoned about as if it were.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'tuneId': {'type': 'string'},
            'channel': {
              'type': 'string',
              'description': "Channel key, e.g. 'system'. Defaults to 'system'.",
            },
          },
          'required': ['tuneId'],
        },
        handler: (args) async {
          final tune = await ctx.getTune(args['tuneId'] as String? ?? '');
          if (tune == null) return {'error': 'no such tune'};
          final channel = args['channel'] as String? ?? 'system';
          final fr = tune.measured[channel];
          if (fr == null) {
            return {
              'error': 'channel not measured',
              'available': tune.measured.keys.toList(),
            };
          }
          // The noise floor is the difference between a curve and a
          // measurement, so it is returned alongside rather than on request.
          final noise = tune.noiseFloors[channel];
          final m = Measurement(
            response: fr,
            levelDbfs: tune.levelsDbfs[channel] ?? 0,
            noiseFloor: noise,
          );
          final usable = m.usableBand();
          return {
            'tune': tune.name,
            'channel': channel,
            'levelDbfs': tune.levelsDbfs[channel],
            'points': _thin(fr),
            'noiseFloor': noise == null ? null : _thin(noise),
            'usableTo': usable == null
                ? null
                : {
                    'fromHz': double.parse(usable.fLo.toStringAsFixed(1)),
                    'toHz': double.parse(usable.fHi.toStringAsFixed(1)),
                  },
            'note':
                'Levels are dBFS unless an SPL calibration was done. The curve '
                'is the system as heard through the real OEM path, including '
                'any head-unit processing. Where the response is not clearly '
                'above the noise floor you are looking at noise, not at the '
                'car — do not reason about that part as if it were a '
                'measurement.'
                '${noise == null ? ' No noise floor was captured for this one, '
                    'so its trustworthy range is unknown.' : ''}',
          };
        },
      ),
      McpTool(
        name: 'get_recommendations',
        description:
            "The app's own EQ recommendations for a channel, each with the "
            'reason it was placed and a confidence score, plus the features it '
            'deliberately declined to correct and why. Review these: say '
            'whether you agree, and flag anything you would do differently.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'tuneId': {'type': 'string'},
            'channel': {'type': 'string'},
          },
          'required': ['tuneId'],
        },
        handler: (args) async {
          final tune = await ctx.getTune(args['tuneId'] as String? ?? '');
          if (tune == null) return {'error': 'no such tune'};
          final channel = args['channel'] as String? ?? 'system';
          final bands = tune.eqBands[channel] ?? const <PeqBand>[];
          return {
            'tune': tune.name,
            'channel': channel,
            'targetCurve': tune.targetPresetName,
            'bands': [for (final b in bands) _bandJson(b)],
            'crossovers': [
              for (final x in tune.crossovers)
                {
                  'channel': x.channelId,
                  'highPassHz': x.highPassHz,
                  'lowPassHz': x.lowPassHz,
                }
            ],
            'principles':
                'Cuts are preferred to boosts; boosts are capped at 3 dB '
                'because a boost costs headroom everywhere and a car dip is '
                'usually cancellation that swallows it. Deep narrow dips are '
                'left alone as acoustic cancellation. Cuts deeper than the '
                'limit come back as a channel level trim instead.',
          };
        },
      ),
      McpTool(
        name: 'measure',
        description:
            'Run a real measurement now: plays a sweep through the car and '
            'captures it with the USB microphone. This makes sound. Returns '
            'the response, the noise floor, the usable bandwidth and how '
            'repeatable it was.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'tuneId': {'type': 'string'},
            'positions': {
              'type': 'integer',
              'description':
                  'How many mic positions to average. More is steadier; 3 is '
                  'the usual choice.',
            },
          },
        },
        handler: (args) async {
          final positions = (args['positions'] as num?)?.toInt() ?? 3;
          final m = await ctx.measure(
            tuneId: args['tuneId'] as String?,
            positions: positions.clamp(1, 10),
          );
          final usable = m.usableBand();
          return {
            'levelDbfs': double.parse(m.levelDbfs.toStringAsFixed(2)),
            'points': _thin(m.response),
            'noiseFloor': _thin(m.noiseFloor ?? FreqResponse(const [], const [])),
            'usableTo': usable == null
                ? null
                : {
                    'fromHz': double.parse(usable.fLo.toStringAsFixed(1)),
                    'toHz': double.parse(usable.fHi.toStringAsFixed(1)),
                  },
            'capture': m.quality == null
                ? null
                : {
                    'usable': m.quality!.usable,
                    'problem': m.quality!.problem,
                  },
            'note':
                'Only the range where the response clears the noise floor is a '
                'measurement of the car. Above that you are looking at noise, '
                'and on a Bluetooth link the SBC codec commonly gives out '
                'somewhere around 11 kHz.',
          };
        },
      ),
      McpTool(
        name: 'get_tuning_parameters',
        description:
            'The heuristics the app currently tunes by — cut and boost limits, '
            'the signal-to-noise gate, how repeatable a feature must be, and '
            'so on — with the bounds each one must stay inside. These are '
            'judgement calls, not measurement maths, which is why they are '
            'open to revision.',
        inputSchema: const {'type': 'object', 'properties': {}},
        handler: (_) async {
          final p = await ctx.parameters();
          return {
            'current': p.toJson(),
            'bounds': {
              'maxCutDb': '0 to 12',
              'maxBoostDb': '0 to 6',
              'targetPercentile': 'above 0, below 1',
              'minSnrDb': '3 to 30',
              'maxSpreadDb': 'above 0, up to 12',
              'maxBands': '1 to 31',
              'analysisSmoothFrac': '3 to 96',
              'averagingPositions': '1 to 10',
            },
            'note':
                'A proposal outside these bounds is refused however good the '
                'reasoning: they are the edges of what the app will do, not '
                'opinions open to revision.',
          };
        },
      ),
      McpTool(
        name: 'get_tuning_journal',
        description:
            'What the app recommended in past sessions and how it turned out: '
            'the parameters in force at the time, the bands, the flatness '
            'before and after, how much of the sweep cleared the noise, and '
            'what the fitter declined to correct. Use it to judge whether the '
            'heuristics are serving this car well.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'limit': {'type': 'integer', 'description': 'Most recent N entries.'},
          },
        },
        handler: (args) async {
          final limit = ((args['limit'] as num?)?.toInt() ?? 50).clamp(1, 500);
          final entries = await ctx.journal(limit: limit);
          return {
            'entries': [
              for (final e in entries)
                {
                  'at': e.at.toIso8601String(),
                  'event': e.event.name,
                  'tune': e.tuneName,
                  'target': e.targetCurve,
                  'bands': e.bands.length,
                  'deepestCutDb': e.bands.isEmpty
                      ? null
                      : e.bands
                          .map((b) => b.gainDb)
                          .reduce((a, b) => a < b ? a : b),
                  'flatnessBefore': e.initialErrorDb,
                  'flatnessAfter': e.finalErrorDb,
                  'improved': e.improved,
                  'levelTrimDb': e.suggestedLevelTrimDb,
                  'usableToHz': e.usableToHz,
                  'captureUsable': e.captureUsable,
                  'declined': e.declined.length,
                  'parameters': e.parameters.toJson(),
                  if (e.applied.isNotEmpty) ...{
                    'changedFromAdvice': e.changedCount,
                    'skipped': e.skippedCount,
                    // The per-band difference, which is the part worth
                    // reasoning about: a band softened the same way every
                    // session is a heuristic that is wrong in one direction.
                    'deviations': [
                      for (final a in e.applied)
                        if (a.skipped)
                          {
                            'hz': double.parse(
                                a.recommended.freqHz.toStringAsFixed(1)),
                            'advisedGainDb': a.recommended.gainDb,
                            'outcome': 'skipped',
                          }
                        else if (!a.unchanged)
                          {
                            'hz': double.parse(
                                a.recommended.freqHz.toStringAsFixed(1)),
                            'advisedGainDb': a.recommended.gainDb,
                            'enteredGainDb': a.entered!.gainDb,
                            'enteredQ': a.entered!.q,
                            'gainDeltaDb': double.parse(
                                a.gainDeltaDb!.toStringAsFixed(2)),
                            'outcome': 'changed',
                          },
                    ],
                  },
                  if (e.note != null) 'note': e.note,
                }
            ],
            'howToRead':
                'A "recommended" entry is what the app proposed. An "applied" '
                'entry is what the owner actually typed into the DSP, with the '
                'per-band differences — the strongest signal here, because a '
                'band changed the same way session after session means the '
                'heuristics are wrong in a consistent direction, while a '
                'single deviation means nothing. A "verified" entry is a fresh '
                'measurement taken afterwards, so its flatness is what the '
                'tune actually achieved. Entries made over a narrow usable '
                'range deserve less weight: the sweep did not clear the noise '
                'across the band.',
          };
        },
      ),
      McpTool(
        name: 'propose_tuning_parameters',
        description:
            'Suggest a change to the heuristics, with your reasoning. This '
            'does NOT take effect: it is saved for the owner to review and '
            'apply in the app. Send the full set — start from '
            'get_tuning_parameters and change only what the journal actually '
            'supports changing.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'parameters': {
              'type': 'object',
              'description': 'The complete parameter set you propose.',
            },
            'rationale': {
              'type': 'string',
              'description':
                  'What in the journal supports this, and what you expect it '
                  'to improve. A proposal without an argument cannot be '
                  'reviewed.',
            },
          },
          'required': ['parameters', 'rationale'],
        },
        handler: (args) async {
          final raw = (args['parameters'] as Map?)?.cast<String, dynamic>();
          final rationale = (args['rationale'] as String? ?? '').trim();
          if (raw == null) return {'accepted': false, 'error': 'no parameters'};
          if (rationale.length < 20) {
            return {
              'accepted': false,
              'error':
                  'Give the reasoning: a proposal with no argument behind it '
                  'cannot be reviewed, and would be adopted on trust.',
            };
          }
          final proposed = TuningParameters.fromJson(raw);
          final problems = proposed.problems();
          if (problems.isNotEmpty) {
            return {'accepted': false, 'problems': problems};
          }
          final current = await ctx.parameters();
          final diff = current.diff(proposed);
          if (diff.isEmpty) {
            return {'accepted': false, 'error': 'identical to the current set'};
          }
          await ctx.proposeParameters(ParameterProposal(
            at: DateTime.now(),
            parameters: proposed,
            rationale: rationale,
          ));
          return {
            'accepted': true,
            'changes': {
              for (final e in diff.entries)
                e.key: {'from': e.value.from, 'to': e.value.to}
            },
            'note':
                'Saved as a proposal. It changes nothing until the owner '
                'reviews and applies it in the app.',
          };
        },
      ),
      McpTool(
        name: 'get_rta',
        description:
            'The live analyser\'s current spectrum, if it is running. Use it '
            'for what a sweep cannot answer: what is rattling, or how much '
            'engine and road noise is present right now.',
        inputSchema: const {'type': 'object', 'properties': {}},
        handler: (_) async {
          final fr = ctx.rtaSpectrum();
          if (fr == null || fr.isEmpty) {
            return {'running': false, 'hint': 'Open the analyser in the app.'};
          }
          return {
            'running': true,
            'levelDbfs': ctx.rtaLevelDbfs(),
            'points': _thin(fr),
          };
        },
      ),
    ];
