// Full-size, detailed view of a measurement, with export.
//
// The point of the export is second opinions: when the recommended tuning looks
// wrong, you want to hand the actual curve to an expert (or an LLM) rather than
// the app's conclusion. So it exports BOTH a labelled PNG of the graph and the
// underlying CSV — the picture is readable, the CSV is exact.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../models/measurement.dart';
import '../models/project.dart';
import '../ffi/rewcore.dart';
import '../platform/file_picker.dart';
import '../services/project_store.dart';
import 'detailed_chart.dart';
import 'distortion_screen.dart';
import 'time_domain_screen.dart';
import 'fullscreen_chart.dart';

class MeasurementDetailScreen extends StatefulWidget {
  const MeasurementDetailScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.traces,
    this.store,
    this.core,
    this.distortion,
    this.rawCapture,
    this.libraryPath,
  });

  final String title;
  final String subtitle;
  final List<DetailedTrace> traces;

  /// Supplied so other saved measurements can be pulled in as references.
  /// Comparing today against last month is a core tuning move — did the change
  /// help, and where — and it was impossible: every measurement lived alone in
  /// its own tune.
  final ProjectStore? store;

  /// For re-smoothing on the fullscreen graph.
  final Rewcore? core;

  /// Harmonic distortion from the same sweep, when there was one. Offered here
  /// rather than shown inline: it answers a different question from the
  /// response curve and deserves its own axes.
  final DistortionAnalysis? distortion;

  /// The samples this measurement came from, when they are still in memory.
  /// The time-domain views start from the deconvolution, so without these they
  /// cannot be offered at all.
  final RawCapture? rawCapture;
  final String? libraryPath;

  @override
  State<MeasurementDetailScreen> createState() =>
      _MeasurementDetailScreenState();
}

/// One measurement borrowed from another tune, and how far it has been shifted
/// to line up with the one being looked at.
class _Reference {
  _Reference(this.tuneName, this.channel, this.response, this.color);
  final String tuneName;
  final String channel;
  final FreqResponse response;
  final Color color;
  double offsetDb = 0;

  String get label => channel == 'system'
      ? tuneName
      : '$tuneName · $channel';

  DetailedTrace trace() => DetailedTrace(
        offsetDb == 0
            ? response
            : FreqResponse(
                response.freqHz,
                [for (final v in response.magDb) v + offsetDb],
              ),
        color,
        offsetDb == 0
            ? label
            : '$label (${offsetDb > 0 ? '+' : ''}${offsetDb.toStringAsFixed(1)} dB)',
      );
}

/// Enough colours to tell several references apart, chosen to stay distinct
/// from the measured blue, the noise-floor brown and the target green.
const _refColors = <Color>[
  Color(0xFFE57373),
  Color(0xFFBA68C8),
  Color(0xFF4DB6AC),
  Color(0xFFFFD54F),
  Color(0xFF90A4AE),
];

class _MeasurementDetailScreenState extends State<MeasurementDetailScreen> {
  final GlobalKey _boundary = GlobalKey();
  bool _busy = false;

  /// References pulled in from other tunes, with the level shift applied to
  /// each. Two measurements taken at different volumes have the same shape at
  /// different heights, and comparing shape is the whole point — so the offset
  /// is adjustable rather than the curves being force-aligned, which would hide
  /// a real level difference when that is what you were checking.
  final List<_Reference> _refs = [];

  List<DetailedTrace> get _allTraces => [
        ...widget.traces,
        for (final r in _refs) r.trace(),
      ];

  /// Offer every measurement in every saved tune, so a reference can be picked
  /// without leaving the graph.
  Future<void> _addReference() async {
    final store = widget.store;
    if (store == null) return;
    final tunes = await store.list();
    if (!mounted) return;

    final options = <({TuneProject tune, String channel})>[];
    for (final t in tunes) {
      for (final ch in t.measured.keys) {
        options.add((tune: t, channel: ch));
      }
    }
    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No other measurements have been saved yet.')));
      return;
    }

