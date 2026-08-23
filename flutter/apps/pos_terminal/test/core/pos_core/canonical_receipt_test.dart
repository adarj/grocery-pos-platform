import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/canonical_receipt.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';

void main() {
  Map<String, Object?> receiptJson({
    Object? schemaVersion = 1,
    Object? transactionId = 'txn-receipt',
    Object? transactionVersion = 6,
    Object? subtotal = 199,
    Object? tax = 777,
    Object? total = 1234,
    Object? cash = 2000,
    Object? change = 999,
    Object? category = 'development-standard',
    Object? rate = 100000,
    Object? lineTax = 20,
  }) => {
    'schema_version': schemaVersion,
    'transaction_id': transactionId,
    'transaction_version': transactionVersion,
    'line_items': [
      {
        'barcode': '049000001234',
        'description': 'Test Apples',
        'unit_price_minor_units': 199,
        'tax_category_id': category,
        'tax_rate_millionths': rate,
        'tax_amount_minor_units': lineTax,
      },
    ],
    'subtotal_minor_units': subtotal,
    'tax_minor_units': tax,
    'total_minor_units': total,
    'tendered_cash_minor_units': cash,
    'change_due_minor_units': change,
  };

  test('strict receipt parses exact authoritative sale-time fields', () {
    final receipt = CanonicalReceipt.fromJson(receiptJson());

    expect(receipt.schemaVersion, 1);
    expect(receipt.transactionId, 'txn-receipt');
    expect(receipt.transactionVersion, 6);
    expect(receipt.lineItems, hasLength(1));
    final line = receipt.lineItems.single;
    expect(line.barcode, '049000001234');
    expect(line.description, 'Test Apples');
    expect(line.unitPriceMinorUnits, 199);
    expect(line.taxCategoryId, 'development-standard');
    expect(line.taxRateMillionths, 100000);
    expect(line.taxAmountMinorUnits, 20);
    // These intentionally surprising values prove the client does not rebuild
    // receipt arithmetic from line or transaction fields.
    expect(receipt.subtotalMinorUnits, 199);
    expect(receipt.taxMinorUnits, 777);
    expect(receipt.totalMinorUnits, 1234);
    expect(receipt.tenderedCashMinorUnits, 2000);
    expect(receipt.changeDueMinorUnits, 999);
  });

  test('legacy line accepts paired null category/rate and zero tax', () {
    final receipt = CanonicalReceipt.fromJson(
      receiptJson(category: null, rate: null, lineTax: 0),
    );

    expect(receipt.lineItems.single.taxCategoryId, isNull);
    expect(receipt.lineItems.single.taxRateMillionths, isNull);
    expect(receipt.lineItems.single.taxAmountMinorUnits, 0);
  });

  test('unsupported schema and invalid identity/version fail closed', () {
    for (final json in [
      receiptJson(schemaVersion: 2),
      receiptJson(transactionId: ''),
      receiptJson(transactionVersion: -1),
      receiptJson(transactionVersion: 6.0),
    ]) {
      expect(
        () => CanonicalReceipt.fromJson(json),
        throwsA(isA<PosCoreInvalidResponseFailure>()),
      );
    }
  });

  test('missing and invalid line fields fail closed', () {
    final missingDescription = receiptJson();
    final missingLine = Map<String, Object?>.from(
      (missingDescription['line_items']! as List<Object?>).single!
          as Map<String, Object?>,
    )..remove('description');
    missingDescription['line_items'] = [missingLine];

    final negativeLineMoney = receiptJson();
    final negativeLine = Map<String, Object?>.from(
      (negativeLineMoney['line_items']! as List<Object?>).single!
          as Map<String, Object?>,
    )..['unit_price_minor_units'] = -1;
    negativeLineMoney['line_items'] = [negativeLine];

    for (final json in [missingDescription, negativeLineMoney]) {
      expect(
        () => CanonicalReceipt.fromJson(json),
        throwsA(isA<PosCoreInvalidResponseFailure>()),
      );
    }
  });

  test('receipt money rejects negative floating and string values', () {
    for (final value in [-1, 199.0, '199']) {
      expect(
        () => CanonicalReceipt.fromJson(receiptJson(total: value)),
        throwsA(isA<PosCoreInvalidResponseFailure>()),
      );
    }
  });

  test('tax rate range and category/rate pairing fail closed', () {
    for (final json in [
      receiptJson(rate: -1),
      receiptJson(rate: 1000001),
      receiptJson(rate: 100000.0),
      receiptJson(category: null, rate: 0),
      receiptJson(category: 'development-standard', rate: null),
    ]) {
      expect(
        () => CanonicalReceipt.fromJson(json),
        throwsA(isA<PosCoreInvalidResponseFailure>()),
      );
    }
  });
}
