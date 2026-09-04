// Checking whether two drivers work together through their crossover.
//
// This is the one part of phase-related tuning that survives a wireless link.
// Absolute arrival time over CarPlay or Bluetooth is not stable enough to
// trust, so anything derived from measured phase would be a guess dressed up
// as precision. Polarity does not need it: measure each driver alone and then
// the pair together, and compare what the pair actually produces against what
// two drivers summing properly would. Two fighting each other come out far
// below it, and the answer does not depend on when the sweep arrived.
//
// The app cannot mute channels — it only measures — so the sequence is a series
// of instructions to carry out in the DSP app, one measurement at a time.
import 'package:flutter/material.dart';

import '../models/measurement.dart';
import '../wizard/wizard_controller.dart';

class PolarityScreen extends StatefulWidget {
  const PolarityScreen({super.key, required this.controller});
  final WizardController controller;

  @override
  State<PolarityScreen> createState() => _PolarityScreenState();
}

class _PolarityScreenState extends State<PolarityScreen> {
  WizardController get c => widget.controller;

  Channel? _a;
  Channel? _b;

  FreqResponse? _aOnly, _bOnly, _both, _bothInverted;
  SummationResult? _result;
  String? _error;

  /// Which step is capturing, or null. This screen measures through the service
  /// directly rather than through the wizard's _run() wrapper, so it does not
  /// get the controller's busy flag for free — and without it the button gave
  /// no sign it was working and could be tapped again mid-sweep, starting a
  /// second capture over the first.
  String? _busyStep;

  /// Built once. `setup.channels` constructs a fresh list on every call, so a
  /// selection held from one call never matches an item from the next and the
  /// dropdown silently shows its hint instead of the choice you made.
  late final List<Channel> _channels = c.project.setup.channels;

  bool get _ready => _a != null && _b != null && _a != _b;

  Future<void> _measureInto(String what) async {
    if (_busyStep != null) return;
    setState(() {
      _error = null;
      _busyStep = what;
    });
    try {
      final m = await c.service.measureAveraged(1, band: SweepBand.full);
      if (!mounted) return;
      setState(() {
        switch (what) {
          case 'a':
            _aOnly = m.analysisResponse;
          case 'b':
            _bOnly = m.analysisResponse;
          case 'both':
            _both = m.analysisResponse;
          case 'inverted':
            _bothInverted = m.analysisResponse;
        }
        _recompute();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      // Cleared on every path: a capture that fails must not leave the screen
      // permanently unable to measure again.
      if (mounted) setState(() => _busyStep = null);
    }
  }

  void _recompute() {
    final a = _aOnly, b = _bOnly, both = _both;
    if (a == null || b == null || both == null) {
      _result = null;
      return;
    }
    _result = c.service.core.analyzeSummation(
      a: a,
      b: b,
      both: both,
      bothInverted: _bothInverted,
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Polarity & summation')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Two drivers sharing a crossover should reinforce each other where '
            'they overlap. If one is wired backwards they cancel instead, and '
            'the dip that leaves is the kind of thing EQ cannot fix — which is '
            'why this is worth checking before any EQ.\n\n'
            'This works by comparing levels, not timing, so the wireless delay '
            'to your car does not affect it.',
          ),
          const SizedBox(height: 16),
          _picker('First driver', _a, (v) => setState(() => _a = v)),
          const SizedBox(height: 8),
          _picker('Second driver', _b, (v) => setState(() => _b = v)),
          if (_a != null && _a == _b)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Pick two different drivers.'),
            ),
          const Divider(height: 28),
          if (!_ready)
            const Text('Choose the two drivers that share a crossover.')
          else ...[
            _step(
              1,
              'Play only ${_a!.name}',
              'Mute everything else in your DSP app, then measure.',
              _aOnly != null,
              'a',
            ),
            _step(
              2,
              'Play only ${_b!.name}',
              'Mute everything else, then measure.',
              _bOnly != null,
              'b',
            ),
            _step(
              3,
              'Play both together',
              'Unmute both — and only these two — then measure.',
              _both != null,
              'both',
            ),
            _step(
              4,
              'Both, with one inverted',
              'Optional, and the most reliable answer: flip the polarity of '
                  '${_b!.name} in the DSP, measure, then set it back. '
                  'Comparing the two directly beats inferring from one.',
              _bothInverted != null,
              'inverted',
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (result != null) ...[
            const Divider(height: 28),
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(result.advice.headline,
                        style: Theme.of(context).textTheme.titleMedium),
                    if (result.valid)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '${result.strength} '
                          '(${(result.confidence * 100).round()}%)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(result.explanation),
                    if (result.valid) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Measured through the overlap: '
                        '${result.measuredDb.toStringAsFixed(1)} dB. '
                        'A perfect sum would be '
                        '${result.coherentDb.toStringAsFixed(1)} dB; two '
                        'drivers arriving unrelated would give '
                        '${result.powerDb.toStringAsFixed(1)} dB.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'A note on what this cannot tell you: it says whether the pair '
            'adds up, not how far apart the drivers are. Time alignment needs '
            'absolute arrival time, and the wireless path does not give a '
            'stable enough one to trust — which is why the app measures '
            'polarity and leaves delay to the manual step.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _picker(String label, Channel? value,
          ValueChanged<Channel?> onChanged) =>
      Row(children: [
        SizedBox(width: 120, child: Text(label)),
        Expanded(
          child: DropdownButton<Channel>(
            value: value,
            isExpanded: true,
            hint: const Text('Choose'),
            items: [
              for (final ch in _channels)
                DropdownMenuItem(value: ch, child: Text(ch.name)),
            ],
            onChanged: (v) {
              onChanged(v);
              setState(() {
                // The old captures belong to the old pair.
                _aOnly = _bOnly = _both = _bothInverted = null;
                _result = null;
              });
            },
          ),
        ),
      ]);

  Widget _step(int n, String title, String detail, bool done, String step) {
    final measuringThis = _busyStep == step;
    final anyMeasuring = _busyStep != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            measuringThis
                ? Icons.graphic_eq
                : (done ? Icons.check_circle : Icons.circle_outlined),
            size: 20,
            color: measuringThis
                ? Theme.of(context).colorScheme.primary
                : (done ? Colors.green : Theme.of(context).disabledColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$n. $title',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(
                  measuringThis
                      ? 'Playing the sweep and recording — keep the '
                          'microphone still.'
                      : detail,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Every other step is disabled while one is running: two captures at
          // once would fight over the microphone and neither would be usable.
          FilledButton.tonal(
            onPressed: anyMeasuring ? null : () => _measureInto(step),
            child: measuringThis
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(done ? 'Again' : 'Measure'),
          ),
        ],
      ),
    );
  }
}
