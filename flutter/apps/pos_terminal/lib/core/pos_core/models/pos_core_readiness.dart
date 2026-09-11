import 'json_fields.dart';
import 'pos_core_failure.dart';

enum PosCoreReadinessReason {
  runtimeStopped('runtime_stopped'),
  databaseMissing('database_missing'),
  databaseUnavailable('database_unavailable'),
  databaseSchemaNotCurrent('database_schema_not_current');

  const PosCoreReadinessReason(this.wireValue);

  final String wireValue;

  static PosCoreReadinessReason fromWireValue(String value) {
    for (final reason in values) {
      if (reason.wireValue == value) {
        return reason;
      }
    }
    throw PosCoreInvalidResponseFailure(
      'POS Core readiness response has an unsupported reason: $value.',
    );
  }
}

final class PosCoreReadiness {
  const PosCoreReadiness._({
    required this.ready,
    required this.service,
    required this.databaseSchemaVersion,
    required this.reason,
  });

  final bool ready;
  final String service;
  final int? databaseSchemaVersion;
  final PosCoreReadinessReason? reason;

  factory PosCoreReadiness.fromJson(Map<String, Object?> json) {
    const context = 'POS Core readiness response';
    final ok = requireJsonBool(json, 'ok', context);
    final service = requireJsonString(json, 'service', context, nonEmpty: true);
    final status = requireJsonString(json, 'status', context, nonEmpty: true);

    switch (status) {
      case 'ready':
        if (!ok || json.containsKey('reason')) {
          throw const PosCoreInvalidResponseFailure(
            'A ready POS Core response must have ok=true and no reason.',
          );
        }
        final schemaVersion = requireJsonNonnegativeInt(
          json,
          'database_schema_version',
          context,
        );
        if (schemaVersion == 0) {
          throw const PosCoreInvalidResponseFailure(
            'A ready POS Core response must report a positive schema version.',
          );
        }
        return PosCoreReadiness._(
          ready: true,
          service: service,
          databaseSchemaVersion: schemaVersion,
          reason: null,
        );
      case 'not_ready':
        if (ok || json.containsKey('database_schema_version')) {
          throw const PosCoreInvalidResponseFailure(
            'A not-ready POS Core response must have ok=false and no schema version.',
          );
        }
        return PosCoreReadiness._(
          ready: false,
          service: service,
          databaseSchemaVersion: null,
          reason: PosCoreReadinessReason.fromWireValue(
            requireJsonString(json, 'reason', context, nonEmpty: true),
          ),
        );
      default:
        throw PosCoreInvalidResponseFailure(
          'POS Core readiness response has an unsupported status: $status.',
        );
    }
  }
}
