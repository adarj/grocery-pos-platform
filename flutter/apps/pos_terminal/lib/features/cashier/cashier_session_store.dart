import 'dart:convert';

import '../../core/pos_core/models/transaction_command.dart';

enum CashierSessionStoreFailureKind { corruptData, storageUnavailable }

final class CashierSessionStoreFailure implements Exception {
  const CashierSessionStoreFailure._(this.kind, this.message);

  const CashierSessionStoreFailure.corruptData()
    : this._(
        CashierSessionStoreFailureKind.corruptData,
        'Saved cashier recovery data could not be read safely.',
      );

  const CashierSessionStoreFailure.storageUnavailable()
    : this._(
        CashierSessionStoreFailureKind.storageUnavailable,
        'Local cashier recovery storage is unavailable.',
      );

  final CashierSessionStoreFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

abstract interface class CashierSessionStore {
  Future<PersistedCashierSession?> load();

  Future<void> save(PersistedCashierSession session);

  Future<void> clear();
}

final class PersistedCashierSession {
  PersistedCashierSession({
    required this.activeTransactionId,
    this.pendingCommand,
  }) {
    if (activeTransactionId.isEmpty ||
        (pendingCommand != null &&
            pendingCommand!.transactionId != activeTransactionId)) {
      throw const CashierSessionStoreFailure.corruptData();
    }
  }

  static const schemaVersion = 1;

  final String activeTransactionId;
  final TransactionCommand? pendingCommand;

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'active_transaction_id': activeTransactionId,
    'pending_command': pendingCommand?.toJson(),
  };

  factory PersistedCashierSession.fromJson(Object? value) {
    final record = _requireExactObject(value, const {
      'schema_version',
      'active_transaction_id',
      'pending_command',
    });
    if (_requireInt(record['schema_version']) != schemaVersion) {
      throw const CashierSessionStoreFailure.corruptData();
    }

    final activeTransactionId = _requireNonemptyString(
      record['active_transaction_id'],
    );
    final pendingValue = record['pending_command'];
    final pendingCommand = pendingValue == null
        ? null
        : _decodeCommand(pendingValue);

    return PersistedCashierSession(
      activeTransactionId: activeTransactionId,
      pendingCommand: pendingCommand,
    );
  }
}

PersistedCashierSession decodePersistedCashierSession(String source) {
  try {
    return PersistedCashierSession.fromJson(jsonDecode(source));
  } on CashierSessionStoreFailure {
    rethrow;
  } on FormatException {
    throw const CashierSessionStoreFailure.corruptData();
  } on ArgumentError {
    throw const CashierSessionStoreFailure.corruptData();
  }
}

TransactionCommand _decodeCommand(Object? value) {
  final command = _requireExactObject(value, const {
    'schema_version',
    'command_id',
    'transaction_id',
    'expected_version',
    'command_type',
    'payload',
  });
  if (_requireInt(command['schema_version']) !=
      TransactionCommand.schemaVersion) {
    throw const CashierSessionStoreFailure.corruptData();
  }

  final commandId = _requireNonemptyString(command['command_id']);
  final transactionId = _requireNonemptyString(command['transaction_id']);
  final expectedVersion = _requireNonnegativeInt(command['expected_version']);
  final commandType = _requireNonemptyString(command['command_type']);
  final payload = command['payload'];

  return switch (commandType) {
    'start_transaction' => _decodeStartCommand(
      commandId,
      transactionId,
      expectedVersion,
      payload,
    ),
    'scan_barcode' => _decodeScanCommand(
      commandId,
      transactionId,
      expectedVersion,
      payload,
    ),
    'tender_cash' => _decodeTenderCommand(
      commandId,
      transactionId,
      expectedVersion,
      payload,
    ),
    'complete_transaction' => _decodeCompleteCommand(
      commandId,
      transactionId,
      expectedVersion,
      payload,
    ),
    'remove_line_item' => _decodeRemoveLineItemCommand(
      commandId,
      transactionId,
      expectedVersion,
      payload,
    ),
    'void_transaction' => _decodeVoidTransactionCommand(
      commandId,
      transactionId,
      expectedVersion,
      payload,
    ),
    _ => throw const CashierSessionStoreFailure.corruptData(),
  };
}

StartTransactionCommand _decodeStartCommand(
  String commandId,
  String transactionId,
  int expectedVersion,
  Object? payload,
) {
  _requireExactObject(payload, const {});
  return StartTransactionCommand(
    commandId: commandId,
    transactionId: transactionId,
    expectedVersion: expectedVersion,
  );
}

ScanBarcodeCommand _decodeScanCommand(
  String commandId,
  String transactionId,
  int expectedVersion,
  Object? payload,
) {
  final fields = _requireExactObject(payload, const {'barcode'});
  return ScanBarcodeCommand(
    commandId: commandId,
    transactionId: transactionId,
    expectedVersion: expectedVersion,
    barcode: _requireNonemptyString(fields['barcode']),
  );
}

TenderCashCommand _decodeTenderCommand(
  String commandId,
  String transactionId,
  int expectedVersion,
  Object? payload,
) {
  final fields = _requireExactObject(payload, const {'amount_minor_units'});
  return TenderCashCommand(
    commandId: commandId,
    transactionId: transactionId,
    expectedVersion: expectedVersion,
    amountMinorUnits: _requireNonnegativeInt(fields['amount_minor_units']),
  );
}

CompleteTransactionCommand _decodeCompleteCommand(
  String commandId,
  String transactionId,
  int expectedVersion,
  Object? payload,
) {
  _requireExactObject(payload, const {});
  return CompleteTransactionCommand(
    commandId: commandId,
    transactionId: transactionId,
    expectedVersion: expectedVersion,
  );
}

RemoveLineItemCommand _decodeRemoveLineItemCommand(
  String commandId,
  String transactionId,
  int expectedVersion,
  Object? payload,
) {
  final fields = _requireExactObject(payload, const {'line_index'});
  return RemoveLineItemCommand(
    commandId: commandId,
    transactionId: transactionId,
    expectedVersion: expectedVersion,
    lineIndex: _requireNonnegativeInt(fields['line_index']),
  );
}

VoidTransactionCommand _decodeVoidTransactionCommand(
  String commandId,
  String transactionId,
  int expectedVersion,
  Object? payload,
) {
  _requireExactObject(payload, const {});
  return VoidTransactionCommand(
    commandId: commandId,
    transactionId: transactionId,
    expectedVersion: expectedVersion,
  );
}

Map<String, Object?> _requireExactObject(
  Object? value,
  Set<String> expectedFields,
) {
  if (value is! Map) {
    throw const CashierSessionStoreFailure.corruptData();
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw const CashierSessionStoreFailure.corruptData();
    }
    result[entry.key as String] = entry.value;
  }
  if (result.length != expectedFields.length ||
      !expectedFields.every(result.containsKey)) {
    throw const CashierSessionStoreFailure.corruptData();
  }
  return result;
}

String _requireNonemptyString(Object? value) {
  if (value is! String || value.isEmpty) {
    throw const CashierSessionStoreFailure.corruptData();
  }
  return value;
}

int _requireInt(Object? value) {
  if (value is! int) {
    throw const CashierSessionStoreFailure.corruptData();
  }
  return value;
}

int _requireNonnegativeInt(Object? value) {
  final result = _requireInt(value);
  if (result < 0) {
    throw const CashierSessionStoreFailure.corruptData();
  }
  return result;
}
