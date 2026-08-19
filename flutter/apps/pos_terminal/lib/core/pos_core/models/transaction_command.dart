sealed class TransactionCommand {
  TransactionCommand({
    required this.commandId,
    required this.transactionId,
    required this.expectedVersion,
  }) {
    if (commandId.isEmpty) {
      throw ArgumentError.value(commandId, 'commandId', 'must not be empty');
    }
    if (transactionId.isEmpty) {
      throw ArgumentError.value(
        transactionId,
        'transactionId',
        'must not be empty',
      );
    }
    if (expectedVersion < 0) {
      throw ArgumentError.value(
        expectedVersion,
        'expectedVersion',
        'must be nonnegative',
      );
    }
  }

  static const schemaVersion = 1;

  final String commandId;
  final String transactionId;
  final int expectedVersion;

  String get commandType;
  Map<String, Object?> get payload;

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'command_id': commandId,
    'transaction_id': transactionId,
    'expected_version': expectedVersion,
    'command_type': commandType,
    'payload': payload,
  };
}

final class StartTransactionCommand extends TransactionCommand {
  StartTransactionCommand({
    required super.commandId,
    required super.transactionId,
    required super.expectedVersion,
  });

  @override
  String get commandType => 'start_transaction';

  @override
  Map<String, Object?> get payload => <String, Object?>{};
}

final class ScanBarcodeCommand extends TransactionCommand {
  ScanBarcodeCommand({
    required super.commandId,
    required super.transactionId,
    required super.expectedVersion,
    required this.barcode,
  }) {
    if (barcode.isEmpty) {
      throw ArgumentError.value(barcode, 'barcode', 'must not be empty');
    }
  }

  final String barcode;

  @override
  String get commandType => 'scan_barcode';

  @override
  Map<String, Object?> get payload => {'barcode': barcode};
}

final class TenderCashCommand extends TransactionCommand {
  TenderCashCommand({
    required super.commandId,
    required super.transactionId,
    required super.expectedVersion,
    required this.amountMinorUnits,
  }) {
    if (amountMinorUnits < 0) {
      throw ArgumentError.value(
        amountMinorUnits,
        'amountMinorUnits',
        'must be nonnegative',
      );
    }
  }

  final int amountMinorUnits;

  @override
  String get commandType => 'tender_cash';

  @override
  Map<String, Object?> get payload => {'amount_minor_units': amountMinorUnits};
}

final class CompleteTransactionCommand extends TransactionCommand {
  CompleteTransactionCommand({
    required super.commandId,
    required super.transactionId,
    required super.expectedVersion,
  });

  @override
  String get commandType => 'complete_transaction';

  @override
  Map<String, Object?> get payload => <String, Object?>{};
}
