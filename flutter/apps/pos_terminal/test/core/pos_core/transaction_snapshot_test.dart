import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';

void main() {
  Map<String, Object?> snapshotJson({
    String status = 'open',
    Object? subtotal = 199,
    Object? tenderedCash,
    Object? changeDue,
  }) => {
    'transaction_id': 'txn-001',
    'version': 2,
    'status': status,
    'line_items': [
      {
        'barcode': '049000001234',
        'description': 'Test Apples',
        'unit_price_minor_units': 199,
      },
    ],
    'subtotal_minor_units': subtotal,
    'total_minor_units': 199,
    'tendered_cash_minor_units': tenderedCash,
    'change_due_minor_units': changeDue,
  };

  test('open transaction and line items parse exact integer money', () {
    final snapshot = TransactionSnapshot.fromJson(snapshotJson());

    expect(snapshot.transactionId, 'txn-001');
    expect(snapshot.version, 2);
    expect(snapshot.status, TransactionStatus.open);
    expect(snapshot.lineItems, hasLength(1));
    expect(snapshot.lineItems.single.barcode, '049000001234');
    expect(snapshot.lineItems.single.description, 'Test Apples');
    expect(snapshot.lineItems.single.unitPriceMinorUnits, 199);
    expect(snapshot.subtotalMinorUnits, 199);
    expect(snapshot.totalMinorUnits, 199);
    expect(snapshot.tenderedCashMinorUnits, isNull);
    expect(snapshot.changeDueMinorUnits, isNull);
  });

  test('paid and completed transaction statuses parse explicitly', () {
    final paid = TransactionSnapshot.fromJson(
      snapshotJson(status: 'paid', tenderedCash: 500, changeDue: 301),
    );
    final completed = TransactionSnapshot.fromJson(
      snapshotJson(status: 'completed', tenderedCash: 500, changeDue: 301),
    );

    expect(paid.status, TransactionStatus.paid);
    expect(completed.status, TransactionStatus.completed);
    expect(completed.tenderedCashMinorUnits, 500);
    expect(completed.changeDueMinorUnits, 301);
  });

  test('unknown status fails closed', () {
    expect(
      () => TransactionSnapshot.fromJson(snapshotJson(status: 'refunded')),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
  });

  test('floating-point and wrong-type authoritative money fail closed', () {
    for (final value in [199.0, '199', -1]) {
      expect(
        () => TransactionSnapshot.fromJson(snapshotJson(subtotal: value)),
        throwsA(isA<PosCoreInvalidResponseFailure>()),
      );
    }
  });

  test('missing authoritative fields fail closed', () {
    final missing = snapshotJson()..remove('total_minor_units');

    expect(
      () => TransactionSnapshot.fromJson(missing),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
  });
}
