import 'package:pos_terminal/core/pos_core/models/register_operations.dart';

mixin UnimplementedRegisterOperationsClient {
  Future<RegisterContext> fetchRegisterContext() => throw UnimplementedError();

  Future<List<CashierIdentity>> fetchActiveCashiers() =>
      throw UnimplementedError();

  Future<ShiftOperationResult> openShift(
    String cashierId,
    int openingCashMinorUnits,
  ) => throw UnimplementedError();

  Future<ShiftOperationResult> closeShift(
    String shiftId,
    int countedCashMinorUnits,
  ) => throw UnimplementedError();

  Future<ShiftCashSummary> fetchShiftCashSummary(String shiftId) =>
      throw UnimplementedError();
}
