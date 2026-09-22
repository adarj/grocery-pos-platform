import 'json_fields.dart';
import 'pos_core_failure.dart';

enum OperatorPermission {
  registerRead('register.read'),
  cashierDirectoryRead('cashier_directory.read'),
  transactionReadOwn('transaction.read.own'),
  transactionReadAny('transaction.read.any'),
  transactionOperateOwn('transaction.operate.own'),
  receiptReadOwn('receipt.read.own'),
  receiptReadAny('receipt.read.any'),
  shiftOpenOwn('shift.open.own'),
  shiftCloseOwn('shift.close.own'),
  shiftCloseAny('shift.close.any'),
  shiftCashSummaryReadOwn('shift.cash_summary.read.own'),
  shiftCashSummaryReadAny('shift.cash_summary.read.any');

  const OperatorPermission(this.wireName);

  final String wireName;

  static OperatorPermission fromWireName(String value) {
    for (final permission in values) {
      if (permission.wireName == value) return permission;
    }
    throw const PosCoreInvalidResponseFailure(
      'Authenticated session contains an unsupported permission.',
    );
  }
}

final class AuthenticatedOperatorSession {
  const AuthenticatedOperatorSession({
    required this.operatorId,
    required this.displayName,
    required this.role,
    this.permissions = const <OperatorPermission>{},
    required this.idleTimeoutSeconds,
    required this.absoluteExpiresAtEpochMs,
  });

  factory AuthenticatedOperatorSession.fromJson(Map<String, Object?> json) {
    const context = 'authenticated operator session';
    return AuthenticatedOperatorSession(
      operatorId: requireJsonString(
        json,
        'operator_id',
        context,
        nonEmpty: true,
      ),
      displayName: requireJsonString(
        json,
        'display_name',
        context,
        nonEmpty: true,
      ),
      role: requireJsonString(json, 'role', context, nonEmpty: true),
      permissions: _parsePermissions(json, context),
      idleTimeoutSeconds: requireJsonNonnegativeInt(
        json,
        'idle_timeout_seconds',
        context,
      ),
      absoluteExpiresAtEpochMs: requireJsonNonnegativeInt(
        json,
        'absolute_expires_at_epoch_ms',
        context,
      ),
    );
  }

  final String operatorId;
  final String displayName;
  final String role;
  final Set<OperatorPermission> permissions;
  final int idleTimeoutSeconds;
  final int absoluteExpiresAtEpochMs;

  bool permits(OperatorPermission permission) => permissions.contains(permission);
}

Set<OperatorPermission> _parsePermissions(
  Map<String, Object?> json,
  String context,
) {
  final values = requireJsonList(json, 'permissions', context);
  final result = <OperatorPermission>{};
  for (final value in values) {
    if (value is! String || value.isEmpty) {
      throw const PosCoreInvalidResponseFailure(
        'Authenticated session permissions must be non-empty strings.',
      );
    }
    if (!result.add(OperatorPermission.fromWireName(value))) {
      throw const PosCoreInvalidResponseFailure(
        'Authenticated session permissions must not contain duplicates.',
      );
    }
  }
  return Set.unmodifiable(result);
}

final class AuthenticationLogin {
  const AuthenticationLogin({required this.accessToken, required this.session});

  final String accessToken;
  final AuthenticatedOperatorSession session;
}
