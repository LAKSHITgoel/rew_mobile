// A log-frequency magnitude chart drawn with a CustomPainter (no chart package
// dependency). Overlays one or more labelled curves — e.g. measured vs target, or
// before vs after — on a dB grid.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/measurement.dart';

class FrCurve {
  const FrCurve(this.response, this.color, this.label);
  final FreqResponse response;
  final Color color;
  final String label;
}

class FrChart extends StatelessWidget {
  const FrChart({
    super.key,
    required this.curves,
    this.fMin = 20,
    this.fMax = 20000,
    this.dbMin = -24,
    this.dbMax = 24,
    this.height = 240,
  });

  final List<FrCurve> curves;
  final double fMin, fMax, dbMin, dbMax, height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _FrPainter(
              curves: curves,
              fMin: fMin,
              fMax: fMax,
              dbMin: dbMin,
              dbMax: dbMax,
              gridColor: theme.dividerColor,
              textColor: theme.textTheme.bodySmall?.color ?? Colors.grey,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          children: [
            for (final c in curves)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 14, height: 3, color: c.color),
                const SizedBox(width: 6),
                Text(c.label, style: theme.textTheme.bodySmall),
              ]),
          ],
        ),
      ],
    );
  }
}

class _FrPainter extends CustomPainter {
  _FrPainter({
    required this.curves,
    required this.fMin,
    required this.fMax,
    required this.dbMin,
    required this.dbMax,
    required this.gridColor,
    required this.textColor,
  });

  final List<FrCurve> curves;
  final double fMin, fMax, dbMin, dbMax;
  final Color gridColor, textColor;

  static const _padL = 36.0;
  static const _padB = 20.0;
  static const _padT = 8.0;
  static const _padR = 8.0;

  double _x(double f, Size s) {
    final lx = (math.log(f) - math.log(fMin)) / (math.log(fMax) - math.log(fMin));
    return _padL + lx * (s.width - _padL - _padR);
  }

  double _y(double db, Size s) {
    final ny = (db - dbMin) / (dbMax - dbMin);
    return (_padT) + (1 - ny) * (s.height - _padT - _padB);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    // Vertical decade/octave gridlines at standard frequencies.
    const freqs = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];
    for (final f in freqs) {
      if (f < fMin || f > fMax) continue;
      final x = _x(f.toDouble(), size);
      canvas.drawLine(Offset(x, _padT), Offset(x, size.height - _padB), grid);
      final label = f >= 1000 ? '${f ~/ 1000}k' : '$f';
      _text(canvas, label, Offset(x - 8, size.height - _padB + 4), 9);
    }

    // Horizontal dB gridlines every 6 dB, 0 dB emphasized.
    for (var db = dbMin; db <= dbMax; db += 6) {
      final y = _y(db, size);
      final p = Paint()
        ..color = db == 0 ? textColor.withAlpha(128) : gridColor
        ..strokeWidth = db == 0 ? 1.2 : 0.6;
      canvas.drawLine(Offset(_padL, y), Offset(size.width - _padR, y), p);
      _text(canvas, '${db.toInt()}', Offset(2, y - 6), 9);
    }

    // Curves.
    for (final c in curves) {
      final paint = Paint()
        ..color = c.color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      var started = false;
      for (var i = 0; i < c.response.length; i++) {
        final f = c.response.freqHz[i];
        if (f < fMin || f > fMax) continue;
        final x = _x(f, size);
        final y = _y(c.response.magDb[i].clamp(dbMin, dbMax), size);
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  void _text(Canvas canvas, String s, Offset at, double size) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: textColor, fontSize: size)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _FrPainter old) =>
      old.curves != curves || old.dbMin != dbMin || old.dbMax != dbMax;
}
