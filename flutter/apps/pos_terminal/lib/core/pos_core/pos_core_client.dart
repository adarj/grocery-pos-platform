import 'models/command_result.dart';
import 'models/canonical_receipt.dart';
import 'models/pos_core_health.dart';
import 'models/transaction_command.dart';
import 'models/transaction_snapshot.dart';

abstract interface class PosCoreClient {
  Future<PosCoreHealth> fetchHealth();

  Future<PosCommandResult> executeCommand(TransactionCommand command);

  Future<TransactionSnapshot> fetchTransaction(String transactionId);

  Future<CanonicalReceipt> fetchReceipt(String transactionId);
}
