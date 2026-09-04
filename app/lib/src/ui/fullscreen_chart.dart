// The measurement graph, full screen and sideways.
//
// A response curve wants width: ten octaves squeezed into a phone's portrait
// width is about 35 pixels per octave, which is why the chart embedded in the
// wizard reads as a sketch rather than an instrument. Turned sideways and given
// the whole screen it gets roughly three times that, which is where the detail
// that was already in the data becomes visible.
//
// Everything here is the same painter the inline chart uses — the difference is
// only how much room it gets and how densely it can afford to label.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'detailed_chart.dart';

class FullscreenChartScreen extends StatefulWidget {
  const FullscreenChartScreen({
    super.key,
    required this.traces,
    required this.title,
    this.subtitle = '',
  });

  final List<DetailedTrace> traces;
  final String title;
  final String subtitle;

  @override
  State<FullscreenChartScreen> createState() => _FullscreenChartScreenState();
}

class _FullscreenChartScreenState extends State<FullscreenChartScreen> {
  @override
  void initState() {
    super.initState();
    // Landscape while this is open, and the system bars out of the way: the
    // point of the screen is the plot, and a status bar costs a tenth of the
    // height it has to work with.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
  }

  @override
  void dispose() {
    // Put the phone back as it was, whichever way this screen is left.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101215),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: DetailedFrChart(
                traces: widget.traces,
                title: widget.title,
                subtitle: widget.subtitle,
                fill: true,
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.fullscreen_exit, color: Colors.white70),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
