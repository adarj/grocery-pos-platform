import 'json_fields.dart';

final class PosCoreHealth {
  const PosCoreHealth({
    required this.ok,
    required this.service,
    required this.version,
    required this.environment,
  });

  final bool ok;
  final String service;
  final String version;
  final String environment;

  factory PosCoreHealth.fromJson(Map<String, Object?> json) {
    const context = 'POS Core health response';
    return PosCoreHealth(
      ok: requireJsonBool(json, 'ok', context),
      service: requireJsonString(json, 'service', context, nonEmpty: true),
      version: requireJsonString(json, 'version', context, nonEmpty: true),
      environment: requireJsonString(
        json,
        'environment',
        context,
        nonEmpty: true,
      ),
    );
  }
}
