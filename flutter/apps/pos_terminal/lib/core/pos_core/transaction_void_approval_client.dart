import 'models/transaction_command.dart';
import 'models/command_result.dart';

/// A short-lived capability for one exact void command. Callers must not save it.
final class TransactionVoidApproval {
  const TransactionVoidApproval({
    required this.approvalToken,
    required this.expiresAtEpochMs,
    required this.approverOperatorId,
    required this.approverDisplayName,
  });

  final String approvalToken;
  final int expiresAtEpochMs;
  final String approverOperatorId;
  final String approverDisplayName;
}

abstract interface class TransactionVoidApprovalClient {
  Future<TransactionVoidApproval> requestTransactionVoidApproval(
    VoidTransactionCommand command,
    String approverOperatorId,
    String approverPin,
  );

  Future<PosCommandResult> executeApprovedVoid(
    VoidTransactionCommand command,
    String approvalToken,
  );
}