    final picked = await showModalBottomSheet<({TuneProject tune, String channel})>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Add a measurement to compare against — an earlier session, '
                'another channel, or the same car before a change.',
              ),
            ),
            for (final o in options)
              ListTile(
                title: Text(o.channel == 'system'
                    ? o.tune.name
                    : '${o.tune.name} · ${o.channel}'),
                subtitle: Text(
                    '${o.tune.createdAt.toIso8601String().split('T').first}'
                    '${o.tune.levelsDbfs[o.channel] != null ? '  ·  level '
                        '${o.tune.levelsDbfs[o.channel]!.toStringAsFixed(1)} dBFS' : ''}'),
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;

    final fr = picked.tune.measured[picked.channel];
    if (fr == null) return;
    setState(() {
      _refs.add(_Reference(
        picked.tune.name,
        picked.channel,
        fr,
        _refColors[_refs.length % _refColors.length],
      ));
    });
  }

  String get _stamp => DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.')
      .first;

  Future<String?> _writePng(String dir) async {
    final obj = _boundary.currentContext?.findRenderObject();
    if (obj is! RenderRepaintBoundary) return null;
    // 3x so the exported image is legible when zoomed, not a phone-sized thumb.
    final image = await obj.toImage(pixelRatio: 3.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return null;
    final file = File('$dir/measurement_$_stamp.png');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file.path;
  }

  Future<String?> _writeCsv(String dir) async {
    final b = StringBuffer()
      ..writeln('# ${widget.title}')
      ..writeln('# ${widget.subtitle}');
    for (final t in widget.traces) {
      b.writeln('# trace: ${t.label}');
    }
    final headers = <String>['freq_hz'];
    for (final t in widget.traces) {
      headers.add('${t.label}_db');
      if (t.response.hasPhase) headers.add('${t.label}_phase_deg');
    }
    b.writeln(headers.join(','));

    final ref = widget.traces.first.response;
    for (var i = 0; i < ref.length; i++) {
      final row = <String>[ref.freqHz[i].toStringAsFixed(2)];
      for (final t in widget.traces) {
        row.add(i < t.response.length
            ? t.response.magDb[i].toStringAsFixed(3)
            : '');
        if (t.response.hasPhase) {
          row.add(i < t.response.length
              ? t.response.phaseDeg[i].toStringAsFixed(2)
              : '');
        }
      }
      b.writeln(row.join(','));
    }
    final file = File('$dir/measurement_$_stamp.csv');
    await file.writeAsString(b.toString(), flush: true);
    return file.path;
  }

  /// Save to wherever the user wants, under a name they choose. Distinct from
  /// sharing: this puts the file in Files/Drive rather than handing it to an app.
  Future<void> _saveAs({required bool png}) async {
    final suggested = _sanitise(widget.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final ctl = TextEditingController(text: suggested);
        return AlertDialog(
          title: Text(png ? 'Save graph as' : 'Save data as'),
          content: TextField(
            controller: ctl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'File name',
              suffixText: png ? '.png' : '.csv',
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, ctl.text.trim()),
                child: const Text('Save')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;

    setState(() => _busy = true);
    try {
      final dir = await NativeFilePicker.exportDirectory();
      if (dir == null) {
        _toast('Saving is only available on the device build.');
        return;
      }
      final path = png ? await _writePng(dir) : await _writeCsv(dir);
      if (path == null) {
        _toast('Could not render the file.');
        return;
      }
      final saved = await NativeFilePicker.saveFileAs(
        path,
        suggestedName: '$name.${png ? 'png' : 'csv'}',
        mime: png ? 'image/png' : 'text/csv',
      );
      _toast(saved ? 'Saved.' : 'Save cancelled.');
    } on PlatformException catch (e) {
      _toast('Save failed: ${e.message}');
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A file-name-safe version of the measurement title.
  String _sanitise(String s) {
    final cleaned = s
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(' ', '_');
    return cleaned.isEmpty ? 'measurement' : cleaned;
  }

  Future<void> _export({required bool png, required bool csv}) async {
    setState(() => _busy = true);
    try {
      final dir = await NativeFilePicker.exportDirectory();
      if (dir == null) {
        _toast('Export is only available on the device build.');
        return;
      }
      final paths = <String>[];
      if (png) {
        final p = await _writePng(dir);
        if (p != null) paths.add(p);
      }
      if (csv) {
        final p = await _writeCsv(dir);
        if (p != null) paths.add(p);
      }
      if (paths.isEmpty) {
        _toast('Nothing to export.');
        return;
      }
      await NativeFilePicker.shareFiles(paths,
          mime: png && !csv ? 'image/png' : '*/*');
    } on PlatformException catch (e) {
      _toast('Export failed: ${e.message}');
    } catch (e) {
      _toast('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Measurement detail')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Only what is inside the boundary ends up in the exported image.
          RepaintBoundary(
            key: _boundary,
            child: DetailedFrChart(
              traces: _allTraces,
              title: widget.title,
              subtitle: widget.subtitle,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => FullscreenChartScreen(
                    traces: _allTraces,
                    title: widget.title,
                    subtitle: widget.subtitle,
                    core: widget.core,
                  ),
                ),
              ),
              icon: const Icon(Icons.fullscreen, size: 20),
              label: const Text('Full screen'),
            ),
          ),
          if (widget.distortion != null &&
              !widget.distortion!.isEmpty) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DistortionScreen(
                    distortion: widget.distortion!,
                    title: widget.title,
                    subtitle: widget.subtitle,
                  ),
                )),
                icon: const Icon(Icons.graphic_eq, size: 18),
                label: Text('Distortion — worst '
                    '${widget.distortion!.worstThdPercent.toStringAsFixed(1)}%'),
              ),
            ),
          ],
          if (widget.rawCapture != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => TimeDomainScreen(
                    capture: widget.rawCapture!,
                    libraryPath: widget.libraryPath,
                    title: widget.title,
                  ),
                )),
                icon: const Icon(Icons.timeline, size: 18),
                label: const Text('In time — impulse, decay, waterfall'),
              ),
            ),
          ],
          if (widget.store != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _addReference,
                icon: const Icon(Icons.add_chart, size: 18),
                label: const Text('Compare with another measurement'),
              ),
            ),
          ],
          for (final r in _refs)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Container(width: 14, height: 3, color: r.color),
                const SizedBox(width: 8),
                Expanded(child: Text(r.label, style: const TextStyle(fontSize: 13))),
                // Level shift, not auto-alignment: two measurements taken at
                // different volumes have the same shape at different heights,
                // and forcing them together would hide a level difference when
                // that is exactly what you were checking.
                IconButton(
                  tooltip: 'Down 1 dB',
                  icon: const Icon(Icons.remove, size: 18),
                  onPressed: () => setState(() => r.offsetDb -= 1),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    '${r.offsetDb > 0 ? '+' : ''}${r.offsetDb.toStringAsFixed(0)} dB',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: 'Up 1 dB',
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: () => setState(() => r.offsetDb += 1),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _refs.remove(r)),
                ),
              ]),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
                'Pinch to zoom (sideways for frequency, up and down for level) '
                'and drag to pan; Reset returns to the full range. The export '
                'captures the view you are looking at.',
                style: TextStyle(fontSize: 11)),
          ),
          const SizedBox(height: 16),
          Text(
            'Save puts the file in Files (you choose the folder and name); Share '
            'hands it straight to another app. The CSV is the exact measured '
            'data — the better input when asking an expert or an LLM.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _saveAs(png: true),
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('Save graph (PNG)…'),
            ),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : () => _saveAs(png: false),
              icon: const Icon(Icons.save_alt, size: 18),
              label: const Text('Save data (CSV)…'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _export(png: true, csv: false),
              icon: const Icon(Icons.image, size: 18),
              label: const Text('Share graph'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _export(png: false, csv: true),
              icon: const Icon(Icons.table_chart, size: 18),
              label: const Text('Share data'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _export(png: true, csv: true),
              icon: const Icon(Icons.share, size: 18),
              label: const Text('Share both'),
            ),
          ]),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
