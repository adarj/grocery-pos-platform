import 'dart:math';

abstract interface class CashierIdGenerator {
  String nextCommandId();

  String nextTransactionId();
}

final class SecureCashierIdGenerator implements CashierIdGenerator {
  SecureCashierIdGenerator() : _random = Random.secure();

  final Random _random;

  @override
  String nextCommandId() => _nextId('cmd');

  @override
  String nextTransactionId() => _nextId('txn');

  String _nextId(String prefix) {
    final value = StringBuffer('${prefix}_');
    for (var index = 0; index < 16; index++) {
      value.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return value.toString();
  }
}
