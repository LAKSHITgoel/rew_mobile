// The measurement in time: impulse, step, energy decay, waterfall, decay time.
//
// One screen rather than four, because the four are one question asked four
// ways — what happened after the sound stopped — and the answers only mean
// something together. A long decay at 63 Hz is a number; the waterfall showing
// 63 Hz still standing when everything else has gone is the same fact in a form
// you can act on.
//
// All of it comes from the deconvolution, which takes a moment, so it is
// computed once on entry in a background isolate and then just drawn.
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../ffi/rewcore.dart';
import '../models/measurement.dart';
import 'time_charts.dart';

class TimeDomainScreen extends StatefulWidget {
  const TimeDomainScreen({
    super.key,
    required this.capture,
    required this.libraryPath,
    required this.title,
  });

  final RawCapture capture;
  final String? libraryPath;
  final String title;

  @override
  State<TimeDomainScreen> createState() => _TimeDomainScreenState();
}

class _TimeDomainScreenState extends State<TimeDomainScreen> {
  ImpulseView _impulse = const ImpulseView.empty();
  WaterfallView _waterfall = const WaterfallView.empty();
  DecayReport _decay = const DecayReport.empty();
  bool _busy = true;
  String? _error;

  // How much of the impulse response to show. The default is tight because the
  // interesting part of a car's impulse response is the first few
  // milliseconds; the rest is decay, which the other plots cover better.
  double _windowMs = 30;

  @override
  void initState() {
    super.initState();
    _compute();
  }

