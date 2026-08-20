import '../../core/pos_core/models/command_result.dart';
import '../../core/pos_core/models/pos_core_failure.dart';
import '../../core/pos_core/models/transaction_command.dart';
import '../../core/pos_core/models/transaction_snapshot.dart';

enum CashierSessionActivity { idle, executingCommand, refreshingTransaction }

final class CashierSessionState {
  const CashierSessionState({
    this.activity = CashierSessionActivity.idle,
    this.activeTransactionId,
    this.snapshot,
    this.pendingCommand,
    this.lastCommandResult,
    this.failure,
  });

  static const initial = CashierSessionState();

  final CashierSessionActivity activity;
  final String? activeTransactionId;
  final TransactionSnapshot? snapshot;
  final TransactionCommand? pendingCommand;
  final PosCommandResult? lastCommandResult;
  final PosCoreFailure? failure;

  bool get isBusy => activity != CashierSessionActivity.idle;
  bool get hasActiveTransaction => activeTransactionId != null;
  bool get hasCurrentTransaction => snapshot != null;
  bool get hasPendingCommand => pendingCommand != null;

  bool get canStartTransaction =>
      !isBusy &&
      pendingCommand == null &&
      activeTransactionId == null &&
      snapshot == null;

  bool get canExecuteNewMutation =>
      !isBusy &&
      pendingCommand == null &&
      snapshot != null &&
      activeTransactionId == snapshot!.transactionId;

  bool get canRetryPendingCommand => !isBusy && pendingCommand != null;

  bool get canRefresh =>
      !isBusy && pendingCommand == null && activeTransactionId != null;
}
