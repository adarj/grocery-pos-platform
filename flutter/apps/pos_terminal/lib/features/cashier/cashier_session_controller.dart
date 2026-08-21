import 'package:flutter/foundation.dart';

import '../../core/pos_core/models/command_result.dart';
import '../../core/pos_core/models/pos_core_failure.dart';
import '../../core/pos_core/models/transaction_command.dart';
import '../../core/pos_core/models/transaction_snapshot.dart';
import '../../core/pos_core/pos_core_client.dart';
import 'cashier_id_generator.dart';
import 'cashier_local_recovery_failure.dart';
import 'cashier_session_state.dart';
import 'cashier_session_store.dart';

final class CashierSessionController extends ChangeNotifier {
  CashierSessionController({
    required PosCoreClient client,
    required CashierIdGenerator idGenerator,
    required CashierSessionStore sessionStore,
  }) : _client = client,
       _idGenerator = idGenerator,
       _sessionStore = sessionStore;

  final PosCoreClient _client;
  final CashierIdGenerator _idGenerator;
  final CashierSessionStore _sessionStore;

  CashierSessionState _state = CashierSessionState.initial;

  CashierSessionState get state => _state;

  Future<void> restoreLocalSession() async {
    _requireIdle();
    if (_state.activeTransactionId != null ||
        _state.snapshot != null ||
        _state.pendingCommand != null) {
      throw StateError('Cashier recovery can only be restored at startup.');
    }

    try {
      final persisted = await _sessionStore.load();
      if (persisted == null) {
        _setState(CashierSessionState.initial);
        return;
      }
      _setState(
        CashierSessionState(
          activeTransactionId: persisted.activeTransactionId,
          pendingCommand: persisted.pendingCommand,
        ),
      );
    } on CashierSessionStoreFailure catch (failure) {
      _setState(
        CashierSessionState(
          localRecoveryFailure: _blockingLocalFailure(failure),
        ),
      );
    }
  }

  Future<void> startTransaction() async {
    _requireIdle();
    if (!_state.canStartTransaction) {
      throw StateError(
        'A new transaction cannot start in the current cashier session.',
      );
    }

    final transactionId = _idGenerator.nextTransactionId();
    final commandId = _idGenerator.nextCommandId();
    final command = StartTransactionCommand(
      commandId: commandId,
      transactionId: transactionId,
      expectedVersion: 0,
    );

    await _persistAndExecuteNewCommand(command);
  }

  Future<void> scanBarcode(String barcode) async {
    final snapshot = _requireAuthoritativeSnapshot();
    if (barcode.isEmpty) {
      throw ArgumentError.value(barcode, 'barcode', 'must not be empty');
    }

    final command = ScanBarcodeCommand(
      commandId: _idGenerator.nextCommandId(),
      transactionId: snapshot.transactionId,
      expectedVersion: snapshot.version,
      barcode: barcode,
    );
    await _persistAndExecuteNewCommand(command);
  }

  Future<void> tenderCash(int amountMinorUnits) async {
    final snapshot = _requireAuthoritativeSnapshot();
    if (amountMinorUnits < 0) {
      throw ArgumentError.value(
        amountMinorUnits,
        'amountMinorUnits',
        'must be nonnegative',
      );
    }

    final command = TenderCashCommand(
      commandId: _idGenerator.nextCommandId(),
      transactionId: snapshot.transactionId,
      expectedVersion: snapshot.version,
      amountMinorUnits: amountMinorUnits,
    );
    await _persistAndExecuteNewCommand(command);
  }

  Future<void> completeTransaction() async {
    final snapshot = _requireAuthoritativeSnapshot();
    final command = CompleteTransactionCommand(
      commandId: _idGenerator.nextCommandId(),
      transactionId: snapshot.transactionId,
      expectedVersion: snapshot.version,
    );
    await _persistAndExecuteNewCommand(command);
  }

  Future<void> retryPendingCommand() async {
    _requireIdle();
    if (!_state.canRetryPendingCommand) {
      throw StateError('There is no pending transaction command to retry.');
    }
    await _executePersistedCommand(
      _state.pendingCommand!,
      pendingWhileExecuting: true,
    );
  }

