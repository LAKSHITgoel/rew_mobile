// A detailed, REW-style measurement chart: log-frequency axis with decade and
// 1-2-3-5 minor ticks, magnitude on the left axis, unwrapped phase on the right,
// and enough labelling that a screenshot of it stands on its own when handed to
// someone else (or to an LLM) for a second opinion.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/measurement.dart';

class DetailedTrace {
  const DetailedTrace(this.response, this.color, this.label,
      {this.showPhase = false, this.dashed = false});
  final FreqResponse response;
  final Color color;
  final String label;
  final bool showPhase;

  /// Drawn as a dashed line. Used for a target: it is not something that was
  /// measured, and it should not look like it was.
  final bool dashed;
}

/// A named frequency range worth jumping to. Reading a car measurement means
/// looking at a few specific regions — where the sub hands over, where the
/// windscreen reflection sits, where sibilance lives — and hunting for them by
/// pinching every time is tedious.
class ChartRange {
  const ChartRange(this.label, this.fLo, this.fHi, this.why);
  final String label;
  final double fLo;
  final double fHi;
  final String why;

  static const all = <ChartRange>[
    ChartRange('Full', 20, 20000, 'The whole measured range.'),
    ChartRange('Bass', 20, 200, 'Room modes and the sub crossover.'),
    ChartRange('Mid-bass', 60, 500, 'Where the sub hands over to the doors.'),
    ChartRange('Midrange', 200, 4000, 'Voices and the body of most music.'),
    ChartRange('Presence', 1000, 8000, 'Sibilance, detail and listening fatigue.'),
    ChartRange('Treble', 4000, 20000, 'Air, and where a wireless link gives out.'),
  ];
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
    this.fill = false,
    this.onSmoothing,
    this.smoothFrac = 24,
  });

  /// Take all the room available instead of a 4:3 box. Used by the fullscreen
  /// view, where the plot is the whole point of the screen.
  final bool fill;

  /// Called when the smoothing control changes, so the screen that owns the
  /// traces can re-smooth them. The chart does not do it itself: smoothing is
  /// measurement maths and belongs in core, not in a painter.
  final void Function(double fractionOfOctave)? onSmoothing;

  /// Current smoothing, for showing in the control.
  final double smoothFrac;

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
/// horizontally for frequency, vertically for level, drag to pan, and Reset
/// returns to the whole measurement.
///
/// There is deliberately no double-tap-to-fit: a double-tap recognizer and a
/// scale recognizer in the same detector compete in the gesture arena, the
/// scale one wins, and the double tap silently never fires. Rather than ship a
/// gesture that does nothing, the Reset button is the way back.
class _DetailedFrChartState extends State<DetailedFrChart> {
  double? _fLo, _fHi, _dbLo, _dbHi;

  /// Frequency under the cursor, or null when it is not placed. A graph you can
  /// only look at is half a tool: the question is almost always "how much, and
  /// exactly where", and reading that off gridlines is guesswork.
  double? _cursorHz;

  /// One finger reads, two fingers move.
  ///
  /// On a desktop the cursor follows the pointer and dragging pans, but a touch
  /// screen has no hover, so the two have to be told apart by how many fingers
  /// are down. Reading a value is the thing done constantly while tuning, so it
  /// gets the single finger; panning and zooming get the pinch they already
  /// needed anyway.

  /// Traces hidden by tapping their legend entry.
  final Set<String> _hidden = {};

  /// Label the largest peaks and dips. Finding the worst offender by eye means
  /// scanning a jagged curve and guessing; the numbers are already there, so
  /// the chart may as well point at them.
  bool _markers = false;

