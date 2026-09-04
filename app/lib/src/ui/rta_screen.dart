// The real-time analyser view.
//
// A live spectrum answers the questions a sweep cannot: what is rattling, how
// loud the car actually is right now, and whether a mode moves when you move
// your head. It is an instrument you pick up mid-job, so it stays out of the
// tuning sequence and is always one tap away instead.
import 'package:flutter/material.dart';

import '../models/measurement.dart';
import '../wizard/rta_controller.dart';
import 'fr_chart.dart';

class RtaScreen extends StatefulWidget {
  const RtaScreen({super.key, required this.controller});
  final RtaController controller;

  @override
  State<RtaScreen> createState() => _RtaScreenState();
}

Widget _label(BuildContext context, String text) => Text(text,
    style: Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(fontWeight: FontWeight.bold));

class _RtaScreenState extends State<RtaScreen> {
  RtaController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.start();
  }

  @override
  void dispose() {
    // Leaving the screen must release the microphone: holding it would keep the
    // USB mic busy and the next sweep would fail to open it.
    c.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final spl = c.splDb;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Real-time analyser'),
            actions: [
              IconButton(
                tooltip: c.running ? 'Pause' : 'Resume',
                icon: Icon(c.running ? Icons.pause : Icons.play_arrow),
                onPressed: () => c.running ? c.stop() : c.start(),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (c.error != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(c.error!),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    spl != null
                        ? '${spl.toStringAsFixed(1)} dB SPL'
                        : '${c.levelDbfs.toStringAsFixed(1)} dBFS',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(width: 10),
                  if (spl == null)
                    Expanded(
                      child: Text(
                        'Calibrate SPL in the wizard to read this as dB SPL.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (c.spectrum.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(child: Text('Listening…')),
                )
              else
                FrChart(
                  height: 260,
                  curves: [
                    FrCurve(c.spectrum, Colors.lightBlueAccent, 'Now'),
                    if (c.showPeakHold && !c.peak.isEmpty)
                      FrCurve(c.peak, Colors.orangeAccent, 'Peak hold'),
                  ],
                ),
              const SizedBox(height: 4),
              Text(
                c.pinkWeighted
                    ? 'Pink-weighted: pink noise reads as a flat line, so flat '
                        'on screen means it matches the reference.'
                    : 'Unweighted: pink noise slopes down 3 dB per octave, as '
                        'it actually does.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Divider(height: 28),
              _label(context, 'Display'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Octave bands'),
                subtitle: Text(c.octaveBands
                    ? 'Energy summed into 1/${c.bandsPerOctave.round()} octave '
                        'bands — how an RTA is normally read'
                    : 'Raw FFT lines'),
                value: c.octaveBands,
                onChanged: (v) => c.reconfigure(octaveBands: v),
              ),
              if (c.octaveBands)
                DropdownButton<double>(
                  value: c.bandsPerOctave,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 1.0, child: Text('1 octave')),
                    DropdownMenuItem(value: 3.0, child: Text('1/3 octave')),
                    DropdownMenuItem(value: 6.0, child: Text('1/6 octave')),
                    DropdownMenuItem(value: 12.0, child: Text('1/12 octave')),
                    DropdownMenuItem(value: 24.0, child: Text('1/24 octave')),
                    DropdownMenuItem(value: 48.0, child: Text('1/48 octave')),
                  ],
                  onChanged: (v) {
                    if (v != null) c.reconfigure(bandsPerOctave: v);
                  },
                )
              else
                DropdownButton<double>(
                  value: c.smoothFrac,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 0.0, child: Text('No smoothing')),
                    DropdownMenuItem(value: 24.0, child: Text('1/24 octave')),
                    DropdownMenuItem(value: 12.0, child: Text('1/12 octave')),
                    DropdownMenuItem(value: 6.0, child: Text('1/6 octave')),
                    DropdownMenuItem(value: 3.0, child: Text('1/3 octave')),
                  ],
                  onChanged: (v) {
                    if (v != null) c.reconfigure(smoothFrac: v);
                  },
                ),
              const SizedBox(height: 12),
              _label(context, 'Averaging'),
              DropdownButton<RtaAveraging>(
                value: c.averaging,
                isExpanded: true,
                items: [
                  for (final a in RtaAveraging.values)
                    DropdownMenuItem(value: a, child: Text(a.label)),
                ],
                onChanged: (v) {
                  if (v != null) c.reconfigure(averaging: v);
                },
              ),
              Text(c.averaging.description,
                  style: Theme.of(context).textTheme.bodySmall),
              if (c.averaging == RtaAveraging.exponential)
                DropdownButton<int>(
                  value: c.averageCount,
                  isExpanded: true,
                  items: [
                    for (final n in kRtaAverageCounts)
                      DropdownMenuItem(value: n, child: Text('$n averages')),
                  ],
                  onChanged: (v) {
                    if (v != null) c.reconfigure(averageCount: v);
                  },
                ),
              const SizedBox(height: 12),
              _label(context, 'Level weighting'),
              DropdownButton<SplWeighting>(
                value: c.weighting,
                isExpanded: true,
                items: [
                  for (final w in SplWeighting.values)
                    DropdownMenuItem(value: w, child: Text(w.label)),
                ],
                onChanged: (v) {
                  if (v != null) c.reconfigure(weighting: v);
                },
              ),
              Text(c.weighting.description,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              _label(context, 'FFT length'),
              DropdownButton<int>(
                value: c.fftSize,
                isExpanded: true,
                items: [
                  for (final n in kRtaFftSizes)
                    DropdownMenuItem(
                        value: n,
                        child: Text('$n  ·  '
                            '${(48000 / n).toStringAsFixed(1)} Hz per bin')),
                ],
                onChanged: (v) {
                  if (v != null) c.reconfigure(fftSize: v);
                },
              ),
              Text(
                  'Longer resolves modes that sit close together, but responds '
                  'more slowly because each block covers more time.',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Pink weighting'),
                subtitle: const Text('Makes pink noise read flat'),
                value: c.pinkWeighted,
                onChanged: (v) => c.reconfigure(pinkWeighted: v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Peak hold'),
                subtitle: const Text(
                    'Remembers the loudest level seen at each frequency — how '
                    'you catch something intermittent, like a rattle on one note'),
                value: c.showPeakHold,
                onChanged: (v) => c.reconfigure(showPeakHold: v),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: c.resetPeak,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Clear peak hold'),
                ),
              ),
              const Divider(height: 28),
              Text(
                'What this is for: play pink noise or music and watch the '
                'balance; tap the trim to find a rattle with peak hold on; or '
                'just sit with the engine running to see how much noise you '
                'are measuring against. For EQ and crossovers use the swept '
                'measurement instead — it separates the system from the noise, '
                'which this cannot.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
