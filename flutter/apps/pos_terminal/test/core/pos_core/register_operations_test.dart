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

  test('configured register context parses exact shift identity and epoch time', () {
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
  });

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
        'register': {
          'register_id': 'register-one',
          'display_name': 'Register',
        },
        'active_shift': null,
      }),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
  });
}
