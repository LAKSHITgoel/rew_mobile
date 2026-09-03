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

class DetailedFrChart extends StatefulWidget {
  const DetailedFrChart({
    super.key,
    required this.traces,
    required this.title,
    this.subtitle = '',
    this.fMin = 20,
    this.fMax = 20000,
    this.dbMin,
    this.dbMax,
    this.phaseMin = -180,
    this.phaseMax = 180,
  });

  final List<DetailedTrace> traces;
  final String title;
  final String subtitle;
  final double fMin, fMax, phaseMin, phaseMax;

  /// Null means "fit the data". A fixed window silently clips: with a -30 dB
  /// floor, a car measurement whose top end had collapsed drew as a flat line
  /// along the bottom of the chart, which reads as "the app stops at 10 kHz"
  /// rather than "there was nothing up there to measure".
  final double? dbMin, dbMax;

  @override
  State<DetailedFrChart> createState() => _DetailedFrChartState();

  /// The dB window to draw: the given bounds where set, otherwise the range of
  /// the data, rounded out to 10 dB and never narrower than 40 dB so that a
  /// nearly flat response is not magnified into drama.
  ({double lo, double hi}) dbRange() {
    if (dbMin != null && dbMax != null) {
      return (lo: dbMin!, hi: dbMax!);
    }
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final t in traces) {
      for (final v in t.response.magDb) {
        if (v.isNaN || v.isInfinite) continue;
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    if (lo > hi) return (lo: dbMin ?? -30, hi: dbMax ?? 18);
    lo = (lo / 10).floorToDouble() * 10 - 5;
    hi = (hi / 10).ceilToDouble() * 10 + 5;
    if (hi - lo < 40) hi = lo + 40;
    return (lo: dbMin ?? lo, hi: dbMax ?? hi);
  }
}

/// Holds the visible window so the chart can be zoomed and panned, the way REW
/// lets you go in on a single mode or a crossover region. Both axes zoom: pinch
/// horizontally for frequency, vertically for level, drag to pan, double-tap to
/// go back to the whole measurement.
class _DetailedFrChartState extends State<DetailedFrChart> {
  double? _fLo, _fHi, _dbLo, _dbHi;

  // Live gesture state; the window is recomputed from the values at gesture
  // start so a pinch does not compound with itself frame to frame.
  double _fLo0 = 0, _fHi0 = 0, _dbLo0 = 0, _dbHi0 = 0;

  double get fLo => _fLo ?? widget.fMin;
  double get fHi => _fHi ?? widget.fMax;
  double get dbLo => _dbLo ?? widget.dbRange().lo;
  double get dbHi => _dbHi ?? widget.dbRange().hi;

  bool get _zoomed =>
      _fLo != null || _fHi != null || _dbLo != null || _dbHi != null;

  // Limits: never zoom out past the full measurement, and stop zooming in at
  // about a sixth of an octave / 5 dB, which is finer than any real feature.
  static const _minDecades = 0.02;
  static const _minDb = 5.0;

  void _onScaleStart(ScaleStartDetails d) {
    _fLo0 = fLo;
    _fHi0 = fHi;
    _dbLo0 = dbLo;
    _dbHi0 = dbHi;
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final fullLo = widget.fMin, fullHi = widget.fMax;
    final fullDb = widget.dbRange();

    // Frequency is a log axis, so zoom and pan happen in log space.
    var logLo = math.log(_fLo0) / math.ln10;
    var logHi = math.log(_fHi0) / math.ln10;
    final fullLogLo = math.log(fullLo) / math.ln10;
    final fullLogHi = math.log(fullHi) / math.ln10;

    final hScale = d.horizontalScale <= 0 ? 1.0 : d.horizontalScale;
    final vScale = d.verticalScale <= 0 ? 1.0 : d.verticalScale;

    // Zoom about the point under the fingers, so what you aimed at stays put.
    final fx = (d.localFocalPoint.dx / size.width).clamp(0.0, 1.0);
    final fy = (d.localFocalPoint.dy / size.height).clamp(0.0, 1.0);
    final anchorLog = logLo + (logHi - logLo) * fx;
    var spanLog = (logHi - logLo) / hScale;
    spanLog = spanLog.clamp(_minDecades, fullLogHi - fullLogLo);
    logLo = anchorLog - spanLog * fx;
    logHi = logLo + spanLog;

    var lo = dbLo, hi = dbHi;
    final anchorDb = _dbHi0 - (_dbHi0 - _dbLo0) * fy;
    var spanDb = (_dbHi0 - _dbLo0) / vScale;
    spanDb = spanDb.clamp(_minDb, fullDb.hi - fullDb.lo);
    hi = anchorDb + spanDb * fy;
    lo = hi - spanDb;

    // Pan: drag moves the window against the finger.
    final dx = -d.focalPointDelta.dx / size.width * spanLog;
    final dy = d.focalPointDelta.dy / size.height * spanDb;
    logLo += dx;
    logHi += dx;
    lo += dy;
    hi += dy;

    // Keep the window inside the measurement.
    if (logLo < fullLogLo) {
      logHi += fullLogLo - logLo;
      logLo = fullLogLo;
    }
    if (logHi > fullLogHi) {
      logLo -= logHi - fullLogHi;
      logHi = fullLogHi;
    }
    if (lo < fullDb.lo) {
      hi += fullDb.lo - lo;
      lo = fullDb.lo;
    }
    if (hi > fullDb.hi) {
      lo -= hi - fullDb.hi;
      hi = fullDb.hi;
    }

    setState(() {
      _fLo = math.pow(10, logLo.clamp(fullLogLo, fullLogHi)).toDouble();
      _fHi = math.pow(10, logHi.clamp(fullLogLo, fullLogHi)).toDouble();
      _dbLo = lo.clamp(fullDb.lo, fullDb.hi);
      _dbHi = hi.clamp(fullDb.lo, fullDb.hi);
    });
  }

