import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/register_operations.dart';

void main() {
  Map<String, Object?> shiftJson({
    Object? opened = 1000,
    Object? closed,
    Object? activeTransaction,
  }) => {
    'shift_id': 'shift-one',
    'register_id': 'register-one',
    'register_display_name': 'Front Register',
    'cashier_id': 'cashier-one',
    'cashier_display_name': 'Alice',
    'opened_at_epoch_ms': opened,
    'closed_at_epoch_ms': closed,
    'active_transaction_id': activeTransaction,
  };

  test(
    'configured register context parses exact shift identity and epoch time',
    () {
      final context = RegisterContext.fromJson({
        'configured': true,
        'register': {
          'register_id': 'register-one',
          'display_name': 'Front Register',
        },
        'active_shift': shiftJson(activeTransaction: 'txn-one'),
      });
      expect(context.register!.registerId, 'register-one');
      expect(context.activeShift!.cashierDisplayName, 'Alice');
      expect(context.activeShift!.openedAtEpochMs, 1000);
      expect(context.activeShift!.activeTransactionId, 'txn-one');
    },
  );

  test('unconfigured context is a strict legitimate state', () {
    final context = RegisterContext.fromJson({
      'configured': false,
      'register': null,
      'active_shift': null,
    });
    expect(context.configured, isFalse);
    expect(context.register, isNull);
    expect(context.activeShift, isNull);
  });

  test('malformed timestamps and inconsistent context fail closed', () {
    for (final value in [-1, 1.5, '1000']) {
      expect(
        () => RegisterShift.fromJson(shiftJson(opened: value)),
        throwsA(isA<PosCoreInvalidResponseFailure>()),
      );
    }
    expect(
      () => RegisterShift.fromJson(shiftJson(opened: 1000, closed: 999)),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
    expect(
      () => RegisterContext.fromJson({
        'configured': false,
        'register': {'register_id': 'register-one', 'display_name': 'Register'},
        'active_shift': null,
      }),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
  });

  Map<String, Object?> cashSummaryJson({
    Object? status = 'open',
    Object? opening = 10000,
    Object? saleCount = 1,
    Object? sales = 1000,
    Object? expected = 77777,
    Object? counted,
    Object? overShort,
  }) => {
    'shift_id': 'shift-one',
    'status': status,
    'view': 'full',
    'opening_cash_minor_units': opening,
    'completed_cash_sale_count': saleCount,
    'cash_sales_minor_units': sales,
    'expected_cash_minor_units': expected,
    'counted_cash_minor_units': counted,
    'over_short_minor_units': overShort,
  };

  test(
    'cash summary preserves authoritative values without local arithmetic',
    () {
      final summary = ShiftCashSummary.fromJson(
        cashSummaryJson(status: 'closed', counted: 80000, overShort: -999),
      );
      expect(summary.openingCashMinorUnits, 10000);
      expect(summary.cashSalesMinorUnits, 1000);
      expect(summary.expectedCashMinorUnits, 77777);
      expect(summary.countedCashMinorUnits, 80000);
      expect(summary.overShortMinorUnits, -999);
    },
  );

  test('limited open summary rejects every financial field', () {
    final limited = ShiftCashSummary.fromJson({
      'shift_id': 'shift-one',
      'status': 'open',
      'view': 'limited',
    });
    expect(limited.view, ShiftCashSummaryView.limited);
    expect(limited.expectedCashMinorUnits, isNull);

    expect(
      () => ShiftCashSummary.fromJson({
        'shift_id': 'shift-one',
        'status': 'open',
        'view': 'limited',
        'expected_cash_minor_units': 77777,
      }),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
  });

  test(
    'cash summary accepts open nulls and signed closed variance strictly',
    () {
      final open = ShiftCashSummary.fromJson(cashSummaryJson());
      expect(open.status, ShiftCashStatus.open);
      expect(open.countedCashMinorUnits, isNull);
      expect(open.overShortMinorUnits, isNull);

      final closed = ShiftCashSummary.fromJson(
        cashSummaryJson(status: 'closed', counted: 9999, overShort: -1),
      );
      expect(closed.status, ShiftCashStatus.closed);
      expect(closed.overShortMinorUnits, -1);
    },
  );

  test('cash summary rejects malformed primitive and lifecycle shapes', () {
    for (final field in [
      'opening_cash_minor_units',
      'completed_cash_sale_count',
      'cash_sales_minor_units',
      'expected_cash_minor_units',
    ]) {
      for (final invalid in [-1, 1.5, '1']) {
        final json = cashSummaryJson()..[field] = invalid;
        expect(
          () => ShiftCashSummary.fromJson(json),
          throwsA(isA<PosCoreInvalidResponseFailure>()),
        );
      }
    }
    expect(
      () => ShiftCashSummary.fromJson(
        cashSummaryJson(status: 'open', counted: 1, overShort: 0),
      ),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
    expect(
      () => ShiftCashSummary.fromJson(
        cashSummaryJson(status: 'closed', counted: 1),
      ),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
    expect(
      () => ShiftCashSummary.fromJson(
        cashSummaryJson(status: 'closed', counted: 1, overShort: 1.5),
      ),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
  });
}
