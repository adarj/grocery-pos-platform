import 'json_fields.dart';
import 'pos_core_failure.dart';

enum TransactionStatus {
  open('open'),
  paid('paid'),
  completed('completed'),
  voided('voided');

  const TransactionStatus(this.wireName);

  final String wireName;

  static TransactionStatus fromWireName(String value) {
    return switch (value) {
      'open' => TransactionStatus.open,
      'paid' => TransactionStatus.paid,
      'completed' => TransactionStatus.completed,
      'voided' => TransactionStatus.voided,
      _ => throw const PosCoreInvalidResponseFailure(
        'Unknown transaction status.',
      ),
    };
  }
}

final class TransactionLineItem {
  const TransactionLineItem({
    required this.barcode,
    required this.description,
    required this.unitPriceMinorUnits,
  });

  final String barcode;
  final String description;
  final int unitPriceMinorUnits;

  factory TransactionLineItem.fromJson(Map<String, Object?> json) {
    const context = 'transaction line item';
    return TransactionLineItem(
      barcode: requireJsonString(json, 'barcode', context, nonEmpty: true),
      description: requireJsonString(json, 'description', context),
      unitPriceMinorUnits: requireJsonNonnegativeInt(
        json,
        'unit_price_minor_units',
        context,
      ),
    );
  }
}

final class TransactionSnapshot {
  TransactionSnapshot({
    required this.transactionId,
    this.ownedByAuthenticatedOperator = false,
    required this.version,
    required this.status,
    required List<TransactionLineItem> lineItems,
    required this.subtotalMinorUnits,
    required this.taxMinorUnits,
    required this.totalMinorUnits,
    required this.tenderedCashMinorUnits,
    required this.changeDueMinorUnits,
  }) : lineItems = List.unmodifiable(lineItems);

  final String transactionId;

  /// A server-derived relationship hint used only to bind legacy local
  /// recovery. Racket remains authoritative for every mutation.
  final bool ownedByAuthenticatedOperator;
  final int version;
  final TransactionStatus status;
  final List<TransactionLineItem> lineItems;
  final int subtotalMinorUnits;
  final int taxMinorUnits;
  final int totalMinorUnits;
  final int? tenderedCashMinorUnits;
  final int? changeDueMinorUnits;

  factory TransactionSnapshot.fromJson(Map<String, Object?> json) {
    const context = 'transaction snapshot';
    final rawLineItems = requireJsonList(json, 'line_items', context);

    return TransactionSnapshot(
      transactionId: requireJsonString(
        json,
        'transaction_id',
        context,
        nonEmpty: true,
      ),
      ownedByAuthenticatedOperator: requireJsonBool(
        json,
        'owned_by_authenticated_operator',
        context,
      ),
      version: requireJsonNonnegativeInt(json, 'version', context),
      status: TransactionStatus.fromWireName(
        requireJsonString(json, 'status', context, nonEmpty: true),
      ),
      lineItems: rawLineItems
          .map(
            (item) => TransactionLineItem.fromJson(
              expectJsonObject(item, 'transaction line item'),
            ),
          )
          .toList(growable: false),
      subtotalMinorUnits: requireJsonNonnegativeInt(
        json,
        'subtotal_minor_units',
        context,
      ),
      taxMinorUnits: requireJsonNonnegativeInt(
        json,
        'tax_minor_units',
        context,
      ),
      totalMinorUnits: requireJsonNonnegativeInt(
        json,
        'total_minor_units',
        context,
      ),
      tenderedCashMinorUnits: requireJsonNullableNonnegativeInt(
        json,
        'tendered_cash_minor_units',
        context,
      ),
      changeDueMinorUnits: requireJsonNullableNonnegativeInt(
        json,
        'change_due_minor_units',
        context,
      ),
    );
  }
}
