// Bar rendering for the real-time analyser, as REW draws it.
//
// Bars are not decoration. A band is the energy in an interval, and a bar says
// that: it has a width, it stands on the floor, and its height is a quantity
// you can compare with its neighbours at a glance. A line through the same
// values implies something continuous between them that was never measured,
// and — worse for a moving display — a line's shape draws the eye to slopes,
// while what you actually want from an RTA is which band is loudest right now.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/measurement.dart';

class RtaBarChart extends StatelessWidget {
  const RtaBarChart({
    super.key,
    required this.spectrum,
    this.peak,
    this.bandsPerOctave = 24,
    this.fMin = 20,
    this.fMax = 20000,
    this.height = 260,
    this.barColor = const Color(0xFF6FC2FF),
    this.peakColor = const Color(0xFFFFB74D),
  });

  final FreqResponse spectrum;
  final FreqResponse? peak;
  final double bandsPerOctave;
  final double fMin, fMax, height;
  final Color barColor, peakColor;

  /// The dB window to draw. Fitted to the data, rounded out, and never narrower
  /// than 30 dB — an RTA on a tight range turns ordinary noise into drama.
  ({double lo, double hi}) _range() {
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final v in spectrum.magDb) {
      if (v.isNaN || v.isInfinite) continue;
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    for (final v in peak?.magDb ?? const <double>[]) {
      if (v.isFinite && v > hi) hi = v;
    }
    if (lo > hi) return (lo: -100, hi: -20);
    lo = (lo / 10).floorToDouble() * 10;
    hi = (hi / 10).ceilToDouble() * 10 + 5;
    if (hi - lo < 30) lo = hi - 30;
    // Bars stand on the floor, so a floor far below the quietest band wastes
    // most of the height on empty space.
    if (hi - lo > 90) lo = hi - 90;
    return (lo: lo, hi: hi);
  }

  @override
  Widget build(BuildContext context) {
    final range = _range();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _RtaBarPainter(
              spectrum: spectrum,
              peak: peak,
              bandsPerOctave: bandsPerOctave,
              fMin: fMin,
              fMax: fMax,
              dbMin: range.lo,
              dbMax: range.hi,
              barColor: barColor,
              peakColor: peakColor,
            ),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          _key(barColor, 'Now'),
          if (peak != null && !peak!.isEmpty) ...[
            const SizedBox(width: 14),
            _key(peakColor, 'Peak hold'),
          ],
        ]),
      ],
    );
  }

  Widget _key(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 8, color: c),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11)),
      ]);
}

class _RtaBarPainter extends CustomPainter {
  _RtaBarPainter({
    required this.spectrum,
    required this.peak,
    required this.bandsPerOctave,
    required this.fMin,
    required this.fMax,
    required this.dbMin,
    required this.dbMax,
    required this.barColor,
    required this.peakColor,
  });

  final FreqResponse spectrum;
  final FreqResponse? peak;
  final double bandsPerOctave, fMin, fMax, dbMin, dbMax;
  final Color barColor, peakColor;

  static const _padL = 38.0, _padR = 8.0, _padT = 8.0, _padB = 20.0;

  double _x(double f, Size s) {
    final t = math.log(f / fMin) / math.log(fMax / fMin);
    return _padL + t * (s.width - _padL - _padR);
  }

  double _y(double db, Size s) {
    final t = (db - dbMin) / (dbMax - dbMin);
    return _padT + (1 - t.clamp(0.0, 1.0)) * (s.height - _padT - _padB);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(_padL, _padT, size.width - _padR,
        size.height - _padB);

    final grid = Paint()..color = Colors.white12..strokeWidth = 1;
    const label = Colors.white60;

    // dB gridlines every 10.
    final step = (dbMax - dbMin) > 60 ? 20.0 : 10.0;
    for (var db = (dbMin / step).ceilToDouble() * step;
        db <= dbMax;
        db += step) {
      final y = _y(db, size);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _text(canvas, '${db.round()}', Offset(2, y - 6), label);
    }

    // Frequency gridlines on the decade marks an RTA is normally read against.
    const marks = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];
    for (final f in marks) {
      if (f < fMin || f > fMax) continue;
      final x = _x(f.toDouble(), size);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      _text(
        canvas,
        f >= 1000 ? '${f ~/ 1000}k' : '$f',
        Offset(x - 8, plot.bottom + 4),
        label,
      );
    }

    if (spectrum.isEmpty) return;

    canvas.save();
    canvas.clipRect(plot);

    // Bars span their band's actual width, so the display says what a band is
    // rather than implying a reading at a single frequency.
    final halfWidth = math.pow(2.0, 0.5 / bandsPerOctave).toDouble();
    final floor = _y(dbMin, size);

    for (var i = 0; i < spectrum.length; i++) {
      final f = spectrum.freqHz[i];
      if (f <= 0) continue;
      final v = spectrum.magDb[i];
      if (!v.isFinite || v <= dbMin) continue;

      final left = _x(f / halfWidth, size);
      final right = _x(f * halfWidth, size);
      // Leave a hairline gap so neighbouring bands stay countable, but never
      // let a bar vanish: at 1/48 octave they are barely a pixel wide.
      final gap = ((right - left) * 0.15).clamp(0.0, 1.5);
      final rect = Rect.fromLTRB(
        left + gap,
        _y(v, size),
        math.max(right - gap, left + gap + 0.8),
        floor,
      );
      canvas.drawRect(rect, Paint()..color = barColor.withValues(alpha: 0.85));
    }

    // Peak hold as a cap above each bar rather than a filled shape: it is a
    // record of a moment, not a level that is present now.
    final pk = peak;
    if (pk != null && pk.length == spectrum.length) {
      final capPaint = Paint()
        ..color = peakColor
        ..strokeWidth = 2;
      for (var i = 0; i < pk.length; i++) {
        final f = pk.freqHz[i];
        final v = pk.magDb[i];
        if (f <= 0 || !v.isFinite || v <= dbMin) continue;
        final left = _x(f / halfWidth, size);
        final right = _x(f * halfWidth, size);
        final y = _y(v, size);
        canvas.drawLine(Offset(left, y), Offset(math.max(right, left + 1), y),
            capPaint);
      }
    }

    canvas.restore();
    canvas.drawRect(
        plot, Paint()..color = Colors.white24..style = PaintingStyle.stroke);
  }

  void _text(Canvas canvas, String s, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _RtaBarPainter old) => true;
}
