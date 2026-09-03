// The guided tuning state machine: setup -> crossovers -> EQ -> verify -> done.
// A ChangeNotifier so screens rebuild as measurements complete. It builds up a
// TuneProject and persists it via the ProjectStore.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/audio_backend.dart';
import '../models/measurement.dart';
import '../models/mic_calibration.dart';
import '../models/car_setup.dart';
import '../models/project.dart';
import '../services/measurement_service.dart';
import '../services/time_align.dart';
import '../services/project_store.dart';

enum WizardStep { system, setup, crossovers, timeAlignment, eq, verify, done }

extension WizardStepInfo on WizardStep {
  String get title => switch (this) {
        WizardStep.system => 'System',
        WizardStep.setup => 'Setup & level check',
        WizardStep.crossovers => 'Crossovers',
        WizardStep.timeAlignment => 'Time alignment',
        WizardStep.eq => 'Equalization',
        WizardStep.verify => 'Verify',
        WizardStep.done => 'Done',
      };
}

class WizardController extends ChangeNotifier {
  WizardController({
    required this.service,
    required this.store,
    required this.project,
  });

  final MeasurementService service;
  final ProjectStore store;
  final TuneProject project;

  WizardStep step = WizardStep.system;
  bool busy = false;

  /// Set when a run fails, so the UI can show it rather than failing silently.
  String? lastError;
  String? status;
  MicInfo? mic;

  /// Result of the most recent EQ / verify measurement, for the chart.
  FreqResponse? lastMeasurement;
  EqResult? lastEq;

  /// Most recent per-driver measurement + its crossover recommendation.
  FreqResponse? lastDriverMeasurement;
  CrossoverRecommendation? lastCrossoverRec;

  // --- live mic check -------------------------------------------------------
  StreamSubscription<MicLevel>? _levelSub;
  MicLevel? micLevel;
  bool monitoringMic = false;

  /// Starts/stops the input meter. Tapping the mic should visibly move it —
  /// that is the only proof the capture path really works before a sweep.
  Future<void> toggleMicMonitor() async {
    // Flip the flag first and notify, so the button always reflects the tap even
    // if the platform call is slow — and so a failure can flip it back rather
    // than leaving the UI and the recorder disagreeing.
    if (monitoringMic) {
      monitoringMic = false;
      micLevel = null;
      notifyListeners();
      await _levelSub?.cancel();
      _levelSub = null;
      try {
        await service.stopInputLevel();
      } catch (e) {
        status = 'Could not stop the mic meter: $e';
      }
    } else {
      monitoringMic = true;
      notifyListeners();
      try {
        _levelSub = service.inputLevels.listen(
          (l) {
            micLevel = l;
            notifyListeners();
          },
          onError: (Object e) {
            status = 'Mic meter error: $e';
            monitoringMic = false;
            notifyListeners();
          },
        );
        await service.startInputLevel();
      } catch (e) {
        status = 'Could not start the mic meter: $e';
        monitoringMic = false;
      }
    }
    notifyListeners();
  }

  // --- manual time alignment ------------------------------------------------
  /// Measured distance from the listening position to each driver, in cm.
  final Map<String, double> distancesCm = {};
  double celsius = 20;
  bool noisePlaying = false;

  /// Delays to enter in the DSP, derived from the distances.
  Map<String, double> get delaysMs =>
      delaysFromDistancesCm(distancesCm, celsius: celsius);

  void setDistance(String channelId, double? cm) {
    if (cm == null) {
      distancesCm.remove(channelId);
    } else {
      distancesCm[channelId] = cm;
    }
    project.delaysMs
      ..clear()
      ..addAll(delaysMs);
    store.save(project);
    notifyListeners();
  }

  void setTemperature(double c) {
    celsius = c;
    project.delaysMs
      ..clear()
      ..addAll(delaysMs);
    notifyListeners();
  }

  /// Loops band-limited pink noise so the centre image can be judged by ear.
  Future<void> toggleCentringNoise({double fLo = 200, double fHi = 4000}) async {
    if (noisePlaying) {
      await service.stopTone();
      noisePlaying = false;
    } else {
      await service.startCentringNoise(fLo: fLo, fHi: fHi);
      noisePlaying = true;
    }
    notifyListeners();
  }

  // --- SPL ------------------------------------------------------------------
  /// Latest live level while the meter runs, as SPL when calibrated.
  double? get liveSplDb => (micLevel == null || project.splOffsetDb == null)
      ? null
      : micLevel!.rmsDb + project.splOffsetDb!;

  /// Calibrate absolute SPL: the user reads a reference meter while the
  /// centring noise plays and types that number in. Relative comparisons
  /// between channels work without this.
  void calibrateSpl(double referenceSpl) {
    final lvl = micLevel;
    if (lvl == null) {
      status = 'Start the mic meter first, then calibrate.';
    } else {
      project.splOffsetDb = referenceSpl - lvl.rmsDb;
      store.save(project);
      status = 'SPL calibrated: offset '
          '${project.splOffsetDb!.toStringAsFixed(1)} dB.';
    }
    notifyListeners();
  }

  void clearSplCalibration() {
    project.splOffsetDb = null;
    store.save(project);
    notifyListeners();
  }

  /// A channel's captured level, as SPL when calibrated else dBFS.
  String levelLabel(String channelId) {
    final l = project.levelsDbfs[channelId];
    if (l == null) return '—';
    final off = project.splOffsetDb;
    return off == null
        ? '${l.toStringAsFixed(1)} dBFS'
        : '${(l + off).toStringAsFixed(1)} dB SPL';
  }

  // --- installed system ------------------------------------------------------
  CarSetup get setup => project.setup;

