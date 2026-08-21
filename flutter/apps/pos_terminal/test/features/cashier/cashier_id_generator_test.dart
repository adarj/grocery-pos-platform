import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/features/cashier/cashier_id_generator.dart';

void main() {
  test('secure generator returns opaque prefixed non-empty IDs', () {
    final generator = SecureCashierIdGenerator();

    final commandId = generator.nextCommandId();
    final transactionId = generator.nextTransactionId();

    expect(commandId, startsWith('cmd_'));
    expect(commandId.length, greaterThan('cmd_'.length));
    expect(transactionId, startsWith('txn_'));
    expect(transactionId.length, greaterThan('txn_'.length));
  });

  test('secure generator produces distinct values in a small smoke test', () {
    final generator = SecureCashierIdGenerator();

    final commandIds = {
      for (var index = 0; index < 16; index++) generator.nextCommandId(),
    };
    final transactionIds = {
      for (var index = 0; index < 16; index++) generator.nextTransactionId(),
    };

    expect(commandIds, hasLength(16));
    expect(transactionIds, hasLength(16));
  });
}
