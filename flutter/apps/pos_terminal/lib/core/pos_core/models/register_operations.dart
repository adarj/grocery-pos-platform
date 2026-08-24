import 'json_fields.dart';
import 'pos_core_failure.dart';

final class RegisterIdentity {
  const RegisterIdentity({required this.registerId, required this.displayName});

  factory RegisterIdentity.fromJson(Map<String, Object?> json) {
    const context = 'register identity';
    return RegisterIdentity(
      registerId: requireJsonString(
        json,
        'register_id',
        context,
        nonEmpty: true,
      ),
      displayName: requireJsonString(
        json,
        'display_name',
        context,
        nonEmpty: true,
      ),
    );
  }

  final String registerId;
  final String displayName;
}

final class CashierIdentity {
  const CashierIdentity({required this.cashierId, required this.displayName});

  factory CashierIdentity.fromJson(Map<String, Object?> json) {
    const context = 'cashier identity';
    return CashierIdentity(
      cashierId: requireJsonString(json, 'cashier_id', context, nonEmpty: true),
      displayName: requireJsonString(
        json,
        'display_name',
        context,
        nonEmpty: true,
      ),
    );
  }

  final String cashierId;
  final String displayName;
}

final class RegisterShift {
  const RegisterShift({
    required this.shiftId,
    required this.registerId,
    required this.registerDisplayName,
    required this.cashierId,
    required this.cashierDisplayName,
    required this.openedAtEpochMs,
    required this.closedAtEpochMs,
    required this.activeTransactionId,
  });

  factory RegisterShift.fromJson(Map<String, Object?> json) {
    const context = 'register shift';
    final openedAt = requireJsonNonnegativeInt(
      json,
      'opened_at_epoch_ms',
      context,
    );
    final closedAt = requireJsonNullableNonnegativeInt(
      json,
      'closed_at_epoch_ms',
      context,
    );
    if (closedAt != null && closedAt < openedAt) {
      throw const PosCoreInvalidResponseFailure(
        'Register shift close time cannot precede its open time.',
      );
    }
    final activeValue = requireJsonField(
      json,
      'active_transaction_id',
      context,
    );
    final String? activeTransactionId;
    if (activeValue == null) {
      activeTransactionId = null;
    } else if (activeValue is String && activeValue.isNotEmpty) {
      activeTransactionId = activeValue;
    } else {
      throw const PosCoreInvalidResponseFailure(
        'Register shift active_transaction_id must be null or a non-empty string.',
      );
    }
    if (closedAt != null && activeTransactionId != null) {
      throw const PosCoreInvalidResponseFailure(
        'A closed register shift cannot retain an active transaction.',
      );
    }
    return RegisterShift(
      shiftId: requireJsonString(json, 'shift_id', context, nonEmpty: true),
      registerId: requireJsonString(
        json,
        'register_id',
        context,
        nonEmpty: true,
      ),
      registerDisplayName: requireJsonString(
        json,
        'register_display_name',
        context,
        nonEmpty: true,
      ),
      cashierId: requireJsonString(json, 'cashier_id', context, nonEmpty: true),
      cashierDisplayName: requireJsonString(
        json,
        'cashier_display_name',
        context,
        nonEmpty: true,
      ),
      openedAtEpochMs: openedAt,
      closedAtEpochMs: closedAt,
      activeTransactionId: activeTransactionId,
    );
  }

  final String shiftId;
  final String registerId;
  final String registerDisplayName;
  final String cashierId;
  final String cashierDisplayName;
  final int openedAtEpochMs;
  final int? closedAtEpochMs;
  final String? activeTransactionId;
}

final class RegisterContext {
  const RegisterContext({
    required this.configured,
    required this.register,
    required this.activeShift,
  });

  factory RegisterContext.fromJson(Map<String, Object?> json) {
    const context = 'register context';
    final configured = requireJsonBool(json, 'configured', context);
    final registerValue = requireJsonField(json, 'register', context);
    final register = registerValue == null
        ? null
        : RegisterIdentity.fromJson(
            expectJsonObject(registerValue, 'register context register'),
          );
    final shiftValue = requireJsonField(json, 'active_shift', context);
    final shift = shiftValue == null
        ? null
        : RegisterShift.fromJson(
            expectJsonObject(shiftValue, 'register context active_shift'),
          );
    if (configured != (register != null)) {
      throw const PosCoreInvalidResponseFailure(
        'Register context configured state and identity disagree.',
      );
    }
    if (!configured && shift != null) {
      throw const PosCoreInvalidResponseFailure(
        'An unconfigured register context cannot have an active shift.',
      );
    }
    if (register != null &&
        shift != null &&
        register.registerId != shift.registerId) {
      throw const PosCoreInvalidResponseFailure(
        'Register context shift identity disagrees with current register.',
      );
    }
    return RegisterContext(
      configured: configured,
      register: register,
      activeShift: shift,
    );
  }

