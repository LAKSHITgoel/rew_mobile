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

import '../platform/file_picker.dart';
import 'detailed_chart.dart';

class MeasurementDetailScreen extends StatefulWidget {
  const MeasurementDetailScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.traces,
  });

  final String title;
  final String subtitle;
  final List<DetailedTrace> traces;

  @override
  State<MeasurementDetailScreen> createState() =>
      _MeasurementDetailScreenState();
}

class _MeasurementDetailScreenState extends State<MeasurementDetailScreen> {
  final GlobalKey _boundary = GlobalKey();
  bool _busy = false;

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
              traces: widget.traces,
              title: widget.title,
              subtitle: widget.subtitle,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Export the graph as an image, or the raw numbers as CSV, to get a '
            'second opinion on the recommended tuning. The CSV is the exact '
            'measured data — best when asking an expert or an LLM.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _export(png: true, csv: false),
              icon: const Icon(Icons.image, size: 18),
              label: const Text('Share graph (PNG)'),
            ),
            FilledButton.tonalIcon(
              onPressed: _busy ? null : () => _export(png: false, csv: true),
              icon: const Icon(Icons.table_chart, size: 18),
              label: const Text('Share data (CSV)'),
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