  Future<void> _compute() async {
    final cap = widget.capture;
    final lib = widget.libraryPath;
    try {
      final result = await Isolate.run(() {
        final core = Rewcore.open(libraryPath: lib);
        final impulse = core.impulseResponse(
          emitted: cap.emitted,
          recorded: cap.recorded,
          fs: cap.fs,
          preMs: 5,
          postMs: 400,
        );
        final waterfall = core.waterfall(
          emitted: cap.emitted,
          recorded: cap.recorded,
          fs: cap.fs,
          slices: 12,
          sliceSpacingMs: 15,
          windowMs: 80,
          fMin: 25,
          fMax: 500,
          points: 64,
        );
        final decay = core.decay(
          emitted: cap.emitted,
          recorded: cap.recorded,
          fs: cap.fs,
          fMin: 32,
          fMax: 8000,
        );
        return (impulse, waterfall, decay);
      });
      if (!mounted) return;
      setState(() {
        _impulse = result.$1;
        _waterfall = result.$2;
        _decay = result.$3;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  /// The impulse response cropped to the window the user picked. Cropping the
  /// data rather than zooming the axis keeps the vertical fit meaningful:
  /// otherwise the whole plot stays scaled to a peak that is off screen.
  ({List<double> t, List<double> ir, List<double> step}) _cropped() {
    final t = <double>[];
    final ir = <double>[];
    final step = <double>[];
    for (var i = 0; i < _impulse.timeMs.length; i++) {
      final ms = _impulse.timeMs[i];
      if (ms < -2 || ms > _windowMs) continue;
      t.add(ms);
      ir.add(_impulse.samples[i]);
      if (i < _impulse.step.length) step.add(_impulse.step[i]);
    }
    return (t: t, ir: ir, step: step);
  }

  static String _hz(double f) =>
      f >= 1000 ? '${(f / 1000).toStringAsFixed(1)} kHz' : '${f.round()} Hz';

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return Scaffold(
        appBar: AppBar(title: const Text('In time')),
        body: const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Working out the impulse response…'),
          ]),
        ),
      );
    }
    if (_error != null || _impulse.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('In time')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
                _error ??
                    'The impulse response could not be worked out from this '
                        'capture.',
                textAlign: TextAlign.center),
          ),
        ),
      );
    }

    final crop = _cropped();
    return Scaffold(
      appBar: AppBar(title: const Text('In time')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'A frequency response says how much came back at each frequency. '
            'It cannot say when. In a small hard space like a car, when is '
            'usually what makes bass sound slow — and it is the part EQ cannot '
            'fix.',
            style: TextStyle(fontSize: 13),
          ),
          const Divider(height: 28),

          if (_impulse.inverted)
            const Card(
              color: Color(0x33E57F7F),
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'The arrival is negative-going: this measurement is inverted. '
                  'Check the speaker wiring and the DSP channel polarity. On '
                  'its own an inverted system sounds much the same, but if one '
                  'driver is inverted and another is not, they cancel where '
                  'they overlap.',
                ),
              ),
            ),

          TimeChart(
            timeMs: crop.t,
            traces: [TimeTrace(crop.ir, const Color(0xFF7FB2E5), 'Impulse')],
            title: 'Impulse response',
            subtitle: 'One clean arrival is what you want. A second spike a few '
                'milliseconds later is a reflection — usually the windscreen or '
                'the door glass.',
            markerMs: 0,
          ),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Window', style: TextStyle(fontSize: 12)),
            Expanded(
              child: Slider(
                value: _windowMs,
                min: 5,
                max: 200,
                divisions: 39,
                label: '${_windowMs.round()} ms',
                onChanged: (v) => setState(() => _windowMs = v),
              ),
            ),
            SizedBox(
                width: 52,
                child: Text('${_windowMs.round()} ms',
                    style: const TextStyle(fontSize: 12))),
          ]),

          const SizedBox(height: 12),
          TimeChart(
            timeMs: crop.t,
            traces: [TimeTrace(crop.step, const Color(0xFF9BD17F), 'Step')],
            title: 'Step response',
            subtitle: 'Polarity at a glance: a correctly wired system steps up '
                'first, then settles back toward zero.',
            markerMs: 0,
          ),

          const SizedBox(height: 20),
          TimeChart(
            timeMs: _impulse.timeMs,
            traces: [
              TimeTrace(_impulse.energyDb, const Color(0xFFE5A76B), 'Energy'),
            ],
            title: 'Energy decay',
            subtitle: 'How the energy falls away, in dB below the arrival. '
                'Where it flattens out is the car\'s noise floor — nothing '
                'below that line was measured.',
            yMin: -70,
            yMax: 2,
            zeroLine: false,
            markerMs: 0,
          ),

          const SizedBox(height: 20),
          Text('Spectral decay', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 2),
          const Text(
            'The same spectrum, taken again every 15 ms. Front slice is the '
            'moment of arrival; the ones behind it are later.',
            style: TextStyle(fontSize: 11, color: Color(0xFF9AA3AC)),
          ),
          const SizedBox(height: 6),
          if (_waterfall.isEmpty)
            const Text('Not enough decay was captured to draw this.')
          else ...[
            WaterfallChart(
              freqHz: _waterfall.freqHz,
              timeMs: _waterfall.timeMs,
              slices: _waterfall.slices,
            ),
            const SizedBox(height: 6),
            Builder(builder: (context) {
              final r = _waterfall.ringing(afterMs: 60);
              if (r == null) return const SizedBox.shrink();
              return Text(
                '${r.timeMs.round()} ms after the arrival, ${_hz(r.freqHz)} is '
                'still the loudest thing left, ${r.levelDb.abs().toStringAsFixed(0)} dB '
                'down. A ridge that stays up while its neighbours fall is a '
                'resonance — a cabin mode or a panel. Cutting it with EQ makes '
                'it quieter but does not make it stop; damping or a different '
                'sub position is what actually shortens it.',
                style: const TextStyle(fontSize: 12),
              );
            }),
          ],

          const SizedBox(height: 24),
          Text('Decay time', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 2),
          const Text(
            'A true RT60 needs 60 dB of clean decay, which no car gives you — '
            'road and HVAC noise arrive first. These are fitted over whatever '
            'clean decay there was and extrapolated, and each row says which.',
            style: TextStyle(fontSize: 11, color: Color(0xFF9AA3AC)),
          ),
          const SizedBox(height: 8),
          if (_decay.isEmpty)
            const Text('No band decayed far enough above the noise to measure.')
          else ...[
            for (final b in _decay.bands)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(
                      width: 62,
                      child: Text(_hz(b.centerHz),
                          style: const TextStyle(fontSize: 12))),
                  Expanded(
                    child: b.basis == DecayBasis.none
                        ? const Text('—',
                            style: TextStyle(
                                fontSize: 12, color: Color(0xFF6E7681)))
                        : _bar(b),
                  ),
                  SizedBox(
                    width: 92,
                    child: Text(
                      b.basis == DecayBasis.none
                          ? 'not measurable'
                          : '${b.rt60Sec.toStringAsFixed(2)} s · ${b.basis.label}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 11,
                        color: b.trustworthy
                            ? null
                            : const Color(0xFF9AA3AC),
                      ),
                    ),
                  ),
                ]),
              ),
            const SizedBox(height: 10),
            Builder(builder: (context) {
              final w = _decay.worst;
              if (w == null) {
                return const Text(
                  'None of these bands decayed cleanly enough for the number to '
                  'be worth much. That usually means the car was too noisy — '
                  'engine off, doors shut, and measure again.',
                  style: TextStyle(fontSize: 12),
                );
              }
              return Text(
                'Longest reliable decay: ${w.rt60Sec.toStringAsFixed(2)} s at '
                '${_hz(w.centerHz)} (${w.basis.label}, fit '
                '${(w.straightness * 100).toStringAsFixed(0)}% straight over '
                '${w.usableRangeDb.toStringAsFixed(0)} dB of clean decay). '
                '${w.edtSec > 0 && w.edtSec < w.rt60Sec * 0.6 ? 'Its early decay is much faster than its late decay, which is the signature of a resonance ringing on after the sound itself has gone. ' : ''}'
                'In a car, anything much over about 0.4 s in the bass is heard '
                'as boom that does not stop when the note does.',
                style: const TextStyle(fontSize: 12),
              );
            }),
          ],
          const SizedBox(height: 16),
          Text(
            'This came from the sweep you already took — nothing extra was '
            'played. It is held in memory for the most recent measurement only, '
            'so reopening an older tune means measuring again.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// A bar per band. Scaled against half a second, which is well past the point
  /// where a car sounds slow, so the bars stay readable rather than all pinning.
  Widget _bar(BandDecay b) {
    final frac = (b.rt60Sec / 0.5).clamp(0.0, 1.0);
    return LayoutBuilder(builder: (context, c) {
      return Stack(children: [
        Container(
          height: 12,
          decoration: BoxDecoration(
            color: const Color(0xFF23282F),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        Container(
          height: 12,
          width: c.maxWidth * frac,
          decoration: BoxDecoration(
            // Dimmed when the fit is not solid, so a shaky number does not look
            // as confident as a good one.
            color: (b.rt60Sec > 0.4
                    ? const Color(0xFFE5A76B)
                    : const Color(0xFF6FC2FF))
                .withValues(alpha: b.trustworthy ? 1.0 : 0.35),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ]);
    });
  }
}