  Future<void> refreshTransaction() async {
    _requireIdle();
    if (!_state.canRefresh) {
      throw StateError('There is no active transaction to refresh safely.');
    }
    await _refreshAuthoritativeTransaction(
      _state.activeTransactionId!,
      lastCommandResult: _state.lastCommandResult,
    );
  }

  Future<void> beginNextSale() async {
    _requireIdle();
    if (!_state.canBeginNextSale) {
      throw StateError(
        'The current cashier session is not ready to begin the next sale.',
      );
    }

    final completedState = _state;
    _setState(
      CashierSessionState(
        activity: CashierSessionActivity.preparingNextSale,
        activeTransactionId: completedState.activeTransactionId,
        snapshot: completedState.snapshot,
        lastCommandResult: completedState.lastCommandResult,
      ),
    );
    try {
      await _sessionStore.clear();
    } on CashierSessionStoreFailure {
      _setState(
        CashierSessionState(
          activeTransactionId: completedState.activeTransactionId,
          snapshot: completedState.snapshot,
          lastCommandResult: completedState.lastCommandResult,
          localRecoveryFailure:
              const CashierLocalRecoveryFailure.storageUnavailable(),
        ),
      );
      return;
    }

    _setState(CashierSessionState.initial);
    await startTransaction();
  }

  Future<void> _persistAndExecuteNewCommand(TransactionCommand command) async {
    final stateBeforeCommand = _state;
    _setState(
      CashierSessionState(
        activity: CashierSessionActivity.executingCommand,
        activeTransactionId: command.transactionId,
      ),
    );
    try {
      await _sessionStore.save(
        PersistedCashierSession(
          activeTransactionId: command.transactionId,
          pendingCommand: command,
        ),
      );
    } on CashierSessionStoreFailure {
      _setState(
        CashierSessionState(
          activeTransactionId: stateBeforeCommand.activeTransactionId,
          snapshot: stateBeforeCommand.snapshot,
          pendingCommand: stateBeforeCommand.pendingCommand,
          lastCommandResult: stateBeforeCommand.lastCommandResult,
          failure: stateBeforeCommand.failure,
          localRecoveryFailure:
              const CashierLocalRecoveryFailure.storageUnavailable(
                commandWasNotSent: true,
              ),
        ),
      );
      return;
    }

    await _executePersistedCommand(command);
  }

  Future<void> _executePersistedCommand(
    TransactionCommand command, {
    bool pendingWhileExecuting = false,
  }) async {
    _setState(
      CashierSessionState(
        activity: CashierSessionActivity.executingCommand,
        activeTransactionId: command.transactionId,
        pendingCommand: pendingWhileExecuting ? command : null,
      ),
    );

    try {
      final result = await _client.executeCommand(command);
      final cleanupFailure = await _recordKnownCommandResult(command, result);
      await _handleResolvedCommand(
        command,
        result,
        localRecoveryFailure: cleanupFailure,
      );
    } on PosCoreFailure catch (failure) {
      await _recordCommandFailure(command, failure);
    } catch (_) {
      _setState(
        CashierSessionState(
          activeTransactionId: command.transactionId,
          pendingCommand: command,
        ),
      );
      rethrow;
    }
  }

  Future<CashierLocalRecoveryFailure?> _recordKnownCommandResult(
    TransactionCommand command,
    PosCommandResult result,
  ) async {
    final shouldClearSession =
        (command is StartTransactionCommand &&
            result.outcomeKind != PosCommandOutcomeKind.accepted) ||
        (command is! StartTransactionCommand &&
            result.outcomeKind == PosCommandOutcomeKind.notFound);
    try {
      if (shouldClearSession) {
        await _sessionStore.clear();
      } else {
        await _sessionStore.save(
          PersistedCashierSession(activeTransactionId: command.transactionId),
        );
      }
      return null;
    } on CashierSessionStoreFailure {
      return const CashierLocalRecoveryFailure.storageUnavailable();
    }
  }

