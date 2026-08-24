import 'package:pos_terminal/core/pos_core/models/register_operations.dart';

mixin UnimplementedRegisterOperationsClient {
  Future<RegisterContext> fetchRegisterContext() => throw UnimplementedError();

  Future<List<CashierIdentity>> fetchActiveCashiers() =>
      throw UnimplementedError();

  Future<RegisterShift> openShift(String cashierId) =>
      throw UnimplementedError();

  Future<RegisterShift> closeShift(String shiftId) =>
      throw UnimplementedError();
}