  final bool configured;
  final RegisterIdentity? register;
  final RegisterShift? activeShift;
}

enum ShiftCashStatus { open, closed }

final class ShiftCashSummary {
  const ShiftCashSummary({
    required this.shiftId,
    required this.status,
    required this.openingCashMinorUnits,
    required this.completedCashSaleCount,
    required this.cashSalesMinorUnits,
    required this.expectedCashMinorUnits,
    required this.countedCashMinorUnits,
    required this.overShortMinorUnits,
  });

  factory ShiftCashSummary.fromJson(Map<String, Object?> json) {
    const context = 'shift cash summary';
    final statusValue = requireJsonString(json, 'status', context);
    final status = switch (statusValue) {
      'open' => ShiftCashStatus.open,
      'closed' => ShiftCashStatus.closed,
      _ => throw const PosCoreInvalidResponseFailure(
        'Shift cash summary status is unsupported.',
      ),
    };
    final counted = requireJsonNullableNonnegativeInt(
      json,
      'counted_cash_minor_units',
      context,
    );
    final overShortValue = requireJsonField(
      json,
      'over_short_minor_units',
      context,
    );
    final int? overShort;
    if (overShortValue == null) {
      overShort = null;
    } else if (overShortValue is int) {
      overShort = overShortValue;
    } else {
      throw const PosCoreInvalidResponseFailure(
        'Shift cash summary over_short_minor_units must be null or an exact integer.',
      );
    }
    if (status == ShiftCashStatus.open &&
        (counted != null || overShort != null)) {
      throw const PosCoreInvalidResponseFailure(
        'An open shift cash summary cannot contain reconciliation values.',
      );
    }
    if (status == ShiftCashStatus.closed &&
        (counted == null || overShort == null)) {
      throw const PosCoreInvalidResponseFailure(
        'A closed shift cash summary requires reconciliation values.',
      );
    }
    return ShiftCashSummary(
      shiftId: requireJsonString(json, 'shift_id', context, nonEmpty: true),
      status: status,
      openingCashMinorUnits: requireJsonNonnegativeInt(
        json,
        'opening_cash_minor_units',
        context,
      ),
      completedCashSaleCount: requireJsonNonnegativeInt(
        json,
        'completed_cash_sale_count',
        context,
      ),
      cashSalesMinorUnits: requireJsonNonnegativeInt(
        json,
        'cash_sales_minor_units',
        context,
      ),
      expectedCashMinorUnits: requireJsonNonnegativeInt(
        json,
        'expected_cash_minor_units',
        context,
      ),
      countedCashMinorUnits: counted,
      overShortMinorUnits: overShort,
    );
  }

  final String shiftId;
  final ShiftCashStatus status;
  final int openingCashMinorUnits;
  final int completedCashSaleCount;
  final int cashSalesMinorUnits;
  final int expectedCashMinorUnits;
  final int? countedCashMinorUnits;
  final int? overShortMinorUnits;
}

final class ShiftOperationResult {
  const ShiftOperationResult({required this.shift, required this.cashSummary});

  factory ShiftOperationResult.fromJson(Map<String, Object?> json) {
    const context = 'shift operation response';
    final shift = RegisterShift.fromJson(
      expectJsonObject(
        requireJsonField(json, 'shift', context),
        '$context shift',
      ),
    );
    final summary = ShiftCashSummary.fromJson(
      expectJsonObject(
        requireJsonField(json, 'cash_summary', context),
        '$context cash_summary',
      ),
    );
    if (shift.shiftId != summary.shiftId ||
        ((shift.closedAtEpochMs == null) !=
            (summary.status == ShiftCashStatus.open))) {
      throw const PosCoreInvalidResponseFailure(
        'Shift operation identity or lifecycle disagrees with its cash summary.',
      );
    }
    return ShiftOperationResult(shift: shift, cashSummary: summary);
  }

  final RegisterShift shift;
  final ShiftCashSummary cashSummary;
}