  /// The biggest departures from the local trend in the first visible trace.
  /// Deliberately measured against a smoothed version of the curve rather than
  /// against a flat line: on a response that tilts, every point at one end
  /// would otherwise count as a peak.
  List<({double hz, double db, bool isPeak})> _extremes() {
    if (!_markers) return const [];
    final visible = _visible;
    if (visible.isEmpty) return const [];
    final fr = visible.first.response;
    if (fr.length < 12) return const [];

    // Local trend: a wide moving average in log space.
    final trend = List<double>.filled(fr.length, 0);
    const half = 12;
    for (var i = 0; i < fr.length; i++) {
      var sum = 0.0;
      var n = 0;
      for (var j = i - half; j <= i + half; j++) {
        if (j < 0 || j >= fr.length) continue;
        sum += fr.magDb[j];
        n++;
      }
      trend[i] = sum / n;
    }

    final out = <({double hz, double db, bool isPeak})>[];
    for (var i = 2; i < fr.length - 2; i++) {
      final f = fr.freqHz[i];
      if (f < fLo || f > fHi) continue;
      final dev = fr.magDb[i] - trend[i];
      if (dev.abs() < 3) continue;
      final isPeak = dev > 0;
      // Only genuine turning points, or a broad hump would be labelled at
      // every one of its points.
      final a = fr.magDb[i - 1], b = fr.magDb[i], c = fr.magDb[i + 1];
      if (isPeak && !(b >= a && b >= c)) continue;
      if (!isPeak && !(b <= a && b <= c)) continue;
      out.add((hz: f, db: fr.magDb[i], isPeak: isPeak));
    }

    // Keep the biggest few, spaced apart, so the chart does not fill with text.
    out.sort((x, y) => (y.db.abs()).compareTo(x.db.abs()));
    final kept = <({double hz, double db, bool isPeak})>[];
    for (final e in out) {
      if (kept.length >= 6) break;
      if (kept.any((k) => (math.log(k.hz / e.hz)).abs() < 0.35)) continue;
      kept.add(e);
    }
    return kept;
  }

  // Live gesture state; the window is recomputed from the values at gesture
  // start so a pinch does not compound with itself frame to frame.
  double _fLo0 = 0, _fHi0 = 0, _dbLo0 = 0, _dbHi0 = 0;

  double get fLo => _fLo ?? widget.fMin;
  double get fHi => _fHi ?? widget.fMax;
  double get dbLo => _dbLo ?? widget.dbRange().lo;
  double get dbHi => _dbHi ?? widget.dbRange().hi;

  bool get _zoomed =>
      _fLo != null || _fHi != null || _dbLo != null || _dbHi != null;

  List<DetailedTrace> get _visible =>
      [for (final t in widget.traces) if (!_hidden.contains(t.label)) t];

  /// Value of each visible trace at the cursor, for the readout.
  List<({DetailedTrace trace, double db})> _readout() {
    final hz = _cursorHz;
    if (hz == null) return const [];
    final out = <({DetailedTrace trace, double db})>[];
    for (final t in _visible) {
      final fr = t.response;
      if (fr.isEmpty) continue;
      // Nearest point rather than interpolating: on a log grid at this density
      // the difference is invisible, and showing a value that is not in the
      // data would be worse than showing one that is.
      var best = 0;
      var err = double.infinity;
      for (var i = 0; i < fr.length; i++) {
        final e = (math.log(fr.freqHz[i] / hz)).abs();
        if (e < err) {
          err = e;
          best = i;
        }
      }
      out.add((trace: t, db: fr.magDb[best]));
    }
    return out;
  }

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
    // Two fingers means move the view; one means read a value. The scale check
    // is a belt-and-braces second signal: a real pinch always changes it, and
    // relying on the pointer count alone would silently turn zooming off
    // anywhere the count is reported low.
    final movingView =
        d.pointerCount >= 2 || (d.scale - 1).abs() > 0.01;
    if (!movingView) {
      _setCursorFrom(d.localFocalPoint, size);
      return;
    }
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

  /// Map an x position to a frequency, matching the painter's plot area.
  void _setCursorFrom(Offset local, Size size) {
    const padL = 44.0, padR = 44.0;
    final w = size.width - padL - padR;
    if (w <= 0) return;
    final t = ((local.dx - padL) / w).clamp(0.0, 1.0);
    final logLo = math.log(fLo), logHi = math.log(fHi);
    setState(() => _cursorHz = math.exp(logLo + t * (logHi - logLo)));
  }

  void _reset() {
    setState(() {
      _fLo = _fHi = _dbLo = _dbHi = null;
      _cursorHz = null;
    });
    // The boxes describe the view, so they follow it however it was changed.
    _syncLimitFields();
  }

  /// Type the range in. The presets cover the regions worth naming; this is
  /// for the times you want exactly 45 to 65 Hz because that is where the mode
  /// is, and no preset is going to guess that.
  Future<void> _askRange() async {
    final lo = TextEditingController(text: fLo.round().toString());
    final hi = TextEditingController(text: fHi.round().toString());
    final result = await showDialog<({double lo, double hi})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Frequency range'),
        content: Row(children: [
          Expanded(
            child: TextField(
              controller: lo,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'From (Hz)'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: hi,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'To (Hz)'),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final a = double.tryParse(lo.text);
              final b = double.tryParse(hi.text);
              if (a == null || b == null || a <= 0 || b <= a) {
                Navigator.pop(ctx);
                return;
              }
              Navigator.pop(ctx, (lo: a, hi: b));
            },
            child: const Text('Show'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      // Clamped to what was measured: a range outside it would draw an empty
      // chart and look like a broken measurement.
      _fLo = result.lo.clamp(widget.fMin, widget.fMax);
      _fHi = result.hi.clamp(widget.fMin, widget.fMax);
      final hz = _cursorHz;
      if (hz != null && (hz < _fLo! || hz > _fHi!)) _cursorHz = null;
    });
  }

  /// REW keeps the limits and smoothing beside the graph rather than behind a
  /// menu, because they are adjusted constantly while reading a measurement —
  /// set the window, look, set it again.
  bool _controlsOpen = true;

  final _topCtl = TextEditingController();
  final _bottomCtl = TextEditingController();
  final _leftCtl = TextEditingController();
  final _rightCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Straight away rather than after a frame: the limits follow from the
    // traces the moment the widget exists, and boxes that start empty read as
    // "type something" instead of "this is the window you are looking at".
    _syncLimitFields();
  }

