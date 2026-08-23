import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';

void main() {
  test('start transaction serializes exactly to command schema v1', () {
    final command = StartTransactionCommand(
      commandId: 'cmd-start',
      transactionId: 'txn-001',
      expectedVersion: 0,
    );

    expect(command.toJson(), {
      'schema_version': 1,
      'command_id': 'cmd-start',
      'transaction_id': 'txn-001',
      'expected_version': 0,
      'command_type': 'start_transaction',
      'payload': <String, Object?>{},
    });
  });

  test('scan barcode serializes exactly to command schema v1', () {
    final command = ScanBarcodeCommand(
      commandId: 'cmd-scan',
      transactionId: 'txn-001',
      expectedVersion: 1,
      barcode: '049000001234',
    );

    expect(command.toJson(), {
      'schema_version': 1,
      'command_id': 'cmd-scan',
      'transaction_id': 'txn-001',
      'expected_version': 1,
      'command_type': 'scan_barcode',
      'payload': {'barcode': '049000001234'},
    });
  });

  test('tender cash serializes exact integer minor units', () {
    final command = TenderCashCommand(
      commandId: 'cmd-tender',
      transactionId: 'txn-001',
      expectedVersion: 2,
      amountMinorUnits: 500,
    );

    expect(command.toJson(), {
      'schema_version': 1,
      'command_id': 'cmd-tender',
      'transaction_id': 'txn-001',
      'expected_version': 2,
      'command_type': 'tender_cash',
      'payload': {'amount_minor_units': 500},
    });
    expect(command.toJson()['payload'], isA<Map<String, Object?>>());
    expect(
      (command.toJson()['payload']!
          as Map<String, Object?>)['amount_minor_units'],
      isA<int>(),
    );
  });

  test('complete transaction serializes exactly to command schema v1', () {
    final command = CompleteTransactionCommand(
      commandId: 'cmd-complete',
      transactionId: 'txn-001',
      expectedVersion: 3,
    );

    expect(command.toJson(), {
      'schema_version': 1,
      'command_id': 'cmd-complete',
      'transaction_id': 'txn-001',
      'expected_version': 3,
      'command_type': 'complete_transaction',
      'payload': <String, Object?>{},
    });
  });

  test('remove line item serializes exact zero-based index', () {
    final command = RemoveLineItemCommand(
      commandId: 'cmd-remove',
      transactionId: 'txn-001',
      expectedVersion: 4,
      lineIndex: 1,
    );

    expect(command.toJson(), {
      'schema_version': 1,
      'command_id': 'cmd-remove',
      'transaction_id': 'txn-001',
      'expected_version': 4,
      'command_type': 'remove_line_item',
      'payload': {'line_index': 1},
    });
    expect(command.lineIndex, 1);
  });

  test('remove line item rejects a negative index', () {
    expect(
      () => RemoveLineItemCommand(
        commandId: 'cmd-remove',
        transactionId: 'txn-001',
        expectedVersion: 4,
        lineIndex: -1,
      ),
      throwsArgumentError,
    );
  });

  test('void transaction serializes exact empty payload', () {
    final command = VoidTransactionCommand(
      commandId: 'cmd-void',
      transactionId: 'txn-001',
      expectedVersion: 4,
    );

    expect(command.toJson(), {
      'schema_version': 1,
      'command_id': 'cmd-void',
      'transaction_id': 'txn-001',
      'expected_version': 4,
      'command_type': 'void_transaction',
      'payload': <String, Object?>{},
    });
  });

  test('serialization retains caller identity and version unchanged', () {
    final command = ScanBarcodeCommand(
      commandId: 'opaque Command ID',
      transactionId: 'opaque Transaction ID',
      expectedVersion: 27,
      barcode: 'Mixed-Case-Barcode',
    );

    final first = command.toJson();
    final second = command.toJson();

    expect(first['command_id'], 'opaque Command ID');
    expect(first['transaction_id'], 'opaque Transaction ID');
    expect(first['expected_version'], 27);
    expect(first, second);
    expect(command.commandId, 'opaque Command ID');
    expect(command.expectedVersion, 27);
  });

  test('command constructors enforce local typed-value invariants', () {
    expect(
      () => StartTransactionCommand(
        commandId: '',
        transactionId: 'txn',
        expectedVersion: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => StartTransactionCommand(
        commandId: 'cmd',
        transactionId: '',
        expectedVersion: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => StartTransactionCommand(
        commandId: 'cmd',
        transactionId: 'txn',
        expectedVersion: -1,
      ),
      throwsArgumentError,
    );
    expect(
      () => ScanBarcodeCommand(
        commandId: 'cmd',
        transactionId: 'txn',
        expectedVersion: 0,
        barcode: '',
      ),
      throwsArgumentError,
    );
    expect(
      () => TenderCashCommand(
        commandId: 'cmd',
        transactionId: 'txn',
        expectedVersion: 0,
        amountMinorUnits: -1,
      ),
      throwsArgumentError,
    );
  });
}
