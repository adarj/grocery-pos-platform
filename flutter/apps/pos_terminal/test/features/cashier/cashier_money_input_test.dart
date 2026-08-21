import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/features/cashier/cashier_money_input.dart';

void main() {
  for (final testCase in [
    ('0', 0),
    ('5', 500),
    ('5.0', 500),
    ('5.00', 500),
    ('12.34', 1234),
    ('0.01', 1),
  ]) {
    test('${testCase.$1} parses as ${testCase.$2} minor units', () {
      expect(parseCashInputMinorUnits(testCase.$1), testCase.$2);
    });
  }

  test('surrounding human-entry whitespace is ignored', () {
    expect(parseCashInputMinorUnits('  5.50\n'), 550);
  });

  for (final invalid in [
    '',
    '.',
    '5.',
    '-1',
    '1.234',
    r'$5.00',
    '1,000.00',
    'abc',
    '1e2',
  ]) {
    test('$invalid is rejected without a floating-point fallback', () {
      expect(parseCashInputMinorUnits(invalid), isNull);
    });
  }
}
