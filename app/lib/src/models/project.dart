// A saved car tune: the measurements taken and the settings recommended, so a
// session can be reopened and compared. JSON-serializable for persistence.
import 'measurement.dart';

class CrossoverSetting {
  CrossoverSetting({
    required this.channelId,
    required this.highPassHz,
    required this.lowPassHz,
    required this.slope,
  });

  final String channelId;
  final double? highPassHz; // null = no high-pass (e.g. sub low section)
  final double? lowPassHz;  // null = no low-pass (e.g. tweeter high section)
  final XoverSlope slope;

  Map<String, dynamic> toJson() => {
        'channelId': channelId,
        'highPassHz': highPassHz,
        'lowPassHz': lowPassHz,
        'slope': slope.index,
      };

  factory CrossoverSetting.fromJson(Map<String, dynamic> j) => CrossoverSetting(
        channelId: j['channelId'] as String,
        highPassHz: (j['highPassHz'] as num?)?.toDouble(),
        lowPassHz: (j['lowPassHz'] as num?)?.toDouble(),
        slope: XoverSlope.values[j['slope'] as int],
      );
}

class TuneProject {
  TuneProject({
    required this.id,
    required this.name,
    required this.createdAt,
    Map<String, FreqResponse>? measured,
    Map<String, List<PeqBand>>? eqBands,
    List<CrossoverSetting>? crossovers,
    Map<String, double>? delaysMs,
  })  : measured = measured ?? {},
        eqBands = eqBands ?? {},
        crossovers = crossovers ?? [],
        delaysMs = delaysMs ?? {};

  final String id;
  String name;
  final DateTime createdAt;

  /// Measured response per channel id (and 'system' for the full-system verify).
  final Map<String, FreqResponse> measured;

  /// Recommended parametric EQ bands per channel id.
  final Map<String, List<PeqBand>> eqBands;

  final List<CrossoverSetting> crossovers;

  /// Manual time-alignment delays per channel id, in milliseconds.
  final Map<String, double> delaysMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'measured':
            measured.map((k, v) => MapEntry(k, v.toJson())),
        'eqBands': eqBands.map(
            (k, v) => MapEntry(k, v.map((b) => b.toJson()).toList())),
        'crossovers': crossovers.map((c) => c.toJson()).toList(),
        'delaysMs': delaysMs,
      };

  factory TuneProject.fromJson(Map<String, dynamic> j) => TuneProject(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        measured: (j['measured'] as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, FreqResponse.fromJson(v as Map<String, dynamic>))),
        eqBands: (j['eqBands'] as Map<String, dynamic>).map((k, v) => MapEntry(
            k,
            (v as List)
                .map((b) => PeqBand.fromJson(b as Map<String, dynamic>))
                .toList())),
        crossovers: (j['crossovers'] as List)
            .map((c) => CrossoverSetting.fromJson(c as Map<String, dynamic>))
            .toList(),
        delaysMs: ((j['delaysMs'] ?? {}) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, (v as num).toDouble())),
      );
}
