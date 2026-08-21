import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/features/cashier/cashier_money_format.dart';

void main() {
  for (final testCase in [
    (0, r'$0.00'),
    (1, r'$0.01'),
    (199, r'$1.99'),
    (12345, r'$123.45'),
  ]) {
    test('${testCase.$1} minor units formats as ${testCase.$2}', () {
      expect(formatUsdMinorUnits(testCase.$1), testCase.$2);
    });
  }

  test('negative presentation money is rejected', () {
    expect(() => formatUsdMinorUnits(-1), throwsArgumentError);
  });
}
