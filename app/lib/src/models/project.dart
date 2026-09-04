// A saved car tune: the measurements taken and the settings recommended, so a
// session can be reopened and compared. JSON-serializable for persistence.
import 'car_setup.dart';
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
    Map<String, FreqResponse>? noiseFloors,
    Map<String, List<PeqBand>>? eqBands,
    List<CrossoverSetting>? crossovers,
    Map<String, double>? delaysMs,
    Map<String, double>? levelsDbfs,
    this.splOffsetDb,
    this.setup = const CarSetup(),
  })  : measured = measured ?? {},
        noiseFloors = noiseFloors ?? {},
        eqBands = eqBands ?? {},
        crossovers = crossovers ?? [],
        delaysMs = delaysMs ?? {},
        levelsDbfs = levelsDbfs ?? {};

  final String id;
  String name;
  final DateTime createdAt;

  /// Measured response per channel id (and 'system' for the full-system verify).
  final Map<String, FreqResponse> measured;

  /// The noise floor captured alongside each measurement, on the same grid.
  /// Saved because without it a stored curve cannot be judged later: there is
  /// no way to tell which part of it was the car and which was the car's noise.
  final Map<String, FreqResponse> noiseFloors;

  /// Recommended parametric EQ bands per channel id.
  final Map<String, List<PeqBand>> eqBands;

  final List<CrossoverSetting> crossovers;

  /// Manual time-alignment delays per channel id, in milliseconds.
  final Map<String, double> delaysMs;

  /// Captured level per channel id, in dBFS — used to match drivers to each
  /// other. Becomes dB SPL when [splOffsetDb] is set.
  final Map<String, double> levelsDbfs;

  /// What is installed in the car; drives which channels get measured.
  CarSetup setup;

  /// dB to add to a dBFS reading to get dB SPL, from a one-time calibration
  /// against a reference meter. Null means only relative levels are meaningful.
  double? splOffsetDb;

  /// What this tune is aimed at. Saved with the tune because it is the
  /// listener's preference, not a property of the car — reopening a tune and
  /// silently reverting to a different target would change every
  /// recommendation.
  String targetPresetName = 'smooth';

  /// Whether recommendations are worded for an expert or a beginner.
  bool expertMode = false;
  TargetShape customTarget = TargetPreset.custom.shape;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'measured':
            measured.map((k, v) => MapEntry(k, v.toJson())),
        'noiseFloors': noiseFloors.map((k, v) => MapEntry(k, v.toJson())),
        'eqBands': eqBands.map(
            (k, v) => MapEntry(k, v.map((b) => b.toJson()).toList())),
        'crossovers': crossovers.map((c) => c.toJson()).toList(),
        'delaysMs': delaysMs,
        'levelsDbfs': levelsDbfs,
        'splOffsetDb': splOffsetDb,
        'targetPreset': targetPresetName,
        'expertMode': expertMode,
        'customTarget': customTarget.toJson(),
        'setup': setup.toJson(),
      };

  /// Tolerant by necessity: FileProjectStore skips any file that fails to
  /// parse, so a model change that throws here does not crash the app — it
  /// silently loses the user's saved tunes. A missing key must always fall back
  /// to a correctly typed empty value, never to a bare `{}`, which is a
  /// Map<dynamic, dynamic> and fails the cast.
  factory TuneProject.fromJson(Map<String, dynamic> j) => TuneProject(
        id: j['id'] as String,
        name: j['name'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        measured: ((j['measured'] as Map?) ?? const {}).cast<String, dynamic>().map(
            (k, v) => MapEntry(k, FreqResponse.fromJson(v as Map<String, dynamic>))),
        noiseFloors: (((j['noiseFloors'] as Map?) ?? const {}).cast<String, dynamic>()).map(
            (k, v) =>
                MapEntry(k, FreqResponse.fromJson(v as Map<String, dynamic>))),
        eqBands: ((j['eqBands'] as Map?) ?? const {}).cast<String, dynamic>().map((k, v) => MapEntry(
            k,
            (v as List)
                .map((b) => PeqBand.fromJson(b as Map<String, dynamic>))
                .toList())),
        crossovers: ((j['crossovers'] as List?) ?? const [])
            .map((c) => CrossoverSetting.fromJson(c as Map<String, dynamic>))
            .toList(),
        delaysMs: (((j['delaysMs'] as Map?) ?? const {}).cast<String, dynamic>())
            .map((k, v) => MapEntry(k, (v as num).toDouble())),
        levelsDbfs: (((j['levelsDbfs'] as Map?) ?? const {}).cast<String, dynamic>())
            .map((k, v) => MapEntry(k, (v as num).toDouble())),
        splOffsetDb: (j['splOffsetDb'] as num?)?.toDouble(),
        setup: CarSetup.fromJson(
            (j['setup'] as Map<String, dynamic>?) ?? const {}),
      )
        ..targetPresetName = (j['targetPreset'] as String?) ?? 'smooth'
        ..expertMode = (j['expertMode'] as bool?) ?? false
        ..customTarget = j['customTarget'] == null
            ? TargetPreset.custom.shape
            : TargetShape.fromJson(j['customTarget'] as Map<String, dynamic>);
}