  @override
  void dispose() {
    _topCtl.dispose();
    _bottomCtl.dispose();
    _leftCtl.dispose();
    _rightCtl.dispose();
    super.dispose();
  }

  void _syncLimitFields() {
    _topCtl.text = dbHi.round().toString();
    _bottomCtl.text = dbLo.round().toString();
    _leftCtl.text = fLo.round().toString();
    _rightCtl.text = fHi.round().toString();
  }

  void _applyLimits() {
    final top = double.tryParse(_topCtl.text);
    final bottom = double.tryParse(_bottomCtl.text);
    final left = double.tryParse(_leftCtl.text);
    final right = double.tryParse(_rightCtl.text);
    setState(() {
      if (top != null && bottom != null && top > bottom) {
        _dbHi = top;
        _dbLo = bottom;
      }
      if (left != null && right != null && right > left && left > 0) {
        _fLo = left.clamp(widget.fMin, widget.fMax);
        _fHi = right.clamp(widget.fMin, widget.fMax);
      }
      final hz = _cursorHz;
      if (hz != null && (hz < fLo || hz > fHi)) _cursorHz = null;
    });
    _syncLimitFields();
  }

  Widget _controlsPanel() {
    return Container(
      width: 168,
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF161A1F),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Expanded(
                child: Text('Limits',
                    style: TextStyle(
                        color: Colors.white, fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ),
              GestureDetector(
                onTap: () => setState(() => _controlsOpen = false),
                child: const Icon(Icons.chevron_right,
                    size: 18, color: Colors.white54),
              ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: _limitField(_topCtl, 'Top dB')),
              const SizedBox(width: 6),
              Expanded(child: _limitField(_bottomCtl, 'Bottom')),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: _limitField(_leftCtl, 'Left Hz')),
              const SizedBox(width: 6),
              Expanded(child: _limitField(_rightCtl, 'Right Hz')),
            ]),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _applyLimits,
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    foregroundColor: Colors.white70),
                child: const Text('Apply', style: TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () {
                  _reset();
                  _syncLimitFields();
                },
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero, foregroundColor: Colors.white54),
                child: const Text('Fit to data', style: TextStyle(fontSize: 12)),
              ),
            ),
            if (widget.onSmoothing != null) ...[
              const Divider(height: 20, color: Colors.white12),
              const Text('Smoothing',
                  style: TextStyle(
                      color: Colors.white, fontSize: 12,
                      fontWeight: FontWeight.bold)),
              DropdownButton<double>(
                value: widget.smoothFrac,
                isExpanded: true,
                dropdownColor: const Color(0xFF1B1F24),
                style: const TextStyle(color: Colors.white, fontSize: 12),
                items: const [
                  DropdownMenuItem(value: 48.0, child: Text('1/48 octave')),
                  DropdownMenuItem(value: 24.0, child: Text('1/24 octave')),
                  DropdownMenuItem(value: 12.0, child: Text('1/12 octave')),
                  DropdownMenuItem(value: 6.0, child: Text('1/6 octave')),
                  DropdownMenuItem(value: 3.0, child: Text('1/3 octave')),
                  DropdownMenuItem(value: 1.0, child: Text('1 octave')),
                ],
                onChanged: (v) {
                  if (v != null) widget.onSmoothing!(v);
                },
              ),
              const Text(
                'Only coarsens — detail averaged away when the measurement was '
                'taken cannot come back.',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _limitField(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(signed: true),
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54, fontSize: 10),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _applyLimits(),
      );

  Widget _plot() {
    final chart = LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (d) {
          _onScaleStart(d);
          // Touching anywhere reads that frequency straight away, rather than
          // needing a drag to wake the cursor up.
          if (d.pointerCount < 2) _setCursorFrom(d.localFocalPoint, size);
        },
        onScaleUpdate: (d) => _onScaleUpdate(d, size),
        child: CustomPaint(
          painter: _DetailedPainter(
            traces: _visible,
            fMin: fLo,
            fMax: fHi,
            dbMin: dbLo,
            dbMax: dbHi,
            phaseMin: widget.phaseMin,
            phaseMax: widget.phaseMax,
            cursorHz: _cursorHz,
            markers: _extremes(),
            // With the whole screen there is room to label properly; boxed
            // into a portrait page there is not, and crowded ticks are worse
            // than fewer of them.
            dense: widget.fill,
          ),
          size: Size.infinite,
        ),
      );
    });
    return widget.fill ? chart : AspectRatio(aspectRatio: 4 / 3, child: chart);
  }

  Widget _chip(
      {required String label,
      required bool selected,
      required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2A4A70) : const Color(0xFF1B1F24),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected ? const Color(0xFF7FB2E5) : Colors.white24),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? Colors.white : Colors.white70, fontSize: 11)),
      ),
    );
  }

  Widget _readoutPanel() {
    final hz = _cursorHz!;
    final values = _readout();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF161A1F),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(children: [
          Text(
            hz >= 1000
                ? '${(hz / 1000).toStringAsFixed(2)} kHz'
                : '${hz.round()} Hz',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFeatures: [FontFeature.tabularFigures()]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(spacing: 12, runSpacing: 2, children: [
              for (final v in values)
                Text('${v.trace.label}  ${v.db.toStringAsFixed(1)} dB',
                    style: TextStyle(
                        color: v.trace.color,
                        fontSize: 11,
                        fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
        ]),
      ),
    );
  }

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
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _chip(
                label: 'Peaks',
                selected: _markers,
                onTap: () => setState(() => _markers = !_markers),
              ),
              const SizedBox(width: 6),
              _chip(
                label: 'Range…',
                selected: false,
                onTap: _askRange,
              ),
              const SizedBox(width: 10),
              for (final r in ChartRange.all) ...[
                _chip(
                  label: r.label,
                  selected: (fLo - r.fLo).abs() < 1 && (fHi - r.fHi).abs() < 1,
                  onTap: () => setState(() {
                    _fLo = r.fLo;
                    _fHi = r.fHi;
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _syncLimitFields());
                    // A readout for a frequency that is no longer on screen is
                    // just a wrong number sitting above the chart.
                    final hz = _cursorHz;
                    if (hz != null && (hz < r.fLo || hz > r.fHi)) {
                      _cursorHz = null;
                    }
                  }),
                ),
                const SizedBox(width: 6),
              ],
            ]),
          ),
          if (_cursorHz != null) _readoutPanel(),
          const SizedBox(height: 6),
          if (widget.fill)
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _plot()),
                  if (_controlsOpen) _controlsPanel(),
                ],
              ),
            )
          else
            _plot(),
          const SizedBox(height: 8),
          Wrap(spacing: 14, runSpacing: 4, children: [
            for (final t in widget.traces)
              // Tapping a legend entry hides its trace. With a measured curve,
              // a prediction, a noise floor and a target all on one chart,
              // being able to take one away is how you actually read it.
              GestureDetector(
                onTap: () => setState(() {
                  if (!_hidden.remove(t.label)) _hidden.add(t.label);
                }),
                child: Opacity(
                  opacity: _hidden.contains(t.label) ? 0.35 : 1,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 16, height: 3, color: t.color),
                    const SizedBox(width: 5),
                    Text(t.label,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          decoration: _hidden.contains(t.label)
                              ? TextDecoration.lineThrough
                              : null,
                        )),
                  ]),
                ),
              ),
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
    this.cursorHz,
    this.markers = const [],
    this.dense = false,
  });

  /// Label every step rather than only the decade marks.
  final bool dense;

  final double? cursorHz;
  final List<({double hz, double db, bool isPeak})> markers;

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
    // What REW labels: every 1-2-3-4-5-6-8 step, not just the decades. Ten
    // octaves across a phone in portrait cannot carry that many without the
    // text colliding, so the full set is used only when there is room.
    const wide = {20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000};
    const denseSet = {
      20, 30, 40, 50, 60, 80,
      100, 200, 300, 400, 500, 600, 800,
      1000, 2000, 3000, 4000, 5000, 6000, 8000,
      10000, 20000,
    };
    final labelled = dense ? denseSet : wide;
    // Zoomed in, the wide set can leave the axis with one label or none, so
    // fall back to labelling every gridline in view.
    var inView = 0;
    for (final f in labelled) {
      if (f >= fMin && f <= fMax) inView++;
    }
    final labelAll = inView < 3;
    for (var decade = 1.0; decade <= 20000; decade *= 10) {
      for (var m = 1; m <= 9; m++) {
        final f = decade * m;
        if (f < fMin || f > fMax) continue;
        final x = _x(f, size);
        final isMajor = labelled.contains(f.round());
        canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom),
            isMajor ? major : minor);
        if (isMajor || labelAll) {
          final t =
              f >= 1000 ? '${(f / 1000).toStringAsFixed(f % 1000 == 0 ? 0 : 1)}k' : '${f.round()}';
          _text(canvas, t, Offset(x - 10, plot.bottom + 4), 10, Colors.white70);
        }
        // Decade boundaries drawn brighter, so the eye can find its place
        // without reading the numbers.
        if (m == 1) {
          canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom),
              Paint()..color = Colors.white30..strokeWidth = 1);
        }
      }
    }

    if (dense) {
      // Named axes. Obvious to whoever took the measurement, not at all obvious
      // to whoever is handed the picture afterwards.
      _text(canvas, 'SPL (dB)', const Offset(4, 2), 10, Colors.white54);
      _text(canvas, 'Frequency (Hz)',
          Offset(plot.right - 76, plot.bottom + 20), 10, Colors.white54);
    }

    // Magnitude grid: step chosen for the window on screen, so zooming in gives
    // finer divisions instead of one line across the middle.
    final dbSpan = (dbMax - dbMin).abs();
    // With the whole screen there is height for twice as many divisions, which
    // is the difference between reading a level off the chart and estimating it.
    final step = dbSpan > (dense ? 200 : 120)
        ? 20.0
        : dbSpan > (dense ? 120 : 60)
            ? 10.0
            : dbSpan > (dense ? 50 : 25)
                ? 5.0
                : dbSpan > (dense ? 24 : 12)
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
    // The short unit marks are the cramped version of the named axes, so only
    // one or the other — together they overlap into "SPL (dB)dB".
    if (!dense) {
      _text(canvas, 'dB', Offset(4, plot.top - 2), 9, Colors.white38);
      _text(canvas, 'Hz', Offset(plot.right - 14, plot.bottom + 16), 9,
          Colors.white38);
    }

    canvas.save();
    canvas.clipRect(plot);

    for (final t in traces) {
      // Phase first, so magnitude sits on top.
      if (t.showPhase && t.response.hasPhase) {
        _dashedPath(canvas, _buildPath(t.response.freqHz, t.response.phaseDeg,
            size, (v, s) => _yPhase(v.clamp(phaseMin, phaseMax), s)),
            t.color.withAlpha(140));
      }
      final path = _buildPath(t.response.freqHz, t.response.magDb, size,
          (v, s) => _yDb(v.clamp(dbMin, dbMax), s));
      if (t.dashed) {
        // A target was never measured, so it must not look like it was.
        _dashedPath(canvas, path, t.color);
      } else {
        canvas.drawPath(
          path,
          Paint()
            ..color = t.color
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round,
        );
      }
    }

    // Cursor last, over everything, with a dot on each trace so the readout
    // above can be matched to the curve it came from.
    final hz = cursorHz;
    if (hz != null && hz >= fMin && hz <= fMax) {
      final x = _x(hz, size);
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = Colors.white70
          ..strokeWidth = 1,
      );
      for (final t in traces) {
        final fr = t.response;
        if (fr.isEmpty) continue;
        var best = 0;
        var err = double.infinity;
        for (var i = 0; i < fr.length; i++) {
          final e = (math.log(fr.freqHz[i] / hz)).abs();
          if (e < err) {
            err = e;
            best = i;
          }
        }
        final v = fr.magDb[best];
        if (v < dbMin || v > dbMax) continue;
        canvas.drawCircle(
          Offset(x, _yDb(v, size)),
          3.5,
          Paint()..color = t.color,
        );
      }
    }
    for (final m in markers) {
      if (m.hz < fMin || m.hz > fMax) continue;
      if (m.db < dbMin || m.db > dbMax) continue;
      final x = _x(m.hz, size);
      final y = _yDb(m.db, size);
      final color = m.isPeak ? const Color(0xFFFF8A65) : const Color(0xFF64B5F6);
      canvas.drawCircle(Offset(x, y), 3, Paint()..color = color);
      final label = m.hz >= 1000
          ? '${(m.hz / 1000).toStringAsFixed(1)}k'
          : '${m.hz.round()}';
      // Peaks labelled above, dips below, so the text never sits on the curve.
      _text(canvas, label, Offset(x - 12, m.isPeak ? y - 16 : y + 5), 10, color);
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
