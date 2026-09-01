// Replaces the default `flutter create` widget test (which references a `MyApp` that
// doesn't exist here). Pumping the real app needs the native rewcore library, which
// isn't linked in a plain `flutter test` run, so this stays a lightweight smoke test;
// the substantive pure-Dart coverage lives in core_logic_test.dart.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('smoke: test harness runs', () {
    expect(2 + 2, 4);
  });
}