  Future<void> _recordCommandFailure(
    TransactionCommand command,
    PosCoreFailure failure,
  ) async {
    final requiresRetry = failure.retrySameCommandId;
    final keepTransactionId =
        requiresRetry || command is! StartTransactionCommand;
    CashierLocalRecoveryFailure? localFailure;
    if (!requiresRetry) {
      try {
        if (keepTransactionId) {
          await _sessionStore.save(
            PersistedCashierSession(activeTransactionId: command.transactionId),
          );
        } else {
          await _sessionStore.clear();
        }
      } on CashierSessionStoreFailure {
        localFailure = const CashierLocalRecoveryFailure.storageUnavailable();
      }
    }

    _setState(
      CashierSessionState(
        activeTransactionId: keepTransactionId ? command.transactionId : null,
        pendingCommand: requiresRetry ? command : null,
        failure: failure,
        localRecoveryFailure: localFailure,
      ),
    );
  }

  Future<void> _handleResolvedCommand(
    TransactionCommand command,
    PosCommandResult result, {
    CashierLocalRecoveryFailure? localRecoveryFailure,
  }) async {
    if (command is StartTransactionCommand) {
      if (result.outcomeKind != PosCommandOutcomeKind.accepted) {
        _setState(
          CashierSessionState(
            lastCommandResult: result,
            localRecoveryFailure: localRecoveryFailure,
          ),
        );
        return;
      }

      await _refreshAuthoritativeTransaction(
        command.transactionId,
        lastCommandResult: result,
        localRecoveryFailure: localRecoveryFailure,
      );
      return;
    }

    if (result.outcomeKind == PosCommandOutcomeKind.notFound) {
      _setState(
        CashierSessionState(
          lastCommandResult: result,
          localRecoveryFailure: localRecoveryFailure,
        ),
      );
      return;
    }

    await _refreshAuthoritativeTransaction(
      command.transactionId,
      lastCommandResult: result,
      localRecoveryFailure: localRecoveryFailure,
    );
  }

  Future<void> _refreshAuthoritativeTransaction(
    String transactionId, {
    required PosCommandResult? lastCommandResult,
    CashierLocalRecoveryFailure? localRecoveryFailure,
  }) async {
    _setState(
      CashierSessionState(
        activity: CashierSessionActivity.refreshingTransaction,
        activeTransactionId: transactionId,
        lastCommandResult: lastCommandResult,
        localRecoveryFailure: localRecoveryFailure,
      ),
    );

    try {
      final snapshot = await _client.fetchTransaction(transactionId);
      _setState(
        CashierSessionState(
          activeTransactionId: transactionId,
          snapshot: snapshot,
          lastCommandResult: lastCommandResult,
          localRecoveryFailure: localRecoveryFailure,
        ),
      );
    } on PosCoreFailure catch (failure) {
      final explicitlyNotFound =
          failure is PosCoreServerFailure &&
          failure.code == 'transaction_not_found';
      var storageFailure = localRecoveryFailure;
      if (explicitlyNotFound) {
        try {
          await _sessionStore.clear();
        } on CashierSessionStoreFailure {
          storageFailure =
              const CashierLocalRecoveryFailure.storageUnavailable();
        }
      }
      _setState(
        CashierSessionState(
          activeTransactionId: explicitlyNotFound ? null : transactionId,
          lastCommandResult: lastCommandResult,
          failure: failure,
          localRecoveryFailure: storageFailure,
        ),
      );
    } catch (_) {
      _setState(
        CashierSessionState(
          activeTransactionId: transactionId,
          lastCommandResult: lastCommandResult,
          localRecoveryFailure: localRecoveryFailure,
        ),
      );
      rethrow;
    }
  }

  CashierLocalRecoveryFailure _blockingLocalFailure(
    CashierSessionStoreFailure failure,
  ) {
    return switch (failure.kind) {
      CashierSessionStoreFailureKind.corruptData =>
        const CashierLocalRecoveryFailure.corruptState(),
      CashierSessionStoreFailureKind.storageUnavailable =>
        const CashierLocalRecoveryFailure.storageUnavailable(
          blocksSession: true,
        ),
    };
  }

  void _requireIdle() {
    if (_state.isBusy) {
      throw StateError('Another cashier operation is already in progress.');
    }
  }

  TransactionSnapshot _requireAuthoritativeSnapshot() {
    _requireIdle();
    if (!_state.canExecuteNewMutation) {
      throw StateError(
        'A current authoritative transaction is required for this mutation.',
      );
    }
    return _state.snapshot!;
  }

  void _setState(CashierSessionState nextState) {
    _state = nextState;
    notifyListeners();
  }
}