  void _reset() => setState(() {
        _fLo = _fHi = _dbLo = _dbHi = null;
      });

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(widget.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
              ),
              if (_zoomed)
                TextButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.zoom_out_map,
                      size: 16, color: Colors.white70),
                  label: const Text('Reset',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28)),
                ),
            ],
          ),
          if (widget.subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(widget.subtitle,
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ),
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio: 4 / 3,
            child: LayoutBuilder(builder: (context, box) {
              final size = Size(box.maxWidth, box.maxHeight);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: (d) => _onScaleUpdate(d, size),
                onDoubleTap: _reset,
                child: CustomPaint(
                  painter: _DetailedPainter(
                    traces: widget.traces,
                    fMin: fLo,
                    fMax: fHi,
                    dbMin: dbLo,
                    dbMax: dbHi,
                    phaseMin: widget.phaseMin,
                    phaseMax: widget.phaseMax,
                  ),
                  size: Size.infinite,
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 14, runSpacing: 4, children: [
            for (final t in widget.traces)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 16, height: 3, color: t.color),
                const SizedBox(width: 5),
                Text(t.label,
                    style: const TextStyle(color: Colors.white, fontSize: 11)),
              ]),
            for (final t in widget.traces.where((t) => t.showPhase))
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
    const wide = {20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000};
    // Zoomed in, the wide set can leave the axis with one label or none, so
    // fall back to labelling every gridline in view.
    var inView = 0;
    for (final f in wide) {
      if (f >= fMin && f <= fMax) inView++;
    }
    final labelAll = inView < 3;
    for (var decade = 1.0; decade <= 20000; decade *= 10) {
      for (var m = 1; m <= 9; m++) {
        final f = decade * m;
        if (f < fMin || f > fMax) continue;
        final x = _x(f, size);
        final isMajor = wide.contains(f.round());
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom),
            isMajor ? major : minor);
        if (isMajor || labelAll) {
          final t =
              f >= 1000 ? '${(f / 1000).toStringAsFixed(f % 1000 == 0 ? 0 : 1)}k' : '${f.round()}';
          _text(canvas, t, Offset(x - 10, plot.bottom + 4), 10, Colors.white70);
        }
      }
    }

    // Magnitude grid: step chosen for the window on screen, so zooming in gives
    // finer divisions instead of one line across the middle.
    final dbSpan = (dbMax - dbMin).abs();
    final step = dbSpan > 120
        ? 20.0
        : dbSpan > 60
            ? 10.0
            : dbSpan > 25
                ? 5.0
                : dbSpan > 12
                    ? 2.0
                    : 1.0;
    final firstLine = (dbMin / step).ceilToDouble() * step;
    for (var db = firstLine; db <= dbMax + 0.001; db += step) {
      final y = _yDb(db, size);
      final labelHere = (db / (step * 2)).abs() % 1 < 0.001;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y),
          db.abs() < 0.001 ? zero : (labelHere ? major : minor));
      if (labelHere) {
        final t = step < 1 ? db.toStringAsFixed(1) : db.round().toString();
        _text(canvas, t, Offset(4, y - 6), 10, Colors.white70);
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