  /// Channels this system actually exposes to the DSP.
  List<Channel> get channels => setup.channels;

  /// Which driver is currently soloed for measurement.
  String? _measuringChannelId;
  Channel get measuringChannel {
    final list = channels;
    if (list.isEmpty) return const Channel('system', 'System');
    return list.firstWhere((c) => c.id == _measuringChannelId,
        orElse: () => list.first);
  }

  /// Picking a driver also picks a safe sweep band for it — you should never
  /// hand a tweeter a full-range sweep.
  void selectMeasuringChannel(String id) {
    _measuringChannelId = id;
    band = CarSetup.bandFor(measuringChannel);
    notifyListeners();
  }

  void updateSetup(CarSetup s) {
    project.setup = s;
    store.save(project);
    notifyListeners();
  }

  bool get hasCalibration => service.calibration != null;
  String? calibrationSummary;

  int eqMaxBands = 10;

  /// How hard the EQ corrects, as the target's percentile in the usable band.
  /// Lower flattens more but costs output level; higher is gentler. This is a
  /// genuine trade-off, not a right answer, so it is the user's to make.
  double eqStrength = 0.25;
  static const eqStrengths = <String, double>{
    'Aggressive — flattest, costs most level': 0.20,
    'Balanced': 0.25,
    'Gentle — least level lost': 0.45,
  };

  void setEqStrength(double v) {
    eqStrength = v;
    notifyListeners();
  }
  int averagingPositions = 3;

  /// The band to sweep. Set this to the driver under test before measuring —
  /// a full-range sweep into a tweeter can destroy it.
  SweepBand band = SweepBand.full;

  void setBand(SweepBand b) {
    band = b;
    notifyListeners();
  }

  Future<void> refreshMic() async {
    mic = await service.micStatus();
    notifyListeners();
  }

  /// Parse and apply a pasted/loaded UMIK-1 calibration file.
  void loadCalibration(String text) {
    final cal = MicCalibration.parse(text);
    if (cal.isEmpty) {
      status = 'Calibration file had no usable points.';
    } else {
      service.calibration = cal;
      calibrationSummary =
          '${cal.freqHz.length} points, ${cal.freqHz.first.toStringAsFixed(0)}–'
          '${cal.freqHz.last.toStringAsFixed(0)} Hz'
          '${cal.sensitivityDbFs != null ? ', sens ${cal.sensitivityDbFs} dB' : ''}';
    }
    notifyListeners();
  }

  /// Measure a single (soloed) driver and compute a crossover recommendation.
  Future<void> runCrossoverMeasurement(String channelId) async {
    await _run('Measuring driver…', () async {
      final m = await service.measureOnce(band: band);
      final fr = m.response;
      lastDriverMeasurement = fr;
      lastCrossoverRec = service.recommendCrossover(fr);
      project.measured[channelId] = fr;
      project.levelsDbfs[channelId] = m.levelDbfs;
      await store.save(project);
      final r = lastCrossoverRec!;
      status = 'Suggested '
          '${r.highPassHz != null ? 'HPF ${r.highPassHz!.toStringAsFixed(0)} Hz' : 'no HPF'}, '
          '${r.lowPassHz != null ? 'LPF ${r.lowPassHz!.toStringAsFixed(0)} Hz' : 'no LPF'}.';
    });
  }

  void goto(WizardStep s) {
    step = s;
    notifyListeners();
  }

  void next() {
    const order = WizardStep.values;
    final i = order.indexOf(step);
    if (i + 1 < order.length) step = order[i + 1];
    notifyListeners();
  }

  void back() {
    const order = WizardStep.values;
    final i = order.indexOf(step);
    if (i > 0) step = order[i - 1];
    notifyListeners();
  }

  /// Measure the full system (spatially averaged) and auto-fit EQ against a flat
  /// target. Stores both on the project under the 'system' key.
  Future<void> runEqMeasurement() async {
    await _run('Measuring system response…', () async {
      final m = await service.measureAveraged(averagingPositions, band: band);
      final fr = m.response;
      final eq = await service.fitEq(fr,
          maxBands: eqMaxBands, band: band, targetPercentile: eqStrength);
      lastMeasurement = fr;
      lastEq = eq;
      project.measured['system'] = fr;
      project.levelsDbfs['system'] = m.levelDbfs;
      project.eqBands['system'] = eq.bands;
      await store.save(project);
      status = 'Measured ${fr.length} points; ${eq.bands.length} EQ bands.';
    });
  }

  /// Verify pass: re-measure and store under 'verify' for before/after compare.
  Future<void> runVerifyMeasurement() async {
    await _run('Verifying…', () async {
      final m = await service.measureAveraged(averagingPositions, band: band);
      lastMeasurement = m.response;
      project.measured['verify'] = m.response;
      project.levelsDbfs['verify'] = m.levelDbfs;
      await store.save(project);
      status = 'Verify measurement saved.';
    });
  }

  void setCrossover(CrossoverSetting c) {
    project.crossovers
      ..removeWhere((e) => e.channelId == c.channelId)
      ..add(c);
    store.save(project);
    notifyListeners();
  }

  @override
  void dispose() {
    _levelSub?.cancel();
    service.stopInputLevel();
    if (noisePlaying) service.stopTone();
    service.stopTone();
    super.dispose();
  }

  Future<void> _run(String msg, Future<void> Function() body) async {
    busy = true;
    lastError = null;
    status = msg;
    notifyListeners();
    try {
      await body();
    } catch (e, st) {
      // Surface it. A measurement that fails silently is indistinguishable from
      // a dead button — which is exactly how this presented in the car.
      debugPrint('[rew] $msg failed: $e\n$st');
      lastError = '$e';
      status = 'Error: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
