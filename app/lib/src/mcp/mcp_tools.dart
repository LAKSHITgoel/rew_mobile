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
