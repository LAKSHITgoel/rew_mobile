// The guided tuning state machine: setup -> crossovers -> EQ -> verify -> done.
// A ChangeNotifier so screens rebuild as measurements complete. It builds up a
// TuneProject and persists it via the ProjectStore.
import 'package:flutter/foundation.dart';

import '../audio/audio_backend.dart';
import '../models/measurement.dart';
import '../models/project.dart';
import '../services/measurement_service.dart';
import '../services/project_store.dart';

enum WizardStep { setup, crossovers, eq, verify, done }

extension WizardStepInfo on WizardStep {
  String get title => switch (this) {
        WizardStep.setup => 'Setup & level check',
        WizardStep.crossovers => 'Crossovers',
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

  WizardStep step = WizardStep.setup;
  bool busy = false;
  String? status;
  MicInfo? mic;

  /// Result of the most recent EQ / verify measurement, for the chart.
  FreqResponse? lastMeasurement;
  EqResult? lastEq;

  int eqMaxBands = 10;
  int averagingPositions = 3;

  Future<void> refreshMic() async {
    mic = await service.micStatus();
    notifyListeners();
  }

  void goto(WizardStep s) {
    step = s;
    notifyListeners();
  }

  void next() {
    final order = WizardStep.values;
    final i = order.indexOf(step);
    if (i + 1 < order.length) step = order[i + 1];
    notifyListeners();
  }

  void back() {
    final order = WizardStep.values;
    final i = order.indexOf(step);
    if (i > 0) step = order[i - 1];
    notifyListeners();
  }

  /// Measure the full system (spatially averaged) and auto-fit EQ against a flat
  /// target. Stores both on the project under the 'system' key.
  Future<void> runEqMeasurement() async {
    await _run('Measuring system response…', () async {
      final fr = await service.measureAveraged(averagingPositions);
      final eq = service.fitEq(fr, maxBands: eqMaxBands);
      lastMeasurement = fr;
      lastEq = eq;
      project.measured['system'] = fr;
      project.eqBands['system'] = eq.bands;
      await store.save(project);
      status = 'Measured ${fr.length} points; ${eq.bands.length} EQ bands.';
    });
  }

  /// Verify pass: re-measure and store under 'verify' for before/after compare.
  Future<void> runVerifyMeasurement() async {
    await _run('Verifying…', () async {
      final fr = await service.measureAveraged(averagingPositions);
      lastMeasurement = fr;
      project.measured['verify'] = fr;
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

  Future<void> _run(String msg, Future<void> Function() body) async {
    busy = true;
    status = msg;
    notifyListeners();
    try {
      await body();
    } catch (e) {
      status = 'Error: $e';
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
