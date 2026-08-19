import 'pos_core_failure.dart';

Map<String, Object?> expectJsonObject(Object? value, String context) {
  if (value is Map<String, Object?>) {
    return value;
  }

  throw PosCoreInvalidResponseFailure('$context must be a JSON object.');
}

Object? requireJsonField(
  Map<String, Object?> json,
  String field,
  String context,
) {
  if (!json.containsKey(field)) {
    throw PosCoreInvalidResponseFailure(
      '$context is missing the required $field field.',
    );
  }

  return json[field];
}

String requireJsonString(
  Map<String, Object?> json,
  String field,
  String context, {
  bool nonEmpty = false,
}) {
  final value = requireJsonField(json, field, context);
  if (value is! String || (nonEmpty && value.isEmpty)) {
    throw PosCoreInvalidResponseFailure(
      '$context field $field must be ${nonEmpty ? 'a non-empty ' : 'a '}string.',
    );
  }

  return value;
}

bool requireJsonBool(Map<String, Object?> json, String field, String context) {
  final value = requireJsonField(json, field, context);
  if (value is! bool) {
    throw PosCoreInvalidResponseFailure(
      '$context field $field must be a boolean.',
    );
  }

  return value;
}

int requireJsonNonnegativeInt(
  Map<String, Object?> json,
  String field,
  String context,
) {
  final value = requireJsonField(json, field, context);
  if (value is! int || value < 0) {
    throw PosCoreInvalidResponseFailure(
      '$context field $field must be a nonnegative integer.',
    );
  }

  return value;
}

int? requireJsonNullableNonnegativeInt(
  Map<String, Object?> json,
  String field,
  String context,
) {
  final value = requireJsonField(json, field, context);
  if (value == null) {
    return null;
  }
  if (value is! int || value < 0) {
    throw PosCoreInvalidResponseFailure(
      '$context field $field must be null or a nonnegative integer.',
    );
  }

  return value;
}

List<Object?> requireJsonList(
  Map<String, Object?> json,
  String field,
  String context,
) {
  final value = requireJsonField(json, field, context);
  if (value is! List<Object?>) {
    throw PosCoreInvalidResponseFailure(
      '$context field $field must be a JSON array.',
    );
  }

  return value;
}
