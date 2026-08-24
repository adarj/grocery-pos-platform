import 'json_fields.dart';
import 'pos_core_failure.dart';
import 'register_operations.dart';

final class CanonicalReceiptLine {
  const CanonicalReceiptLine({
    required this.barcode,
    required this.description,
    required this.unitPriceMinorUnits,
    required this.taxCategoryId,
    required this.taxRateMillionths,
    required this.taxAmountMinorUnits,
  });

  factory CanonicalReceiptLine.fromJson(Map<String, Object?> json) {
    const context = 'receipt line item';
    final categoryValue = requireJsonField(json, 'tax_category_id', context);
    final String? taxCategoryId;
    if (categoryValue == null) {
      taxCategoryId = null;
    } else if (categoryValue is String && categoryValue.isNotEmpty) {
      taxCategoryId = categoryValue;
    } else {
      throw const PosCoreInvalidResponseFailure(
        'Receipt line field tax_category_id must be null or a non-empty string.',
      );
    }

    final taxRateMillionths = requireJsonNullableNonnegativeInt(
      json,
      'tax_rate_millionths',
      context,
    );
    if (taxRateMillionths != null && taxRateMillionths > 1000000) {
      throw const PosCoreInvalidResponseFailure(
        'Receipt line field tax_rate_millionths must not exceed 1000000.',
      );
    }
    if ((taxCategoryId == null) != (taxRateMillionths == null)) {
      throw const PosCoreInvalidResponseFailure(
        'Receipt line tax category and rate must both be present or both be null.',
      );
    }

    return CanonicalReceiptLine(
      barcode: requireJsonString(json, 'barcode', context),
      description: requireJsonString(json, 'description', context),
      unitPriceMinorUnits: requireJsonNonnegativeInt(
        json,
        'unit_price_minor_units',
        context,
      ),
      taxCategoryId: taxCategoryId,
      taxRateMillionths: taxRateMillionths,
      taxAmountMinorUnits: requireJsonNonnegativeInt(
        json,
        'tax_amount_minor_units',
        context,
      ),
    );
  }

  final String barcode;
  final String description;
  final int unitPriceMinorUnits;
  final String? taxCategoryId;
  final int? taxRateMillionths;
  final int taxAmountMinorUnits;
}

final class CanonicalReceipt {
  CanonicalReceipt({
    required this.schemaVersion,
    required this.transactionId,
    required this.transactionVersion,
    required List<CanonicalReceiptLine> lineItems,
    required this.subtotalMinorUnits,
    required this.taxMinorUnits,
    required this.totalMinorUnits,
    required this.tenderedCashMinorUnits,
    required this.changeDueMinorUnits,
    this.register,
    this.cashier,
    this.shiftId,
    this.startedAtEpochMs,
    this.completedAtEpochMs,
  }) : lineItems = List.unmodifiable(lineItems);

  factory CanonicalReceipt.fromJson(Map<String, Object?> json) {
    const context = 'canonical receipt';
    final schemaVersion = requireJsonNonnegativeInt(
      json,
      'schema_version',
      context,
    );
    if (schemaVersion != 1 && schemaVersion != 2) {
      throw PosCoreInvalidResponseFailure(
        'Canonical receipt schema version $schemaVersion is unsupported.',
      );
    }

    final lineItems = requireJsonList(json, 'line_items', context)
        .map(
          (value) => CanonicalReceiptLine.fromJson(
            expectJsonObject(value, 'receipt line item'),
          ),
        )
        .toList(growable: false);

    RegisterIdentity? register;
    CashierIdentity? cashier;
    String? shiftId;
    int? startedAtEpochMs;
    int? completedAtEpochMs;
    if (schemaVersion == 2) {
      register = RegisterIdentity.fromJson(
        expectJsonObject(
          requireJsonField(json, 'register', context),
          'canonical receipt register',
        ),
      );
      cashier = CashierIdentity.fromJson(
        expectJsonObject(
          requireJsonField(json, 'cashier', context),
          'canonical receipt cashier',
        ),
      );
      shiftId = requireJsonString(
        json,
        'shift_id',
        context,
        nonEmpty: true,
      );
      startedAtEpochMs = requireJsonNonnegativeInt(
        json,
        'started_at_epoch_ms',
        context,
      );
      completedAtEpochMs = requireJsonNonnegativeInt(
        json,
        'completed_at_epoch_ms',
        context,
      );
      if (completedAtEpochMs < startedAtEpochMs) {
        throw const PosCoreInvalidResponseFailure(
          'Canonical receipt completion time cannot precede its start time.',
        );
      }
    } else {
      const v2OnlyFields = <String>{
        'register',
        'cashier',
        'shift_id',
        'started_at_epoch_ms',
        'completed_at_epoch_ms',
      };
      if (v2OnlyFields.any(json.containsKey)) {
        throw const PosCoreInvalidResponseFailure(
          'Canonical receipt Schema v1 cannot contain operational context.',
        );
      }
    }

    return CanonicalReceipt(
      schemaVersion: schemaVersion,
      transactionId: requireJsonString(
        json,
        'transaction_id',
        context,
        nonEmpty: true,
      ),
      transactionVersion: requireJsonNonnegativeInt(
        json,
        'transaction_version',
        context,
      ),
      lineItems: lineItems,
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
      tenderedCashMinorUnits: requireJsonNonnegativeInt(
        json,
        'tendered_cash_minor_units',
        context,
      ),
      changeDueMinorUnits: requireJsonNonnegativeInt(
        json,
        'change_due_minor_units',
        context,
      ),
      register: register,
      cashier: cashier,
      shiftId: shiftId,
      startedAtEpochMs: startedAtEpochMs,
      completedAtEpochMs: completedAtEpochMs,
    );
  }

  final int schemaVersion;
  final String transactionId;
  final int transactionVersion;
  final List<CanonicalReceiptLine> lineItems;
  final int subtotalMinorUnits;
  final int taxMinorUnits;
  final int totalMinorUnits;
  final int tenderedCashMinorUnits;
  final int changeDueMinorUnits;
  final RegisterIdentity? register;
  final CashierIdentity? cashier;
  final String? shiftId;
  final int? startedAtEpochMs;
  final int? completedAtEpochMs;
}
