// The wizard's deliverable: exactly what to type into the DSP's own app
// (parametric EQ bands and crossover points/slopes), as a scrollable checklist.
import 'package:flutter/material.dart';

import '../models/measurement.dart';
import '../models/project.dart';

class DspEntrySheet extends StatelessWidget {
  const DspEntrySheet({super.key, required this.project});
  final TuneProject project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final eq = project.eqBands['system'] ?? const <PeqBand>[];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Enter these into your DSP app',
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'The app does not change the DSP directly — copy these values into the '
          'Alpine app, then run the Verify step.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (project.crossovers.isNotEmpty) ...[
          Text('Crossovers', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _CrossoverTable(project.crossovers),
          const SizedBox(height: 20),
        ],
        if (project.delaysMs.isNotEmpty) ...[
          Text('Time alignment', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'From measured distances; the farthest driver is the reference at '
            '0 ms. Fine-tune by ear with the centring noise.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          _DelayTable(project.delaysMs),
          const SizedBox(height: 20),
        ],
        Text('Parametric EQ (${eq.length} bands)',
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (eq.isEmpty)
          const Text('Run the EQ step to generate bands.')
        else
          _EqTable(eq),
      ],
    );
  }
}

class _DelayTable extends StatelessWidget {
  const _DelayTable(this.delays);
  final Map<String, double> delays;

  String _channelName(String id) => Channel.defaults
      .firstWhere((c) => c.id == id, orElse: () => Channel(id, id))
      .name;

  @override
  Widget build(BuildContext context) {
    final entries = delays.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return Table(
      border: TableBorder.all(color: Theme.of(context).dividerColor),
      children: [
        const TableRow(children: [_HCell('Channel'), _HCell('Delay (ms)')]),
        for (final e in entries)
          TableRow(children: [
            _Cell(_channelName(e.key)),
            _Cell(e.value.toStringAsFixed(2)),
          ]),
      ],
    );
  }
}

class _EqTable extends StatelessWidget {
  const _EqTable(this.bands);
  final List<PeqBand> bands;

  @override
  Widget build(BuildContext context) {
    return Table(
      border: TableBorder.all(color: Theme.of(context).dividerColor),
      columnWidths: const {
        0: FixedColumnWidth(40),
        1: FlexColumnWidth(),
        2: FlexColumnWidth(),
        3: FlexColumnWidth(),
      },
      children: [
        const TableRow(children: [
          _HCell('#'),
          _HCell('Freq (Hz)'),
          _HCell('Gain (dB)'),
          _HCell('Q'),
        ]),
        for (var i = 0; i < bands.length; i++)
          TableRow(children: [
            _Cell('${i + 1}'),
            _Cell(bands[i].freqHz.toStringAsFixed(0)),
            _Cell(bands[i].gainDb.toStringAsFixed(1)),
            _Cell(bands[i].q.toStringAsFixed(2)),
          ]),
      ],
    );
  }
}

class _CrossoverTable extends StatelessWidget {
  const _CrossoverTable(this.settings);
  final List<CrossoverSetting> settings;

  String _channelName(String id) => Channel.defaults
      .firstWhere((c) => c.id == id, orElse: () => Channel(id, id))
      .name;

  @override
  Widget build(BuildContext context) {
    return Table(
      border: TableBorder.all(color: Theme.of(context).dividerColor),
      children: [
        const TableRow(children: [
          _HCell('Channel'),
          _HCell('HPF'),
          _HCell('LPF'),
          _HCell('Slope'),
        ]),
        for (final c in settings)
          TableRow(children: [
            _Cell(_channelName(c.channelId)),
            _Cell(c.highPassHz == null ? '—' : '${c.highPassHz!.toStringAsFixed(0)} Hz'),
            _Cell(c.lowPassHz == null ? '—' : '${c.lowPassHz!.toStringAsFixed(0)} Hz'),
            _Cell(c.slope.label.split(' ').first),
          ]),
      ],
    );
  }
}

class _HCell extends StatelessWidget {
  const _HCell(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Text(text,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
      );
}

class _Cell extends StatelessWidget {
  const _Cell(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Text(text, style: const TextStyle(fontSize: 13)),
      );
}
