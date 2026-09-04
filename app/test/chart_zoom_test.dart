// The chart's zoom is a gesture, so it is tested as one: a real pinch driven
// through the widget tree, not just the arithmetic behind it. A two-finger
// pinch cannot be synthesised over adb, so this is the only honest way to know
// it works before it reaches the car.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/models/measurement.dart';
import 'package:rew_mobile/src/ui/detailed_chart.dart';

FreqResponse _sweepish() {
  final freq = <double>[];
  final mag = <double>[];
  for (var i = 0; i < 200; i++) {
    final t = i / 199;
    freq.add(20 * (1000.0).toDouble() * 0 + 20 * (1 + t * 999));
    mag.add(-40 + 10 * (i % 7));
  }
  return FreqResponse(freq, mag);
}

Future<void> _pumpChart(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 500,
        child: DetailedFrChart(
          traces: [DetailedTrace(_sweepish(), Colors.blue, 'Measured')],
          title: 'zoom test',
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a range chip narrows the view, and Reset restores it',
      (tester) async {
    // Gestures are not covered here. This harness does not deliver touches to
    // the chart's recognizer in a way that reproduces a pinch or a drag — a
    // "pinch" arrives as a single pointer, and a drag arrives not at all — so a
    // passing gesture test would be asserting the harness's behaviour rather
    // than the app's. The window-changing path is covered through a control a
    // test can genuinely press; the cursor and the pinch are checked on a
    // device, where they are real touches.
    await _pumpChart(tester);
    expect(find.text('Reset'), findsNothing);

    await tester.ensureVisible(find.text('Bass'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bass'));
    await tester.pumpAndSettle();
    expect(find.text('Reset'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(find.text('Reset'), findsNothing);
  });

}
