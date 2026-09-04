// Charts with TIME on the horizontal axis.
//
// Everything else the app draws is a frequency response, where the x axis is
// logarithmic and spans ten octaves. These are the opposite: linear
// milliseconds, over a window short enough that individual arrivals are
// separate things you can point at. They needed their own painters rather than
// a mode on the frequency chart, because almost nothing carries over — not the
// gridlines, not the axis, not what a peak means.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A single trace against time.
class TimeTrace {
  const TimeTrace(this.values, this.color, this.label);
  final List<double> values;
  final Color color;
  final String label;
}

/// Impulse, step and energy-time curves — anything sampled uniformly in time.
class TimeChart extends StatelessWidget {
  const TimeChart({
    super.key,
    required this.timeMs,
    required this.traces,
    required this.title,
    this.subtitle = '',
    this.height = 220,
    this.yMin,
    this.yMax,
    this.zeroLine = true,
    this.markerMs,
  });

  final List<double> timeMs;
  final List<TimeTrace> traces;
  final String title;
  final String subtitle;
  final double height;

  /// Fixed vertical range. Left null the chart fits the data, which is right
  /// for an impulse (its scale is arbitrary) and wrong for an energy-time curve
  /// (where 0 dB means something).
  final double? yMin, yMax;

  final bool zeroLine;

  /// A vertical line at a moment worth pointing at — the arrival, usually.
  final double? markerMs;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        if (subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9AA3AC))),
          ),
        const SizedBox(height: 6),
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _TimePainter(
              timeMs: timeMs,
              traces: traces,
              yMin: yMin,
              yMax: yMax,
              zeroLine: zeroLine,
              markerMs: markerMs,
            ),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 14,
          children: [
            for (final t in traces)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 14, height: 3, color: t.color),
                const SizedBox(width: 5),
                Text(t.label, style: const TextStyle(fontSize: 11)),
              ]),
          ],
        ),
      ],
    );
  }
}

class _TimePainter extends CustomPainter {
  _TimePainter({
    required this.timeMs,
    required this.traces,
    required this.yMin,
    required this.yMax,
    required this.zeroLine,
    required this.markerMs,
  });

  final List<double> timeMs;
  final List<TimeTrace> traces;
  final double? yMin, yMax;
  final bool zeroLine;
  final double? markerMs;

