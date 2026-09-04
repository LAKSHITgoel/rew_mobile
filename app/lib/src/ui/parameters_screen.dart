// The heuristics the app tunes by, the history behind them, and any changes an
// assistant has suggested.
//
// A proposal arrives here and stops. Nothing an assistant sends changes how the
// app tunes until it is read and applied on this screen — the model proposes,
// the person decides.
import 'package:flutter/material.dart';

import '../models/tuning_journal.dart';
import '../models/tuning_parameters.dart';
import '../services/journal_store.dart';

class ParametersScreen extends StatefulWidget {
  const ParametersScreen({super.key, required this.journal});
  final JournalStore journal;

  @override
  State<ParametersScreen> createState() => _ParametersScreenState();
}

class _ParametersScreenState extends State<ParametersScreen> {
  TuningParameters _current = TuningParameters.defaults;
  List<ParameterProposal> _proposals = const [];
  List<JournalEntry> _entries = const [];
  bool _loading = true;

  static const _labels = {
    'maxCutDb': 'Deepest cut',
    'maxBoostDb': 'Deepest boost',
    'targetPercentile': 'Target level',
    'minSnrDb': 'Signal-to-noise gate',
    'maxSpreadDb': 'Repeatability limit',
    'maxBands': 'Most EQ bands',
    'analysisSmoothFrac': 'Analysis smoothing',
    'averagingPositions': 'Positions averaged',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final current = await widget.journal.parameters();
    final proposals = await widget.journal.proposals();
    final entries = await widget.journal.entries(limit: 20);
    if (!mounted) return;
    setState(() {
      _current = current;
      _proposals = proposals.where((p) => !p.applied).toList();
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _apply(ParameterProposal p) async {
    // Checked again here, not only where it arrived: this is the last point
    // before it changes how the app tunes.
    final problems = p.parameters.problems();
    if (problems.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problems.first)));
      return;
    }
    await widget.journal.saveParameters(p.parameters);
    final all = await widget.journal.proposals();
    await widget.journal.replaceProposals([
      for (final q in all) if (q.at == p.at) q.markApplied() else q,
    ]);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Applied. It affects the next measurement.')));
  }

  Future<void> _dismiss(ParameterProposal p) async {
    final all = await widget.journal.proposals();
    await widget.journal
        .replaceProposals([for (final q in all) if (q.at != p.at) q]);
    await _load();
  }

  Future<void> _reset() async {
    await widget.journal.saveParameters(TuningParameters.defaults);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final improved = _entries.where((e) => e.improved == true).length;
    final scored = _entries.where((e) => e.improved != null).length;

    return Scaffold(
      appBar: AppBar(title: const Text('How this app tunes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'These are the judgement calls behind every recommendation — how '
            'deep a cut is worth making, how repeatable a feature has to be, '
            'where the flat target sits. The measurement maths is not in here; '
            'that part is fixed and tested. These are the opinions.',
          ),
          const SizedBox(height: 16),
          for (final e in _current.toJson().entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(_labels[e.key] ?? e.key),
              trailing: Text('${e.value}',
                  style: const TextStyle(fontFamily: 'monospace')),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Back to defaults'),
            ),
          ),
          const Divider(height: 28),
          Text('Suggested changes',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          if (_proposals.isEmpty)
            const Text(
              'None waiting. An assistant connected over the network can '
              'suggest changes from what is in the journal; they appear here '
              'and change nothing until you apply them.',
            )
          else
            for (final p in _proposals)
              Card(
                margin: const EdgeInsets.only(top: 10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${p.source} · ${_when(p.at)}',
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 6),
                      for (final d in _current.diff(p.parameters).entries)
                        Text(
                          '${_labels[d.key] ?? d.key}: '
                          '${d.value.from} → ${d.value.to}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13),
                        ),
                      const SizedBox(height: 8),
                      Text(p.rationale),
                      const SizedBox(height: 8),
                      Row(children: [
                        FilledButton(
                            onPressed: () => _apply(p),
                            child: const Text('Apply')),
                        const SizedBox(width: 8),
                        TextButton(
                            onPressed: () => _dismiss(p),
                            child: const Text('Dismiss')),
                      ]),
                    ],
                  ),
                ),
              ),
          const Divider(height: 28),
          Text('Recent sessions',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          if (_entries.isEmpty)
            const Text(
              'Nothing recorded yet. Every measurement writes down what was '
              'recommended and, after a verify pass, how it turned out — which '
              'is what any suggested change has to be argued from.',
            )
          else ...[
            if (scored > 0)
              Text('$improved of $scored fits measurably improved the response.',
                  style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            for (final e in _entries.take(10))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${e.tuneName} · ${e.event.name}'),
                subtitle: Text([
                  _when(e.at),
                  '${e.bands.length} bands',
                  if (e.initialErrorDb != null && e.finalErrorDb != null)
                    '${e.initialErrorDb!.toStringAsFixed(1)} → '
                        '${e.finalErrorDb!.toStringAsFixed(1)} dB',
                  if (e.usableToHz != null)
                    'clean to ${(e.usableToHz! / 1000).toStringAsFixed(1)} kHz',
                ].join('  ·  ')),
              ),
          ],
        ],
      ),
    );
  }

  static String _when(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}
