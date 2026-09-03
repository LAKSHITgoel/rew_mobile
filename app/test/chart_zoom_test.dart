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
  testWidgets('a pinch zooms the chart, and Reset returns to the full view',
      (tester) async {
    await _pumpChart(tester);

    // Nothing to reset until the view has actually been changed.
    expect(find.text('Reset'), findsNothing);

    final chart = find.byType(CustomPaint).first;
    final centre = tester.getCenter(chart);

    // Two fingers apart: a zoom-in.
    final f1 = await tester.startGesture(centre - const Offset(40, 0));
    final f2 = await tester.startGesture(centre + const Offset(40, 0));
    await tester.pump();
    await f1.moveBy(const Offset(-60, 0));
    await f2.moveBy(const Offset(60, 0));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();

    expect(find.text('Reset'), findsOneWidget,
        reason: 'the pinch should have changed the visible window');

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(find.text('Reset'), findsNothing);
  });

}