  static const _bg = Color(0xFF14171B);
  static const _grid = Color(0xFF2A2F36);
  static const _axisText = Color(0xFF8B949E);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);
    if (timeMs.isEmpty || traces.isEmpty) return;

    const left = 42.0, bottom = 22.0, top = 8.0, right = 8.0;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    if (plot.width <= 4 || plot.height <= 4) return;

    var lo = yMin ?? double.infinity;
    var hi = yMax ?? double.negativeInfinity;
    if (yMin == null || yMax == null) {
      for (final t in traces) {
        for (final v in t.values) {
          if (!v.isFinite) continue;
          if (yMin == null && v < lo) lo = v;
          if (yMax == null && v > hi) hi = v;
        }
      }
      if (lo > hi) {
        lo = -1;
        hi = 1;
      }
      // A little air, and never a degenerate range.
      final pad = math.max((hi - lo) * 0.08, 1e-6);
      if (yMin == null) lo -= pad;
      if (yMax == null) hi += pad;
    }

    final t0 = timeMs.first, t1 = timeMs.last;
    double xOf(double ms) =>
        plot.left + (t1 - t0 <= 0 ? 0 : (ms - t0) / (t1 - t0)) * plot.width;
    double yOf(double v) =>
        plot.bottom - ((v - lo) / (hi - lo)).clamp(0.0, 1.0) * plot.height;

    final gridPaint = Paint()
      ..color = _grid
      ..strokeWidth = 1;

    // Horizontal gridlines with labels: five is enough to read a value off
    // without turning the plot into graph paper.
    for (var i = 0; i <= 4; i++) {
      final v = lo + (hi - lo) * i / 4;
      final y = yOf(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _label(canvas, _fmt(v), Offset(4, y - 6), _axisText);
    }

    // Vertical gridlines on round milliseconds.
    final span = t1 - t0;
    final stepMs = span <= 20
        ? 5.0
        : span <= 60
            ? 10.0
            : span <= 200
                ? 25.0
                : span <= 600
                    ? 100.0
                    : 250.0;
    for (var ms = (t0 / stepMs).ceil() * stepMs; ms <= t1; ms += stepMs) {
      final x = xOf(ms);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
      _label(canvas, '${ms.toStringAsFixed(0)} ms',
          Offset(x - 16, plot.bottom + 4), _axisText);
    }

    if (zeroLine && lo < 0 && hi > 0) {
      canvas.drawLine(
        Offset(plot.left, yOf(0)),
        Offset(plot.right, yOf(0)),
        Paint()
          ..color = const Color(0xFF444C55)
          ..strokeWidth = 1,
      );
    }

    // The arrival. Drawn dashed so it is plainly an annotation rather than
    // something that was measured.
    final marker = markerMs;
    if (marker != null && marker >= t0 && marker <= t1) {
      final x = xOf(marker);
      final p = Paint()
        ..color = const Color(0xFF6E7681)
        ..strokeWidth = 1;
      for (var y = plot.top; y < plot.bottom; y += 6) {
        canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 3, plot.bottom)), p);
      }
    }

    canvas.save();
    canvas.clipRect(plot);
    for (final t in traces) {
      final path = Path();
      var started = false;
      final n = math.min(t.values.length, timeMs.length);
      // One point per pixel at most: an impulse response is tens of thousands
      // of samples and a path with all of them is slow and no more legible.
      final stride = math.max(1, (n / (plot.width * 2)).floor());
      for (var i = 0; i < n; i += stride) {
        final v = t.values[i];
        if (!v.isFinite) continue;
        final p = Offset(xOf(timeMs[i]), yOf(v));
        if (!started) {
          path.moveTo(p.dx, p.dy);
          started = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = t.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }
    canvas.restore();

    canvas.drawRect(
      plot,
      Paint()
        ..color = _grid
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  String _fmt(double v) {
    if (v.abs() >= 100) return v.toStringAsFixed(0);
    if (v.abs() >= 10) return v.toStringAsFixed(1);
    return v.toStringAsFixed(2);
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 9)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _TimePainter old) =>
      old.traces != traces || old.timeMs != timeMs;
}

/// The waterfall, drawn as stacked slices rather than as a heat map.
///
/// A heat map is prettier and much harder to read: colour is a poor encoding
/// for a quantity, and the question here — "is one frequency still there after
/// the rest has gone?" — is answered instantly by stacked outlines and only
/// eventually by shades of orange. Later slices are drawn behind earlier ones
/// and offset, which is the shape REW uses for the same reason.
class WaterfallChart extends StatelessWidget {
  const WaterfallChart({
    super.key,
    required this.freqHz,
    required this.timeMs,
    required this.slices,
    this.height = 280,
    this.floorDb = -40,
  });

  final List<double> freqHz;
  final List<double> timeMs;
  final List<List<double>> slices;
  final double height;

  /// How far down to draw. Below this is noise in any car measurement, and
  /// including it just makes the plot taller without adding anything.
  final double floorDb;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _WaterfallPainter(
          freqHz: freqHz,
          timeMs: timeMs,
          slices: slices,
          floorDb: floorDb,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _WaterfallPainter extends CustomPainter {
  _WaterfallPainter({
    required this.freqHz,
    required this.timeMs,
    required this.slices,
    required this.floorDb,
  });

  final List<double> freqHz;
  final List<double> timeMs;
  final List<List<double>> slices;
  final double floorDb;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF14171B));
    if (slices.isEmpty || freqHz.isEmpty) return;

    const left = 34.0, bottom = 20.0, top = 10.0, right = 10.0;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    if (plot.width <= 4 || plot.height <= 4) return;

    // Each successive slice is pushed up and to the right, which is what gives
    // the plot its depth and keeps the earlier ones from being hidden.
    final depth = math.min(plot.height * 0.35, 90.0);
    final shiftX = plot.width * 0.10;
    final usableH = plot.height - depth;

    final logLo = math.log(freqHz.first);
    final logHi = math.log(freqHz.last);

    // Frequency gridlines and labels, on the front slice's axis.
    final gridPaint = Paint()
      ..color = const Color(0xFF2A2F36)
      ..strokeWidth = 1;
    for (final f in const [20.0, 31.5, 50.0, 80.0, 125.0, 200.0, 315.0, 500.0]) {
      if (f < freqHz.first || f > freqHz.last) continue;
      final x = plot.left +
          (math.log(f) - logLo) / (logHi - logLo) * (plot.width - shiftX);
      canvas.drawLine(Offset(x, plot.top + depth), Offset(x, plot.bottom), gridPaint);
      final tp = TextPainter(
        text: TextSpan(
            text: f >= 1000 ? '${(f / 1000).toStringAsFixed(1)}k' : '${f.round()}',
            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, plot.bottom + 4));
    }

    // Back to front, so nearer slices overlap the ones behind them.
    for (var s = slices.length - 1; s >= 0; s--) {
      final frac = slices.length <= 1 ? 0.0 : s / (slices.length - 1);
      final baseY = plot.bottom - frac * depth;
      final baseX = plot.left + frac * shiftX;
      final width = plot.width - shiftX;

      final path = Path();
      final fill = Path();
      for (var i = 0; i < freqHz.length && i < slices[s].length; i++) {
        final x = baseX + (math.log(freqHz[i]) - logLo) / (logHi - logLo) * width;
        final norm = ((slices[s][i] - floorDb) / -floorDb).clamp(0.0, 1.0);
        final y = baseY - norm * usableH;
        if (i == 0) {
          path.moveTo(x, y);
          fill.moveTo(x, baseY);
          fill.lineTo(x, y);
        } else {
          path.lineTo(x, y);
          fill.lineTo(x, y);
        }
      }
      fill
        ..lineTo(baseX + width, baseY)
        ..close();

      // Opaque fill in the background colour, so a slice hides what is behind
      // it instead of turning the plot into a tangle of overlapping lines.
      canvas.drawPath(fill, Paint()..color = const Color(0xFF14171B));
      // Newer slices brighter: time reads as fading away.
      final t = 1.0 - frac;
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.lerp(const Color(0xFF3E5A6E), const Color(0xFF6FC2FF), t)!
          ..style = PaintingStyle.stroke
          ..strokeWidth = frac == 0 ? 1.6 : 1.0,
      );
    }

    // Time labels down the left, on the slices that carry them.
    for (var s = 0; s < slices.length; s++) {
      if (s % math.max(1, slices.length ~/ 4) != 0) continue;
      final frac = slices.length <= 1 ? 0.0 : s / (slices.length - 1);
      final y = plot.bottom - frac * depth;
      final tp = TextPainter(
        text: TextSpan(
            text: '${timeMs[s].round()}',
            style: const TextStyle(color: Color(0xFF8B949E), fontSize: 9)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, y - 5));
    }
  }

  @override
  bool shouldRepaint(covariant _WaterfallPainter old) => old.slices != slices;
}
