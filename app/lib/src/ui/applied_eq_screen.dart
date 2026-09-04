// Record what actually went into the DSP.
//
// Until now the journal knew what the app suggested and never whether anyone
// believed it. The difference is the most useful thing in there: a band changed
// the same way session after session is the heuristics being wrong in a
// consistent, fixable direction — which is precisely what should be learned
// from. A band skipped every time says the same about a rule that keeps
// recommending something nobody wants.
//
// So this screen is deliberately quick to get through: everything starts at
// "as recommended", and you only touch the ones you changed.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/measurement.dart';
import '../models/tuning_journal.dart';

class AppliedEqScreen extends StatefulWidget {
  const AppliedEqScreen({super.key, required this.recommended});
  final List<PeqBand> recommended;

  @override
  State<AppliedEqScreen> createState() => _AppliedEqScreenState();
}

enum _Fate { asRecommended, changed, skipped }

class _Row {
  _Row(this.band)
      : freq = TextEditingController(text: band.freqHz.toStringAsFixed(0)),
        gain = TextEditingController(text: band.gainDb.toStringAsFixed(1)),
        q = TextEditingController(text: band.q.toStringAsFixed(2));

  final PeqBand band;
  _Fate fate = _Fate.asRecommended;
  final TextEditingController freq;
  final TextEditingController gain;
  final TextEditingController q;

  void dispose() {
    freq.dispose();
    gain.dispose();
    q.dispose();
  }

  AppliedBand result() {
    switch (fate) {
      case _Fate.skipped:
        return AppliedBand(recommended: band);
      case _Fate.asRecommended:
        return AppliedBand(recommended: band, entered: band);
      case _Fate.changed:
        return AppliedBand(
          recommended: band,
          entered: PeqBand(
            freqHz: double.tryParse(freq.text) ?? band.freqHz,
            gainDb: double.tryParse(gain.text) ?? band.gainDb,
            q: double.tryParse(q.text) ?? band.q,
            reason: band.reason,
            confidence: band.confidence,
          ),
        );
    }
  }
}

class _AppliedEqScreenState extends State<AppliedEqScreen> {
  late final List<_Row> _rows =
      widget.recommended.map((b) => _Row(b)).toList();

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final changed = _rows.where((r) => r.fate == _Fate.changed).length;
    final skipped = _rows.where((r) => r.fate == _Fate.skipped).length;

    return Scaffold(
      appBar: AppBar(title: const Text('What you entered')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Mark anything you changed or left out when you typed these into '
            'the DSP. If you took the advice as it stands, just save.\n\n'
            'This is how the app finds out where its advice is consistently '
            'off — a band you always soften, or always skip, is worth more '
            'than any amount of theory.',
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < _rows.length; i++) _rowTile(i, _rows[i]),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => Navigator.of(context)
                .pop([for (final r in _rows) r.result()]),
            icon: const Icon(Icons.save_outlined),
            label: Text(changed == 0 && skipped == 0
                ? 'Save — entered as recommended'
                : 'Save — $changed changed, $skipped skipped'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _rowTile(int i, _Row r) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${i + 1}.  ${r.band.freqHz.toStringAsFixed(0)} Hz   '
              '${r.band.gainDb >= 0 ? '+' : ''}${r.band.gainDb.toStringAsFixed(1)} dB   '
              'Q ${r.band.q.toStringAsFixed(2)}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
            if (r.band.reason != PeqReason.unknown)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(r.band.reason.short,
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            const SizedBox(height: 8),
            SegmentedButton<_Fate>(
              segments: const [
                ButtonSegment(
                    value: _Fate.asRecommended, label: Text('As advised')),
                ButtonSegment(value: _Fate.changed, label: Text('Changed')),
                ButtonSegment(value: _Fate.skipped, label: Text('Skipped')),
              ],
              selected: {r.fate},
              onSelectionChanged: (s) => setState(() => r.fate = s.first),
            ),
            if (r.fate == _Fate.changed) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _field(r.freq, 'Hz')),
                const SizedBox(width: 8),
                Expanded(child: _field(r.gain, 'dB', signed: true)),
                const SizedBox(width: 8),
                Expanded(child: _field(r.q, 'Q')),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label, {bool signed = false}) =>
      TextField(
        controller: c,
        keyboardType:
            TextInputType.numberWithOptions(decimal: true, signed: signed),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
        ],
        decoration: InputDecoration(labelText: label, isDense: true),
      );
}
