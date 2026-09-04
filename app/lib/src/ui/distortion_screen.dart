// Harmonic distortion, from the sweep that was already taken.
//
// This is the one plot that answers "is something in the car actually
// struggling?" — a question a frequency response cannot answer at all. A dip in
// the response and a driver at its excursion limit look the same on a magnitude
// curve; here they look nothing alike, because a driver at its limit is putting
// energy out at two and three times the frequency it was asked for.
//
// The harmonics are drawn against the FUNDAMENTAL that produced them, which is
// what makes the plot readable: the bump you see at 80 Hz on the H2 trace is
// what the system does when it is asked for 80 Hz, not something happening at
// 160 Hz.
import 'package:flutter/material.dart';

import '../models/measurement.dart';
import 'detailed_chart.dart';
import 'fullscreen_chart.dart';

class DistortionScreen extends StatefulWidget {
  const DistortionScreen({
    super.key,
    required this.distortion,
    required this.title,
    this.subtitle = '',
  });

  final DistortionAnalysis distortion;
  final String title;
  final String subtitle;

  @override
  State<DistortionScreen> createState() => _DistortionScreenState();
}

class _DistortionScreenState extends State<DistortionScreen> {
  // Which harmonics are drawn. The 2nd and 3rd carry almost all of the useful
  // signal — the 2nd is what a driver reaching its limit makes, the 3rd what a
  // driver being clipped makes — so those two start on and the rest are there
  // for when someone wants them.
  final Set<int> _shown = {2, 3};

  static const _harmonicColors = <int, Color>{
    2: Color(0xFFE5A76B),
    3: Color(0xFFE57F7F),
    4: Color(0xFFB78AD1),
    5: Color(0xFF7FC7C1),
  };

  /// Harmonics as levels relative to the fundamental, which is how they are
  /// read: "40 dB down" is a statement about distortion, whereas the absolute
  /// level of the harmonic on its own is a statement about how loud the sweep
  /// happened to be played.
  FreqResponse _relative(FreqResponse harmonic) {
    final d = widget.distortion.fundamental;
    return FreqResponse(harmonic.freqHz, [
      for (var i = 0; i < harmonic.length; i++) harmonic.magDb[i] - d.magDb[i],
    ]);
  }

  List<DetailedTrace> get _traces {
    final d = widget.distortion;
    return [
      // The fundamental sits at 0 dB by definition once everything is relative
      // to it — drawn so there is a reference line to read the rest against.
      DetailedTrace(
        FreqResponse(d.fundamental.freqHz,
            List<double>.filled(d.fundamental.length, 0)),
        const Color(0xFF7FB2E5),
        'Fundamental',
      ),
      for (final h in _shown.toList()..sort())
        if (h - 2 < d.harmonics.length)
          DetailedTrace(_relative(d.harmonics[h - 2]),
              _harmonicColors[h] ?? Colors.grey, '${_ordinal(h)} harmonic'),
    ];
  }

  static String _ordinal(int h) => switch (h) {
        2 => '2nd',
        3 => '3rd',
        _ => '${h}th',
      };

  static String _hz(double f) => f >= 1000
      ? '${(f / 1000).toStringAsFixed(f >= 10000 ? 0 : 1)} kHz'
      : '${f.round()} Hz';

  /// What the worst figure means, in the terms someone tuning a car cares
  /// about. These thresholds are the conventional ones for loudspeakers: below
  /// about 1% nobody hears it, around 3% it is audible on sustained tones, and
  /// past 10% something is plainly wrong.
  ({String verdict, String detail, Color color}) get _reading {
    final worst = widget.distortion.worstThdPercent;
    final where = _hz(widget.distortion.worstThdHz);
    if (worst < 1) {
      return (
        verdict: 'Clean',
        detail: 'Nothing above 1% anywhere in the measured band. Distortion is '
            'not what is limiting this system at the level you measured at.',
        color: const Color(0xFF7FC77F),
      );
    }
    if (worst < 3) {
      return (
        verdict: 'Mild',
        detail: 'Peaks at ${worst.toStringAsFixed(1)}% around $where. Audible '
            'only on sustained tones, if at all. Worth remeasuring louder to '
            'see whether it climbs.',
        color: const Color(0xFFC7C77F),
      );
    }
    if (worst < 10) {
      return (
        verdict: 'Audible',
        detail: '${worst.toStringAsFixed(1)}% around $where. This is the level '
            'at which distortion starts being heard as hardness or buzz. If it '
            'is in the bass, the driver is probably being asked for more '
            'excursion than it has.',
        color: const Color(0xFFE5A76B),
      );
    }
    return (
      verdict: 'Something is wrong',
      detail: '${worst.toStringAsFixed(0)}% around $where. At this level a '
          'driver is being driven past its limit, an amplifier is clipping, or '
          'something is mechanically loose. Fix it before tuning: no EQ '
          'setting improves a system that is breaking up.',
      color: const Color(0xFFE57F7F),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.distortion;
    if (d.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Distortion')),
        body: const Center(
            child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
              'No distortion analysis for this measurement. It is taken from '
              'the sweep itself, so measuring again will produce it.',
              textAlign: TextAlign.center),
        )),
      );
    }
    final reading = _reading;
    return Scaffold(
      appBar: AppBar(title: const Text('Distortion')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            color: reading.color.withValues(alpha: 0.14),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(width: 10, height: 10,
                        decoration: BoxDecoration(
                            color: reading.color, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text(reading.verdict,
                        style: Theme.of(context).textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 6),
                  Text(reading.detail),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          DetailedFrChart(
            traces: _traces,
            title: widget.title,
            subtitle: widget.subtitle.isEmpty
                ? 'Harmonics relative to the fundamental'
                : '${widget.subtitle} · relative to the fundamental',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (var h = 2; h < 2 + d.harmonics.length; h++)
                FilterChip(
                  label: Text(_ordinal(h)),
                  selected: _shown.contains(h),
                  selectedColor:
                      (_harmonicColors[h] ?? Colors.grey).withValues(alpha: 0.3),
                  onSelected: (on) => setState(
                      () => on ? _shown.add(h) : _shown.remove(h)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => FullscreenChartScreen(
                  traces: _traces,
                  title: widget.title,
                  subtitle: 'Harmonics relative to the fundamental',
                ),
              )),
              icon: const Icon(Icons.fullscreen, size: 20),
              label: const Text('Full screen'),
            ),
          ),
          const SizedBox(height: 16),
          Text('How to read this',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          const Text(
            'Each harmonic is drawn against the frequency that produced it, and '
            'as a level below the fundamental. Further down is better: −40 dB '
            'is 1% distortion, −30 dB is 3%, −20 dB is 10%.\n\n'
            'A rise in the 2nd harmonic in the bass usually means a driver '
            'running out of excursion — the fix is a higher crossover point or '
            'less level, not EQ. A rise in the 3rd more often means clipping, '
            'somewhere in the amplifier or in the source. Either way, cutting '
            'that region is the honest response; boosting it makes it worse.\n\n'
            'Distortion depends on how loud the sweep was played, so this is a '
            'reading at that level and not a property of the system. Measuring '
            'again at the volume you actually listen at is what makes it useful.',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}
