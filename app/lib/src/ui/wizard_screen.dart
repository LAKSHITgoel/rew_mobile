import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/measurement.dart';
import '../models/project.dart';
import '../services/crossover_calc.dart';
import '../platform/file_picker.dart';
import '../services/dsp_math.dart';
import '../wizard/wizard_controller.dart';
import 'dsp_entry_sheet.dart';
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
      case WizardStep.setup:
        return _setupStep();
      case WizardStep.crossovers:
        return _crossoverStep();
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

  // ---- Steps --------------------------------------------------------------

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
                Row(children: [
                  FilledButton.tonalIcon(
                    onPressed: c.busy
                        ? null
                        : () => c.runCrossoverMeasurement('fl_tweeter'),
                    icon: const Icon(Icons.graphic_eq, size: 18),
                    label: const Text('Measure driver'),
                  ),
                  const SizedBox(width: 12),
                  if (rec != null)
                    Expanded(
                      child: Text(
                        'HPF ${rec.highPassHz?.toStringAsFixed(0) ?? '—'} Hz · '
                        'LPF ${rec.lowPassHz?.toStringAsFixed(0) ?? '—'} Hz',
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
        const SizedBox(height: 12),
        if (measured != null)
          FrChart(curves: [
            FrCurve(measured, Colors.blueGrey, 'Measured'),
            if (eq != null)
              FrCurve(applyEqPreview(measured, eq.bands, 48000), Colors.green,
                  'Predicted after EQ'),
          ]),
        if (eq != null) ...[
          const SizedBox(height: 12),
          Text('${eq.bands.length} bands recommended',
              style: Theme.of(context).textTheme.titleSmall),
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
