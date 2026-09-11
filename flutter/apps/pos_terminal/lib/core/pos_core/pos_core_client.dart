import 'models/command_result.dart';
import 'models/canonical_receipt.dart';
import 'models/pos_core_health.dart';
import 'models/pos_core_readiness.dart';
import 'models/register_operations.dart';
import 'models/transaction_command.dart';
import 'models/transaction_snapshot.dart';

abstract interface class PosCoreClient {
  Future<PosCoreHealth> fetchHealth();

  Future<PosCoreReadiness> fetchReadiness();

  Future<PosCommandResult> executeCommand(TransactionCommand command);

  Future<TransactionSnapshot> fetchTransaction(String transactionId);

  Future<CanonicalReceipt> fetchReceipt(String transactionId);

  Future<RegisterContext> fetchRegisterContext();

  Future<List<CashierIdentity>> fetchActiveCashiers();

  Future<ShiftOperationResult> openShift(
    String cashierId,
    int openingCashMinorUnits,
  );

  Future<ShiftOperationResult> closeShift(
    String shiftId,
    int countedCashMinorUnits,
  );

  Future<ShiftCashSummary> fetchShiftCashSummary(String shiftId);
}
