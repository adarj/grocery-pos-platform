import 'json_fields.dart';

final class AuthenticatedOperatorSession {
  const AuthenticatedOperatorSession({
    required this.operatorId,
    required this.displayName,
    required this.role,
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
  final int idleTimeoutSeconds;
  final int absoluteExpiresAtEpochMs;
}

final class AuthenticationLogin {
  const AuthenticationLogin({required this.accessToken, required this.session});

  final String accessToken;
  final AuthenticatedOperatorSession session;
}
