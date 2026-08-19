sealed class PosCoreFailure implements Exception {
  const PosCoreFailure(this.message, {this.retrySameCommandId = false});

  final String message;
  final bool retrySameCommandId;

  @override
  String toString() => message;
}

final class PosCoreTransportFailure extends PosCoreFailure {
  const PosCoreTransportFailure(super.message, {super.retrySameCommandId});
}

final class PosCoreServerFailure extends PosCoreFailure {
  const PosCoreServerFailure({
    required this.code,
    required String message,
    this.reason,
    this.statusCode,
    bool retrySameCommandId = false,
  }) : super(message, retrySameCommandId: retrySameCommandId);

  final String code;
  final String? reason;
  final int? statusCode;
}

final class PosCoreInvalidResponseFailure extends PosCoreFailure {
  const PosCoreInvalidResponseFailure(
    super.message, {
    super.retrySameCommandId,
  });
}
