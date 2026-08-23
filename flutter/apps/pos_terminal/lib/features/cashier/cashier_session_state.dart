import '../../core/pos_core/models/command_result.dart';
import '../../core/pos_core/models/pos_core_failure.dart';
import '../../core/pos_core/models/transaction_command.dart';
import '../../core/pos_core/models/transaction_snapshot.dart';
import 'cashier_local_recovery_failure.dart';

enum CashierSessionActivity {
  idle,
  executingCommand,
  refreshingTransaction,
  preparingNextSale,
}

final class CashierSessionState {
  const CashierSessionState({
    this.activity = CashierSessionActivity.idle,
    this.activeTransactionId,
    this.snapshot,
    this.pendingCommand,
    this.lastCommandResult,
    this.failure,
    this.localRecoveryFailure,
  });

  static const initial = CashierSessionState();

  final CashierSessionActivity activity;
  final String? activeTransactionId;
  final TransactionSnapshot? snapshot;
  final TransactionCommand? pendingCommand;
  final PosCommandResult? lastCommandResult;
  final PosCoreFailure? failure;
  final CashierLocalRecoveryFailure? localRecoveryFailure;

  bool get isBusy => activity != CashierSessionActivity.idle;
  bool get hasActiveTransaction => activeTransactionId != null;
  bool get hasCurrentTransaction => snapshot != null;
  bool get hasPendingCommand => pendingCommand != null;
  bool get recoveryBlocked => localRecoveryFailure?.blocksSession ?? false;

  bool get canStartTransaction =>
      !isBusy &&
      !recoveryBlocked &&
      pendingCommand == null &&
      activeTransactionId == null &&
      snapshot == null;

  bool get canExecuteNewMutation =>
      !isBusy &&
      !recoveryBlocked &&
      pendingCommand == null &&
      snapshot != null &&
      activeTransactionId == snapshot!.transactionId;

  bool get canRetryPendingCommand =>
      !isBusy && !recoveryBlocked && pendingCommand != null;

  bool get canRefresh =>
      !isBusy &&
      !recoveryBlocked &&
      pendingCommand == null &&
      activeTransactionId != null;

  bool get canBeginNextSale =>
      canExecuteNewMutation &&
      (snapshot!.status == TransactionStatus.completed ||
          snapshot!.status == TransactionStatus.voided);
}
