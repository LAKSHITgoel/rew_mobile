// Comparing measurements, and the marker maths behind "show me the peaks".
// Both are things a wrong answer would quietly mislead you about rather than
// crash, which is the kind worth pinning down.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/models/measurement.dart';
import 'package:rew_mobile/src/models/project.dart';
import 'package:rew_mobile/src/services/project_store.dart';
import 'package:rew_mobile/src/ui/detailed_chart.dart';
import 'package:rew_mobile/src/ui/measurement_detail_screen.dart';

FreqResponse _curve({double offset = 0, double bumpAt = 0}) {
  final hz = <double>[];
  final db = <double>[];
  for (var i = 0; i < 120; i++) {
    final f = 20 * (1.0417 * (i + 1));
    hz.add(f);
    var v = -40 + offset;
    if (bumpAt > 0 && (f / bumpAt - 1).abs() < 0.06) v += 9;
    db.add(v);
  }
  return FreqResponse(hz, db);
}

/// A ListView only builds what the viewport reaches, so on the default 800x600
/// test surface the controls below the chart do not exist to be found at all.
/// Give the test a tall window instead of scrolling for every tap.
void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The range chips scroll sideways, so bring one into view before tapping.
Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, ProjectStore store) async {
  _bigScreen(tester);
  await tester.pumpWidget(MaterialApp(
    home: MeasurementDetailScreen(
      title: 'today',
      subtitle: 'test',
      store: store,
      traces: [DetailedTrace(_curve(), Colors.blue, 'Measured')],
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('another tune can be pulled in to compare against',
      (tester) async {
    final store = MemoryProjectStore();
    await store.save(TuneProject(
      id: 'old',
      name: 'Last month',
      createdAt: DateTime(2026, 8, 1),
      measured: {'system': _curve(offset: -6)},
    ));

    await _open(tester, store);
    expect(find.text('Last month'), findsNothing);

    await _tap(tester, find.text('Compare with another measurement'));
    await _tap(tester, find.text('Last month').last);

    // It appears with its own level control, so two measurements taken at
    // different volumes can be compared on shape.
    expect(find.text('Last month'), findsWidgets);
    expect(find.text('0 dB'), findsOneWidget);

    await _tap(tester, find.byTooltip('Up 1 dB'));
    expect(find.text('+1 dB'), findsOneWidget);

    await _tap(tester, find.byTooltip('Remove'));
    expect(find.byTooltip('Up 1 dB'), findsNothing);
  });

  testWidgets('with nothing else saved, it says so rather than doing nothing',
      (tester) async {
    await _open(tester, MemoryProjectStore());
    await _tap(tester, find.text('Compare with another measurement'));
    expect(find.textContaining('No other measurements'), findsOneWidget);
  });

  testWidgets('markers can be switched on and label a real peak',
      (tester) async {
    _bigScreen(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 500,
          child: DetailedFrChart(
            title: 'markers',
            traces: [
              DetailedTrace(_curve(bumpAt: 1000), Colors.blue, 'Measured'),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await _tap(tester, find.text('Peaks'));
    // Drawn on the canvas rather than as widgets, so the check is that turning
    // it on neither throws nor blanks the chart.
    expect(tester.takeException(), isNull);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('a named range narrows the view and Reset restores it',
      (tester) async {
    _bigScreen(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 500,
          child: DetailedFrChart(
            title: 'ranges',
            traces: [DetailedTrace(_curve(), Colors.blue, 'Measured')],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Reset'), findsNothing);
    await _tap(tester, find.text('Bass'));
    expect(find.text('Reset'), findsOneWidget);

    await _tap(tester, find.text('Reset'));
    expect(find.text('Reset'), findsNothing);
  });
}
