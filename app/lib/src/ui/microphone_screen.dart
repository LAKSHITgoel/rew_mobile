// The microphone, and its calibration.
//
// The calibration belongs to the mic rather than to a car or a tune, so it is
// managed here, once, and used by everything that measures: swept measurements,
// the polarity check, the real-time analyser, and anything an assistant asks
// for over the network. Previously it could only be loaded inside a tune and
// was lost on restart, which meant most measurements were quietly taken
// uncalibrated — reading the microphone's own response as if it were the car's.
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/mic_calibration.dart';
import '../platform/file_picker.dart';

class MicrophoneScreen extends StatefulWidget {
  const MicrophoneScreen({super.key, required this.services});
  final AppServices services;

  @override
  State<MicrophoneScreen> createState() => _MicrophoneScreenState();
}

class _MicrophoneScreenState extends State<MicrophoneScreen> {
  String? _message;
  bool _busy = false;

  AppServices get s => widget.services;

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final text = await NativeFilePicker.pickTextFile();
      if (text == null) return;
      final cal = MicCalibration.parse(text);
      if (cal.isEmpty) {
        setState(() => _message =
            'That file has no calibration points in it. A UMIK-1 file is a '
            'list of frequencies and levels, usually named for the mic\'s '
            'serial number.');
        return;
      }
      final name = 'UMIK-1 (${cal.freqHz.length} points)';
      await s.calibrationStore.save(name, text);
      setState(() {
        s.calibration = cal;
        s.calibrationName = name;
        _message = 'Loaded. Every measurement from now on uses it.';
      });
    } catch (e) {
      setState(() => _message = 'Could not read that file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    await s.calibrationStore.clear();
    setState(() {
      s.calibration = null;
      s.calibrationName = null;
      _message = 'Cleared. Measurements will show the microphone\'s own '
          'response as well as the car\'s.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final cal = s.calibration;
    return Scaffold(
      appBar: AppBar(title: const Text('Microphone')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: cal == null
                ? Theme.of(context).colorScheme.surfaceContainerHighest
                : const Color(0xFF1B3D23),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(cal == null ? Icons.info_outline : Icons.check_circle,
                    color: cal == null ? null : const Color(0xFF9BE7A8)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cal == null
                            ? 'No calibration loaded'
                            : 'Calibrated',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (s.calibrationName != null)
                        Text(s.calibrationName!,
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Your UMIK-1 came with a calibration file named for its serial '
            'number. It describes how the microphone itself deviates from '
            'flat — several dB at the extremes — and without it those '
            'deviations are read as if the car made them.\n\n'
            'Loaded here, it applies to everything: swept measurements, the '
            'polarity check, the real-time analyser, and any measurement an '
            'assistant asks for. It is kept until you replace it.',
          ),
          const SizedBox(height: 16),
          Row(children: [
            FilledButton.icon(
              onPressed: _busy ? null : _load,
              icon: const Icon(Icons.file_open),
              label: Text(cal == null ? 'Load calibration file' : 'Replace'),
            ),
            const SizedBox(width: 10),
            if (cal != null)
              TextButton(onPressed: _busy ? null : _clear, child: const Text('Clear')),
          ]),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_message!),
            ),
          if (cal != null) ...[
            const Divider(height: 32),
            Text('What it corrects',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Across ${cal.freqHz.first.round()} Hz to '
              '${(cal.freqHz.last / 1000).toStringAsFixed(1)} kHz, the '
              'correction ranges from '
              '${cal.gainDb.reduce((a, b) => a < b ? a : b).toStringAsFixed(1)} '
              'to '
              '${cal.gainDb.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)} dB. '
              'That is how far your measurements would be out without it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const Divider(height: 32),
          Text('A note on the 90-degree file',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          const Text(
            'UMIK-1 mics ship with two files: one for pointing the mic at the '
            'speaker, one ending _90deg for pointing it at the ceiling. For a '
            'car, where sound arrives from all round, the 90-degree file with '
            'the mic pointing up is usually the better match.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
