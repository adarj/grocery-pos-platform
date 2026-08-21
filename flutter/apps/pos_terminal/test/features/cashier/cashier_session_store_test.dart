import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/features/cashier/cashier_session_store.dart';

PersistedCashierSession roundTrip(TransactionCommand command) {
  final session = PersistedCashierSession(
    activeTransactionId: command.transactionId,
    pendingCommand: command,
  );
  return PersistedCashierSession.fromJson(
    jsonDecode(jsonEncode(session.toJson())),
  );
}

void expectCommonCommandFields(
  TransactionCommand actual,
  TransactionCommand expected,
) {
  expect(actual.commandId, expected.commandId);
  expect(actual.transactionId, expected.transactionId);
  expect(actual.expectedVersion, expected.expectedVersion);
  expect(actual.commandType, expected.commandType);
  expect(actual.payload, expected.payload);
}

void main() {
  test('pending start round-trips exact command identity', () {
    final command = StartTransactionCommand(
      commandId: 'cmd-start',
      transactionId: 'txn-1',
      expectedVersion: 0,
    );

    final restored = roundTrip(command);

    expect(restored.activeTransactionId, 'txn-1');
    expect(restored.pendingCommand, isA<StartTransactionCommand>());
    expectCommonCommandFields(restored.pendingCommand!, command);
  });

  test('pending scan round-trips exact payload and version', () {
    final command = ScanBarcodeCommand(
      commandId: 'cmd-scan',
      transactionId: 'txn-1',
      expectedVersion: 3,
      barcode: '049000001234',
    );

    final restored = roundTrip(command).pendingCommand!;

    expect(restored, isA<ScanBarcodeCommand>());
    expectCommonCommandFields(restored, command);
    expect((restored as ScanBarcodeCommand).barcode, '049000001234');
  });

  test('pending tender round-trips exact integer amount', () {
    final command = TenderCashCommand(
      commandId: 'cmd-tender',
      transactionId: 'txn-1',
      expectedVersion: 4,
      amountMinorUnits: 500,
    );

    final restored = roundTrip(command).pendingCommand!;

    expect(restored, isA<TenderCashCommand>());
    expectCommonCommandFields(restored, command);
    expect((restored as TenderCashCommand).amountMinorUnits, 500);
  });

  test('pending completion round-trips exactly', () {
    final command = CompleteTransactionCommand(
      commandId: 'cmd-complete',
      transactionId: 'txn-1',
      expectedVersion: 5,
    );

    final restored = roundTrip(command).pendingCommand!;

    expect(restored, isA<CompleteTransactionCommand>());
    expectCommonCommandFields(restored, command);
  });

  test('known active session round-trips with null pending command', () {
    final restored = PersistedCashierSession.fromJson(
      jsonDecode(
        jsonEncode(
          PersistedCashierSession(activeTransactionId: 'txn-known').toJson(),
        ),
      ),
    );

    expect(restored.activeTransactionId, 'txn-known');
    expect(restored.pendingCommand, isNull);
  });

  test('recovery record persists no transaction truth or result metadata', () {
    final encoded = jsonEncode(
      PersistedCashierSession(
        activeTransactionId: 'txn-1',
        pendingCommand: ScanBarcodeCommand(
          commandId: 'cmd-scan',
          transactionId: 'txn-1',
          expectedVersion: 7,
          barcode: 'opaque-barcode',
        ),
      ).toJson(),
    );

    for (final forbidden in <String>[
      'line_items',
      'subtotal_minor_units',
      'total_minor_units',
      'tendered_cash_minor_units',
      'change_due_minor_units',
      'status',
      'outcome_kind',
      'outcome_code',
    ]) {
      expect(encoded, isNot(contains(forbidden)));
    }
  });

  test('pending command transaction mismatch fails closed', () {
    expect(
      () => PersistedCashierSession.fromJson({
        'schema_version': 1,
        'active_transaction_id': 'txn-1',
        'pending_command': {
          'schema_version': 1,
          'command_id': 'cmd-start',
          'transaction_id': 'txn-other',
          'expected_version': 0,
          'command_type': 'start_transaction',
          'payload': <String, Object?>{},
        },
      }),
      throwsA(
        isA<CashierSessionStoreFailure>().having(
          (failure) => failure.kind,
          'kind',
          CashierSessionStoreFailureKind.corruptData,
        ),
      ),
    );
  });

  test('unknown recovery schema version fails closed', () {
    expect(
      () => PersistedCashierSession.fromJson({
        'schema_version': 2,
        'active_transaction_id': 'txn-1',
        'pending_command': null,
      }),
      throwsA(isA<CashierSessionStoreFailure>()),
    );
  });

  test('unknown command type fails closed', () {
    expect(
      () => PersistedCashierSession.fromJson({
        'schema_version': 1,
        'active_transaction_id': 'txn-1',
        'pending_command': {
          'schema_version': 1,
          'command_id': 'cmd-1',
          'transaction_id': 'txn-1',
          'expected_version': 0,
          'command_type': 'future_command',
          'payload': <String, Object?>{},
        },
      }),
      throwsA(isA<CashierSessionStoreFailure>()),
    );
  });

  test('missing, extra, and wrong-type recovery fields fail closed', () {
    final invalidRecords = <Object?>[
      {'schema_version': 1, 'active_transaction_id': 'txn-1'},
      {
        'schema_version': 1,
        'active_transaction_id': 'txn-1',
        'pending_command': null,
        'snapshot': <String, Object?>{},
      },
      {
        'schema_version': 1,
        'active_transaction_id': 12,
        'pending_command': null,
      },
      <Object?>[],
    ];

    for (final record in invalidRecords) {
      expect(
        () => PersistedCashierSession.fromJson(record),
        throwsA(isA<CashierSessionStoreFailure>()),
      );
    }
  });

  test('invalid command fields and payloads fail closed', () {
    final invalidCommands = <Map<String, Object?>>[
      {
        'schema_version': 1,
        'command_id': '',
        'transaction_id': 'txn-1',
        'expected_version': 0,
        'command_type': 'start_transaction',
        'payload': <String, Object?>{},
      },
      {
        'schema_version': 1,
        'command_id': 'cmd-1',
        'transaction_id': 'txn-1',
        'expected_version': -1,
        'command_type': 'complete_transaction',
        'payload': <String, Object?>{},
      },
      {
        'schema_version': 1,
        'command_id': 'cmd-1',
        'transaction_id': 'txn-1',
        'expected_version': 1,
        'command_type': 'scan_barcode',
        'payload': {'barcode': 123},
      },
      {
        'schema_version': 1,
        'command_id': 'cmd-1',
        'transaction_id': 'txn-1',
        'expected_version': 1,
        'command_type': 'tender_cash',
        'payload': {'amount_minor_units': 1.5},
      },
    ];

    for (final command in invalidCommands) {
      expect(
        () => PersistedCashierSession.fromJson({
          'schema_version': 1,
          'active_transaction_id': 'txn-1',
          'pending_command': command,
        }),
        throwsA(isA<CashierSessionStoreFailure>()),
      );
    }
  });
}
