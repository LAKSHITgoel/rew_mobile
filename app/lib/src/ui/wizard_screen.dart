import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/car_setup.dart';
import '../models/measurement.dart';
import '../models/project.dart';
import '../services/crossover_calc.dart';
import '../platform/file_picker.dart';
import '../services/dsp_math.dart';
import '../services/time_align.dart';
import '../wizard/wizard_controller.dart';
import 'detailed_chart.dart';
import 'dsp_entry_sheet.dart';
import 'measurement_detail_screen.dart';
import 'fr_chart.dart';

class WizardScreen extends StatefulWidget {
  const WizardScreen({super.key, required this.controller});
  final WizardController controller;

  @override
  State<WizardScreen> createState() => _WizardScreenState();
}

class _WizardScreenState extends State<WizardScreen> {
  // Local crossover editor state for the front 2-way section.
  double _xoverFc = 2500;
  XoverSlope _slope = XoverSlope.linkwitzRiley24;

  WizardController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.refreshMic();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(c.project.name),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: _stepBar(),
            ),
          ),
          body: SafeArea(child: _stepBody()),
          bottomNavigationBar: _navBar(),
        );
      },
    );
  }

  Widget _stepBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          for (final s in WizardStep.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Chip(
                label: Text(s.title, style: const TextStyle(fontSize: 11)),
                backgroundColor: s == c.step
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _stepBody() {
    switch (c.step) {
      case WizardStep.system:
        return _systemStep();
      case WizardStep.setup:
        return _setupStep();
      case WizardStep.crossovers:
        return _crossoverStep();
      case WizardStep.timeAlignment:
        return _timeAlignStep();
      case WizardStep.eq:
        return _eqStep();
      case WizardStep.verify:
        return _verifyStep();
      case WizardStep.done:
        return DspEntrySheet(project: c.project);
    }
  }

  /// Prefer the real document picker; a UMIK-1 cal file is ~600 lines, which
  /// nobody is going to paste on a phone. Falls back to pasting where no picker
  /// exists (desktop / tests).
  Future<void> _loadCalibration() async {
    try {
      final text = await NativeFilePicker.pickTextFile();
      if (text != null && text.trim().isNotEmpty) {
        c.loadCalibration(text);
      }
      return; // picked or cancelled — either way, don't fall through
    } on MissingPluginException {
      // no native picker on this platform; fall through to paste
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open file: ${e.message}')));
      }
      return;
    }
    await _pasteCalibration();
  }

  Future<void> _pasteCalibration() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste calibration file'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: ctrl,
            maxLines: 10,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText: '"20 0.5\\n1000 0.0\\n..." — the contents of your UMIK-1 .txt',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('Load')),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) c.loadCalibration(text);
  }

  /// Edit the current band's endpoints (or dial in a fresh custom range).
  /// Editing a preset produces a custom band rather than mutating the preset.
  Future<void> _editBand() async {
    final loCtl = TextEditingController(text: c.band.fLo.round().toString());
    final hiCtl = TextEditingController(text: c.band.fHi.round().toString());
    String? error;

    final band = await showDialog<SweepBand>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Sweep range'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: loCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Low (Hz)', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: hiCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'High (Hz)', border: OutlineInputBorder()),
                  ),
                ),
              ]),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final lo = double.tryParse(loCtl.text.trim());
                final hi = double.tryParse(hiCtl.text.trim());
                if (lo == null || hi == null) {
                  setLocal(() => error = 'Enter numbers in Hz.');
                  return;
                }
                if (lo < SweepBand.minHz || hi > SweepBand.maxHz) {
                  setLocal(() => error =
                      'Stay within ${SweepBand.minHz.round()}–${SweepBand.maxHz.round()} Hz.');
                  return;
                }
                if (lo >= hi) {
                  setLocal(() => error = 'Low must be below high.');
                  return;
                }
                Navigator.pop(context, SweepBand.custom(lo, hi));
              },
              child: const Text('Use range'),
            ),
          ],
        ),
      ),
    );
    if (band != null) c.setBand(band);
  }

  /// Per-driver detail. This one carries phase — a single capture is not
  /// power-averaged — which is what you need to judge whether a crossover is
  /// actually summing rather than cancelling.
  void _openDriverDetail() {
    final fr = c.lastDriverMeasurement;
    if (fr == null) return;
    final ch = c.measuringChannel;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MeasurementDetailScreen(
        title: '${c.project.name} — ${ch.name}',
        subtitle: '${c.band.label} · '
            '1/${c.service.config.smoothFrac.toStringAsFixed(0)} octave '
            'smoothing · ${c.hasCalibration ? 'mic-calibrated' : 'no mic calibration'} '
            '· level ${c.levelLabel(ch.id)}',
        traces: [
          DetailedTrace(fr, const Color(0xFF7FB2E5), ch.name,
              showPhase: fr.hasPhase),
        ],
      ),
    ));
  }

  /// Full-size graph with export, for getting a second opinion on a result
  /// that looks wrong.
  void _openDetail(FreqResponse measured, EqResult? eq) {
    final traces = <DetailedTrace>[
      DetailedTrace(measured, const Color(0xFF7FB2E5), 'Measured',
          showPhase: measured.hasPhase),
      if (eq != null)
        DetailedTrace(applyEqPreview(measured, eq.bands, 48000).predicted,
            const Color(0xFF6DD98C), 'Predicted after EQ (level-matched)'),
    ];
    final cal = c.hasCalibration ? 'mic-calibrated' : 'no mic calibration';
    final lvl = c.levelLabel('system');
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MeasurementDetailScreen(
        title: '${c.project.name} — ${c.band.label}',
        subtitle: '1/${c.service.config.smoothFrac.toStringAsFixed(0)} octave '
            'smoothing · $cal · level $lvl · '
            '${DateTime.now().toLocal().toString().split('.').first}',
        traces: traces,
      ),
    ));
  }

  /// One-time absolute-SPL calibration. The mic's own sensitivity can't give
  /// this on a phone (the USB/Android capture gain is unknown), so we calibrate
  /// against whatever reference meter the user has.
  Future<void> _calibrateSpl() async {
    final ctl = TextEditingController();
    final spl = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Calibrate SPL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Play a steady signal, hold a reference SPL meter (or a phone SPL '
              'app) right next to the measurement mic, and type its reading. '
              'Only needed for absolute numbers — matching drivers to each other '
              'works without it.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Reference reading',
                  suffixText: 'dB SPL',
                  border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, double.tryParse(ctl.text.trim())),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (spl != null) c.calibrateSpl(spl);
  }

  /// Live input meter. Showing the mic's *name* only proves it enumerated;
  /// this proves the capture path actually carries audio.
  Widget _micCheckCard() {
    final lvl = c.micLevel;
    // Map -70..0 dBFS onto 0..1 for the bar.
    final frac = lvl == null ? 0.0 : ((lvl.rmsDb + 70) / 70).clamp(0.0, 1.0);
    final ok = lvl != null && lvl.hasSignal;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Mic check',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                FilledButton.tonal(
                  onPressed: c.toggleMicMonitor,
                  child: Text(c.monitoringMic ? 'Stop' : 'Test mic'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              c.monitoringMic
                  ? 'Tap or speak into the mic — the bar must move. If it stays '
                      'flat the mic is connected but not capturing.'
                  : 'Confirms the mic is not just detected but actually hearing.',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 10,
                color: ok ? Colors.green : Colors.orange,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              lvl == null
                  ? '—'
                  : 'RMS ${lvl.rmsDb.toStringAsFixed(1)} dBFS   ·   '
                      'peak ${lvl.peakDb.toStringAsFixed(1)} dBFS'
                      '${ok ? '  ·  signal OK' : '  ·  very quiet'}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            if (c.liveSplDb != null)
              Text('${c.liveSplDb!.toStringAsFixed(1)} dB SPL',
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Row(children: [
              TextButton.icon(
                onPressed: c.monitoringMic ? _calibrateSpl : null,
                icon: const Icon(Icons.speed, size: 16),
                label: Text(c.project.splOffsetDb == null
                    ? 'Calibrate SPL'
                    : 'Recalibrate SPL'),
              ),
              if (c.project.splOffsetDb != null)
                TextButton(
                    onPressed: c.clearSplCalibration,
                    child: const Text('Clear')),
            ]),
            Text(
              c.project.splOffsetDb == null
                  ? 'Uncalibrated: levels are relative only — still enough to '
                      'match drivers to each other.'
                  : 'Offset ${c.project.splOffsetDb!.toStringAsFixed(1)} dB.',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  /// Per-channel captured levels. Matching drivers to each other is the point:
  /// an unmatched pair tilts the summed response before EQ ever gets involved,
  /// and the differences are exact whether or not SPL has been calibrated.
  Widget _channelLevelsCard() {
    final levels = Map<String, double>.from(c.project.levelsDbfs)
      ..removeWhere((k, _) => k == 'system' || k == 'verify');
    if (levels.isEmpty) return const SizedBox.shrink();

    final values = levels.values.toList()..sort();
    final spread = values.last - values.first;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Measured channel levels',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            for (final e in levels.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                      flex: 5,
                      child: Text(
                          Channel.defaults
                              .firstWhere((ch) => ch.id == e.key,
                                  orElse: () => Channel(e.key, e.key))
                              .name,
                          style: const TextStyle(fontSize: 13))),
                  Expanded(
                    flex: 4,
                    child: Text(c.levelLabel(e.key),
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 13)),
                  ),
                ]),
              ),
            if (levels.length > 1) ...[
              const SizedBox(height: 6),
              Text(
                'Spread ${spread.toStringAsFixed(1)} dB — '
                '${spread <= 1.0 ? 'well matched.' : 'trim channel gains in the '
                    'DSP until they agree within ~1 dB, then re-measure.'}',
                style: TextStyle(
                    fontSize: 12,
                    color: spread <= 1.0 ? Colors.green : Colors.orange),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Band picker. Sweeping only the driver under test is a safety matter, not
  /// just an accuracy one.
  Widget _bandSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Sweep band',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            TextButton.icon(
              onPressed: _editBand,
              icon: const Icon(Icons.tune, size: 16),
              label: const Text('Edit range'),
            ),
          ],
        ),
        DropdownButton<SweepBand>(
          value: c.band,
          isExpanded: true,
          items: [
            for (final b in SweepBand.presets)
              DropdownMenuItem(
                value: b,
                child: Text(b.label, style: const TextStyle(fontSize: 13)),
              ),
            // A custom band isn't in the presets, so it has to be offered
            // explicitly or the dropdown would have no matching value.
            if (!SweepBand.presets.contains(c.band))
              DropdownMenuItem(
                value: c.band,
                child: Text(c.band.label, style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged: (b) => c.setBand(b ?? c.band),
        ),
        if (c.band.isFullRange)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
              'Full range sends 20 Hz to whatever is soloed. With a tweeter '
              'soloed, pick the Tweeter band first — a full-range sweep can '
              'destroy it.',
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
      ],
    );
  }

  // ---- Steps --------------------------------------------------------------

  Widget _systemStep() {
    final setup = c.setup;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('What is installed?',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'This decides which channels get measured and which sweep each one is '
          'given. Answer once — the rest of the wizard follows from it.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        _setupDropdown<FrontConfig>(
          'Front stage',
          setup.front,
          FrontConfig.values,
          (v) => v.label,
          (v) => c.updateSetup(setup.copyWith(front: v)),
        ),
        _setupDropdown<RearConfig>(
          'Rear speakers',
          setup.rear,
          RearConfig.values,
          (v) => v.label,
          (v) => c.updateSetup(setup.copyWith(rear: v)),
        ),
        _setupDropdown<SubConfig>(
          'Subwoofer',
          setup.sub,
          SubConfig.values,
          (v) => v.label,
          (v) => c.updateSetup(setup.copyWith(sub: v)),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Plan',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                for (final n in setup.planNotes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('• $n', style: const TextStyle(fontSize: 13)),
                  ),
                const Divider(),
                const Text('Channels to measure',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                for (final ch in c.channels)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(children: [
                      Expanded(flex: 5, child: Text(ch.name,
                          style: const TextStyle(fontSize: 13))),
                      Expanded(
                        flex: 5,
                        child: Text(CarSetup.bandFor(ch).label,
                            style: const TextStyle(fontSize: 11)),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _setupDropdown<T>(String label, T value, List<T> options,
      String Function(T) labelOf, void Function(T) onPick) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          DropdownButton<T>(
            value: value,
            isExpanded: true,
            items: [
              for (final o in options)
                DropdownMenuItem(
                    value: o,
                    child: Text(labelOf(o),
                        style: const TextStyle(fontSize: 13))),
            ],
            onChanged: (v) { if (v != null) onPick(v); },
          ),
        ],
      ),
    );
  }

  Widget _setupStep() {
    final mic = c.mic;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: Icon(mic?.connected == true ? Icons.mic : Icons.mic_off,
                color: mic?.connected == true ? Colors.green : Colors.red),
            title: Text(mic?.connected == true
                ? (mic?.name ?? 'Microphone connected')
                : 'No microphone detected'),
            subtitle: const Text('UMIK-1 over USB'),
            trailing: TextButton(
                onPressed: c.refreshMic, child: const Text('Refresh')),
          ),
        ),
        const SizedBox(height: 12),
        _micCheckCard(),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: Icon(c.hasCalibration ? Icons.verified : Icons.rule,
                color: c.hasCalibration ? Colors.green : null),
            title: Text(c.hasCalibration
                ? 'Calibration loaded'
                : 'Load UMIK-1 calibration'),
            subtitle: Text(c.calibrationSummary ??
                'Load your mic\'s calibration .txt so measurements reflect the '
                    'speakers, not the mic.'),
            trailing: TextButton(
              onPressed: _loadCalibration,
              child: Text(c.hasCalibration ? 'Replace' : 'Load'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const _InfoCard(
          icon: Icons.bluetooth_audio,
          title: 'Audio path',
          body: 'The sweep plays out as media over wireless CarPlay / Android Auto / '
              'Bluetooth, so it passes through your OEM processing and the DSP — the '
              'real chain you listen to. Keep the phone connected to the car.',
        ),
        const _InfoCard(
          icon: Icons.tune,
          title: 'Per-driver measuring',
          body: 'When a step asks, solo the relevant channel in the Alpine app so only '
              'that driver plays while it is measured.',
        ),
        const _InfoCard(
          icon: Icons.warning_amber,
          title: 'Level',
          body: 'Set a moderate, fixed volume. If OEM loudness/dynamic processing is '
              'active the response can change with level — keep it constant.',
        ),
      ],
    );
  }

  Widget _crossoverStep() {
    final sum = summation(_xoverFc, _slope, _slope);
    final summedFr = FreqResponse(sum.freqHz, sum.summedDb);
    final rec = c.lastCrossoverRec;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Front 2-way crossover', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Measured recommendation',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text(
                  'Solo the tweeter (or mid) in the Alpine app, then measure — the app '
                  'reads its natural roll-off and suggests a crossover.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                const Text('Driver under test',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                DropdownButton<String>(
                  value: c.measuringChannel.id,
                  isExpanded: true,
                  items: [
                    for (final ch in c.channels)
                      DropdownMenuItem(
                          value: ch.id,
                          child: Text(ch.name,
                              style: const TextStyle(fontSize: 13))),
                  ],
                  onChanged: (v) {
                    if (v != null) c.selectMeasuringChannel(v);
                  },
                ),
                const SizedBox(height: 8),
                _bandSelector(),
                const SizedBox(height: 8),
                Row(children: [
                  FilledButton.tonalIcon(
                    onPressed: c.busy
                        ? null
                        : () => c.runCrossoverMeasurement(
                            c.measuringChannel.id),
                    icon: const Icon(Icons.graphic_eq, size: 18),
                    label: const Text('Measure driver'),
                  ),
                  const SizedBox(width: 12),
                  if (rec != null)
                    Expanded(
                      child: Text(
                        'HPF ${rec.highPassHz?.toStringAsFixed(0) ?? '—'} Hz · '
                        'LPF ${rec.lowPassHz?.toStringAsFixed(0) ?? '—'} Hz\n'
                        'level ${c.levelLabel(c.measuringChannel.id)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ]),
                if (rec?.highPassHz != null)
                  TextButton(
                    onPressed: () =>
                        setState(() => _xoverFc = rec!.highPassHz!),
                    child: const Text('Use suggested crossover'),
                  ),
              ],
            ),
          ),
        ),
        if (c.lastDriverMeasurement != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _openDriverDetail(),
            icon: const Icon(Icons.insights),
            label: Text('Detailed graph & export — ${c.measuringChannel.name}'),
          ),
        ],
        const SizedBox(height: 8),
        _channelLevelsCard(),
        const SizedBox(height: 8),
        Text('Crossover: ${_xoverFc.toStringAsFixed(0)} Hz'),
        Slider(
          min: 1500,
          max: 5000,
          divisions: 70,
          value: _xoverFc,
          label: '${_xoverFc.toStringAsFixed(0)} Hz',
          onChanged: (v) => setState(() => _xoverFc = v),
        ),
        DropdownButton<XoverSlope>(
          value: _slope,
          isExpanded: true,
          items: [
            for (final s in XoverSlope.values)
              DropdownMenuItem(value: s, child: Text(s.label)),
          ],
          onChanged: (v) => setState(() => _slope = v ?? _slope),
        ),
        const SizedBox(height: 8),
        Text('Predicted summation (deviation ${sum.maxDeviationDb.toStringAsFixed(2)} dB)',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        FrChart(
          curves: [FrCurve(summedFr, Colors.blue, 'Tweeter + Mid summed')],
          dbMin: -18,
          dbMax: 6,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () {
            // Tweeter high-passed, mid low-passed at the chosen point.
            c.setCrossover(CrossoverSetting(
                channelId: 'fl_tweeter',
                highPassHz: _xoverFc,
                lowPassHz: null,
                slope: _slope));
            c.setCrossover(CrossoverSetting(
                channelId: 'fl_mid',
                highPassHz: null,
                lowPassHz: _xoverFc,
                slope: _slope));
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Crossover saved')));
          },
          child: const Text('Save crossover'),
        ),
      ],
    );
  }

  Widget _timeAlignStep() {
    final delays = c.delaysMs;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Manual time alignment',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const _InfoCard(
          icon: Icons.straighten,
          title: 'Why this is measured by hand',
          body: 'The sweep reaches the car over Bluetooth, whose latency is '
              'neither known nor stable, so the app cannot honestly measure '
              'arrival times. Physical distances are exact, though — and only '
              'the differences between drivers matter, so distances give correct '
              'delays. Refine by ear afterwards.',
        ),
        const _InfoCard(
          icon: Icons.rule,
          title: 'Method',
          body: '1. Sit in your normal listening position.\n'
              '2. Measure from the centre of your head to each driver (a tape '
              'measure or a phone laser app; be consistent).\n'
              '3. Enter the distances below and copy the delays into the Alpine '
              'app — the farthest driver gets 0 and everything closer is delayed.\n'
              '4. Play the centring noise below and refine: the image should sit '
              'dead centre on the dashboard. If it pulls left, add a little delay '
              'to the LEFT side (you are delaying the side that arrives first).\n'
              '5. Change one channel at a time, in 0.05-0.1 ms steps.',
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Centring signal',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text(
                  'Band-limited pink noise (200 Hz – 4 kHz). Narrowing it to the '
                  'midrange is deliberate: that is where your ears localise best, '
                  'and it keeps bass room modes from smearing the image.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  FilledButton.tonalIcon(
                    onPressed: () => c.toggleCentringNoise(),
                    icon: Icon(c.noisePlaying ? Icons.stop : Icons.play_arrow,
                        size: 18),
                    label: Text(c.noisePlaying ? 'Stop noise' : 'Play centring noise'),
                  ),
                  const SizedBox(width: 12),
                  if (c.noisePlaying)
                    const Expanded(
                      child: Text('Playing — adjust delays in the Alpine app.',
                          style: TextStyle(fontSize: 12)),
                    ),
                ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Text('Air temperature'),
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: TextField(
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(suffixText: '°C', isDense: true),
              controller: TextEditingController(text: c.celsius.round().toString()),
              onSubmitted: (v) {
                final t = double.tryParse(v);
                if (t != null) c.setTemperature(t);
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text('sound ≈ ${speedOfSound(celsius: c.celsius).toStringAsFixed(1)} m/s',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ]),
        const SizedBox(height: 12),
        Text('Distance to each driver',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final ch in c.channels)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(flex: 4, child: Text(ch.name)),
                Expanded(
                  flex: 3,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        suffixText: 'cm', isDense: true, hintText: '—'),
                    onSubmitted: (v) =>
                        c.setDistance(ch.id, double.tryParse(v.trim())),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: Text(
                    delays[ch.id] == null
                        ? '—'
                        : '${delays[ch.id]!.toStringAsFixed(2)} ms',
                    style: const TextStyle(
                        fontFamily: 'monospace', fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Text(
          delays.isEmpty
              ? 'Enter at least two distances to get delays.'
              : 'Enter these delays in the Alpine app, then use the noise above '
                  'to fine-tune by ear.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _eqStep() {
    final measured = c.lastMeasurement;
    final eq = c.lastEq;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Measure the system and auto-fit EQ',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            FilledButton.icon(
              onPressed: c.busy ? null : c.runEqMeasurement,
              icon: c.busy
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.graphic_eq),
              label: const Text('Measure'),
            ),
          ],
        ),
        if (c.status != null) ...[
          const SizedBox(height: 8),
          Text(c.status!, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 8),
        _bandSelector(),
        const SizedBox(height: 12),
        if (measured != null)
          FrChart(curves: [
            FrCurve(measured, Colors.blueGrey, 'Measured'),
            if (eq != null)
              FrCurve(applyEqPreview(measured, eq.bands, 48000).predicted,
                  Colors.green, 'Predicted after EQ (level-matched)'),
          ]),
        if (eq != null) ...[
          const SizedBox(height: 12),
          Text('${eq.bands.length} bands recommended',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Builder(builder: (context) {
            final prev = applyEqPreview(measured!, eq.bands, 48000);
            final drop = prev.levelChangeDb;
            return Text(
              'Flatness ${eq.initialErrorDb.toStringAsFixed(1)} → '
              '${eq.finalErrorDb.toStringAsFixed(1)} dB RMS'
              '${drop < -0.5 ? '  ·  costs ${(-drop).toStringAsFixed(1)} dB of '
                  'output — raise the DSP gain to make it back' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            );
          }),
          const SizedBox(height: 8),
          for (var i = 0; i < eq.bands.length; i++)
            Text(
              '  ${i + 1}.  ${eq.bands[i].freqHz.toStringAsFixed(0)} Hz   '
              '${eq.bands[i].gainDb >= 0 ? '+' : ''}${eq.bands[i].gainDb.toStringAsFixed(1)} dB   '
              'Q ${eq.bands[i].q.toStringAsFixed(2)}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => FractionallySizedBox(
                  heightFactor: 0.8, child: DspEntrySheet(project: c.project)),
            ),
            icon: const Icon(Icons.list_alt),
            label: const Text('View DSP entry sheet'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed:
                measured == null ? null : () => _openDetail(measured, eq),
            icon: const Icon(Icons.insights),
            label: const Text('Detailed graph & export'),
          ),
        ],
      ],
    );
  }

  Widget _verifyStep() {
    final before = c.project.measured['system'];
    final after = c.project.measured['verify'];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Re-measure to confirm',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            FilledButton.icon(
              onPressed: c.busy ? null : c.runVerifyMeasurement,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Measure'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text('Enter the recommended EQ into the Alpine app first, then measure.'),
        const SizedBox(height: 12),
        if (before != null || after != null)
          FrChart(curves: [
            if (before != null) FrCurve(before, Colors.blueGrey, 'Before (no EQ)'),
            if (after != null) FrCurve(after, Colors.green, 'After EQ'),
          ]),
      ],
    );
  }

  // ---- Navigation ---------------------------------------------------------

  Widget _navBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            onPressed: c.step == WizardStep.setup ? null : c.back,
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: c.step == WizardStep.done ? () => Navigator.pop(context) : c.next,
            child: Text(c.step == WizardStep.done ? 'Finish' : 'Next'),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title, body;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(body, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
