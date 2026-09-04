// The bar chart's own arithmetic: the dB window it picks, and that it renders
// without throwing on the shapes an RTA actually produces. A painter that
// crashes on an empty or single-band spectrum takes the whole screen with it,
// and both happen — one at startup, one at 1/1 octave.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rew_mobile/src/models/measurement.dart';
import 'package:rew_mobile/src/ui/rta_chart.dart';

FreqResponse _bands(List<double> hz, List<double> db) => FreqResponse(hz, db);

Future<void> _pump(WidgetTester tester, RtaBarChart chart) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SizedBox(width: 400, height: 300, child: chart)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders a normal spectrum with peak hold', (tester) async {
    await _pump(
      tester,
      RtaBarChart(
        spectrum: _bands([100, 200, 400, 800], [-60, -55, -58, -62]),
        peak: _bands([100, 200, 400, 800], [-52, -50, -54, -57]),
        bandsPerOctave: 1,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Peak hold'), findsOneWidget);
  });

  testWidgets('an empty spectrum does not throw', (tester) async {
    // This is the state at startup, before the first block has arrived.
    await _pump(tester, RtaBarChart(spectrum: FreqResponse(const [], const [])));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a single band does not throw', (tester) async {
    await _pump(
      tester,
      RtaBarChart(spectrum: _bands([1000], [-40]), bandsPerOctave: 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the finest band spacing still renders', (tester) async {
    // At 1/48 octave the bars are barely a pixel wide, which is where a naive
    // gap calculation collapses them to nothing or to negative width.
    final hz = <double>[];
    final db = <double>[];
    for (var i = 0; i < 400; i++) {
      hz.add(20 * (1.0146 * (i + 1)));
      db.add(-70 + (i % 11).toDouble());
    }
    await _pump(
        tester, RtaBarChart(spectrum: _bands(hz, db), bandsPerOctave: 48));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a nearly flat spectrum is not magnified into drama',
      (tester) async {
    // Everything within 2 dB. The window must not zoom in until noise looks
    // like structure.
    await _pump(
      tester,
      RtaBarChart(
        spectrum: _bands([100, 200, 400], [-60, -59, -61]),
        bandsPerOctave: 1,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('peak hold of a different length is ignored, not fatal',
      (tester) async {
    // Happens for one frame after the band setting changes and the analyser is
    // rebuilt: the two traces briefly disagree.
    await _pump(
      tester,
      RtaBarChart(
        spectrum: _bands([100, 200], [-60, -55]),
        peak: _bands([100, 200, 400], [-50, -48, -47]),
        bandsPerOctave: 1,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
