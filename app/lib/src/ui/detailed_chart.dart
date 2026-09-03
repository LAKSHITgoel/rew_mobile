// A detailed, REW-style measurement chart: log-frequency axis with decade and
// 1-2-3-5 minor ticks, magnitude on the left axis, unwrapped phase on the right,
// and enough labelling that a screenshot of it stands on its own when handed to
// someone else (or to an LLM) for a second opinion.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/measurement.dart';

class DetailedTrace {
  const DetailedTrace(this.response, this.color, this.label,
      {this.showPhase = false});
  final FreqResponse response;
  final Color color;
  final String label;
  final bool showPhase;
}

class DetailedFrChart extends StatelessWidget {
  const DetailedFrChart({
    super.key,
    required this.traces,
    required this.title,
    this.subtitle = '',
    this.fMin = 20,
    this.fMax = 20000,
    this.dbMin = -30,
    this.dbMax = 18,
    this.phaseMin = -180,
    this.phaseMax = 180,
  });

  final List<DetailedTrace> traces;
  final String title;
  final String subtitle;
  final double fMin, fMax, dbMin, dbMax, phaseMin, phaseMax;

  @override
  Widget build(BuildContext context) {
    // Fixed dark palette rather than the app theme: an exported image should
    // look the same whoever opens it.
    return Container(
      color: const Color(0xFF101215),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(subtitle,
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ),
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio: 4 / 3,
            child: CustomPaint(
              painter: _DetailedPainter(
                traces: traces,
                fMin: fMin,
                fMax: fMax,
                dbMin: dbMin,
                dbMax: dbMax,
                phaseMin: phaseMin,
                phaseMax: phaseMax,
              ),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 14, runSpacing: 4, children: [
            for (final t in traces)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 16, height: 3, color: t.color),
                const SizedBox(width: 5),
                Text(t.label,
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ]),
            for (final t in traces.where((t) => t.showPhase))
              Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 16,
                  height: 3,
                  child: CustomPaint(painter: _DashLegend(t.color)),
                ),
                const SizedBox(width: 5),
                Text('${t.label} phase',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 11)),
              ]),
          ]),
        ],
      ),
    );
  }
}

class _DashLegend extends CustomPainter {
  _DashLegend(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 3;
    for (double x = 0; x < size.width; x += 6) {
      canvas.drawLine(Offset(x, size.height / 2),
          Offset(math.min(x + 3, size.width), size.height / 2), p);
    }
  }

  @override
  bool shouldRepaint(covariant _DashLegend old) => old.color != color;
}

class _DetailedPainter extends CustomPainter {
  _DetailedPainter({
    required this.traces,
    required this.fMin,
    required this.fMax,
    required this.dbMin,
    required this.dbMax,
    required this.phaseMin,
    required this.phaseMax,
  });

  final List<DetailedTrace> traces;
  final double fMin, fMax, dbMin, dbMax, phaseMin, phaseMax;

  static const _padL = 44.0;
  static const _padR = 44.0;
  static const _padT = 10.0;
  static const _padB = 30.0;

  double _x(double f, Size s) =>
      _padL +
      (math.log(f) - math.log(fMin)) /
          (math.log(fMax) - math.log(fMin)) *
          (s.width - _padL - _padR);

  double _yDb(double db, Size s) =>
      _padT + (1 - (db - dbMin) / (dbMax - dbMin)) * (s.height - _padT - _padB);

  double _yPhase(double deg, Size s) =>
      _padT +
      (1 - (deg - phaseMin) / (phaseMax - phaseMin)) *
          (s.height - _padT - _padB);

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(
        _padL, _padT, size.width - _padR, size.height - _padB);
    canvas.drawRect(plot, Paint()..color = const Color(0xFF15181C));

    final minor = Paint()
      ..color = Colors.white.withAlpha(20)
      ..strokeWidth = 0.6;
    final major = Paint()
      ..color = Colors.white.withAlpha(56)
      ..strokeWidth = 1.0;
    final zero = Paint()
      ..color = Colors.white.withAlpha(115)
      ..strokeWidth = 1.2;

    // Frequency grid: a line at every 1-2-3-4-5-6-7-8-9 in each decade, labels
    // only on the ones REW labels, so the scale is readable but not cluttered.
    const labelled = {20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000};
    for (var decade = 10.0; decade <= 20000; decade *= 10) {
      for (var m = 1; m <= 9; m++) {
        final f = decade * m;
        if (f < fMin || f > fMax) continue;
        final x = _x(f, size);
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom),
            labelled.contains(f.round()) ? major : minor);
        if (labelled.contains(f.round())) {
          final t = f >= 1000 ? '${(f / 1000).toStringAsFixed(0)}k' : '${f.round()}';
          _text(canvas, t, Offset(x - 10, plot.bottom + 4), 10, Colors.white70);
        }
      }
    }

    // Magnitude grid every 5 dB, labelled every 10.
    for (var db = dbMin; db <= dbMax + 0.001; db += 5) {
      final y = _yDb(db, size);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y),
          db.abs() < 0.001 ? zero : (db % 10 == 0 ? major : minor));
      if (db % 10 == 0) {
        _text(canvas, '${db.toInt()}', Offset(4, y - 6), 10, Colors.white70);
      }
    }

    // Phase grid on the right, every 90 degrees.
    final anyPhase = traces.any((t) => t.showPhase && t.response.hasPhase);
    if (anyPhase) {
      for (var d = phaseMin; d <= phaseMax + 0.001; d += 90) {
        final y = _yPhase(d, size);
        _text(canvas, '${d.toInt()}°', Offset(plot.right + 5, y - 6), 10,
            Colors.white38);
      }
      _text(canvas, 'phase', Offset(plot.right + 5, plot.top - 2), 9,
          Colors.white38);
    }
    _text(canvas, 'dB', Offset(4, plot.top - 2), 9, Colors.white38);
    _text(canvas, 'Hz', Offset(plot.right - 14, plot.bottom + 16), 9,
        Colors.white38);

    canvas.save();
    canvas.clipRect(plot);

    for (final t in traces) {
      // Phase first, so magnitude sits on top.
      if (t.showPhase && t.response.hasPhase) {
        _dashedPath(canvas, _buildPath(t.response.freqHz, t.response.phaseDeg,
            size, (v, s) => _yPhase(v.clamp(phaseMin, phaseMax), s)),
            t.color.withAlpha(140));
      }
      canvas.drawPath(
        _buildPath(t.response.freqHz, t.response.magDb, size,
            (v, s) => _yDb(v.clamp(dbMin, dbMax), s)),
        Paint()
          ..color = t.color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.restore();
    canvas.drawRect(plot, Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke);
  }

  Path _buildPath(List<double> xs, List<double> ys, Size size,
      double Function(double, Size) toY) {
    final path = Path();
    var started = false;
    for (var i = 0; i < xs.length && i < ys.length; i++) {
      final f = xs[i];
      if (f < fMin || f > fMax) continue;
      final p = Offset(_x(f, size), toY(ys[i], size));
      if (!started) {
        path.moveTo(p.dx, p.dy);
        started = true;
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path;
  }

  void _dashedPath(Canvas canvas, Path path, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final next = math.min(d + 5, metric.length);
        canvas.drawPath(metric.extractPath(d, next), paint);
        d = next + 4;
      }
    }
  }

  void _text(Canvas canvas, String s, Offset at, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _DetailedPainter old) => true;
}
