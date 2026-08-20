import 'package:flutter/foundation.dart';

import '../../core/pos_core/models/command_result.dart';
import '../../core/pos_core/models/pos_core_failure.dart';
import '../../core/pos_core/models/transaction_command.dart';
import '../../core/pos_core/models/transaction_snapshot.dart';
import '../../core/pos_core/pos_core_client.dart';
import 'cashier_id_generator.dart';
import 'cashier_session_state.dart';

final class CashierSessionController extends ChangeNotifier {
  CashierSessionController({
    required PosCoreClient client,
    required CashierIdGenerator idGenerator,
  }) : _client = client,
       _idGenerator = idGenerator;

  final PosCoreClient _client;
  final CashierIdGenerator _idGenerator;

  CashierSessionState _state = CashierSessionState.initial;

  CashierSessionState get state => _state;

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

    await _executeCommand(command);
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
    await _executeCommand(command);
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
    await _executeCommand(command);
  }

  Future<void> completeTransaction() async {
    final snapshot = _requireAuthoritativeSnapshot();
    final command = CompleteTransactionCommand(
      commandId: _idGenerator.nextCommandId(),
      transactionId: snapshot.transactionId,
      expectedVersion: snapshot.version,
    );
    await _executeCommand(command);
  }

  Future<void> retryPendingCommand() async {
    _requireIdle();
    final command = _state.pendingCommand;
    if (command == null) {
      throw StateError('There is no pending transaction command to retry.');
    }

    await _executeCommand(command, pendingWhileExecuting: true);
  }

  Future<void> refreshTransaction() async {
    _requireIdle();
    if (_state.pendingCommand != null) {
      throw StateError(
        'The pending command must be resolved before refreshing state.',
      );
    }
    final transactionId = _state.activeTransactionId;
    if (transactionId == null) {
      throw StateError('There is no active transaction to refresh.');
    }

    await _refreshAuthoritativeTransaction(
      transactionId,
      lastCommandResult: _state.lastCommandResult,
    );
  }

  Future<void> _executeCommand(
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
      await _handleResolvedCommand(command, result);
    } on PosCoreFailure catch (failure) {
      _recordCommandFailure(command, failure);
    } catch (_) {
      _setState(
        CashierSessionState(activeTransactionId: command.transactionId),
      );
      rethrow;
    }
  }

  void _recordCommandFailure(
    TransactionCommand command,
    PosCoreFailure failure,
  ) {
    final requiresRetry = failure.retrySameCommandId;
    final keepTransactionId =
        requiresRetry || command is! StartTransactionCommand;
    _setState(
      CashierSessionState(
        activeTransactionId: keepTransactionId ? command.transactionId : null,
        pendingCommand: requiresRetry ? command : null,
        failure: failure,
      ),
    );
  }

  Future<void> _handleResolvedCommand(
    TransactionCommand command,
    PosCommandResult result,
  ) async {
    if (command is StartTransactionCommand) {
      if (result.outcomeKind != PosCommandOutcomeKind.accepted) {
        _setState(CashierSessionState(lastCommandResult: result));
        return;
      }

      await _refreshAuthoritativeTransaction(
        command.transactionId,
        lastCommandResult: result,
      );
      return;
    }

    if (result.outcomeKind == PosCommandOutcomeKind.notFound) {
      _setState(CashierSessionState(lastCommandResult: result));
      return;
    }

    await _refreshAuthoritativeTransaction(
      command.transactionId,
      lastCommandResult: result,
    );
  }

  Future<void> _refreshAuthoritativeTransaction(
    String transactionId, {
    required PosCommandResult? lastCommandResult,
  }) async {
    _setState(
      CashierSessionState(
        activity: CashierSessionActivity.refreshingTransaction,
        activeTransactionId: transactionId,
        lastCommandResult: lastCommandResult,
      ),
    );

    try {
      final snapshot = await _client.fetchTransaction(transactionId);
      _setState(
        CashierSessionState(
          activeTransactionId: transactionId,
          snapshot: snapshot,
          lastCommandResult: lastCommandResult,
        ),
      );
    } on PosCoreFailure catch (failure) {
      final explicitlyNotFound =
          failure is PosCoreServerFailure &&
          failure.code == 'transaction_not_found';
      _setState(
        CashierSessionState(
          activeTransactionId: explicitlyNotFound ? null : transactionId,
          lastCommandResult: lastCommandResult,
          failure: failure,
        ),
      );
    } catch (_) {
      _setState(
        CashierSessionState(
          activeTransactionId: transactionId,
          lastCommandResult: lastCommandResult,
        ),
      );
      rethrow;
    }
  }

  void _requireIdle() {
    if (_state.isBusy) {
      throw StateError('Another cashier operation is already in progress.');
    }
  }

  TransactionSnapshot _requireAuthoritativeSnapshot() {
    _requireIdle();
    if (_state.pendingCommand != null) {
      throw StateError(
        'The pending command must be resolved before a new mutation.',
      );
    }
    final snapshot = _state.snapshot;
    if (snapshot == null ||
        _state.activeTransactionId != snapshot.transactionId) {
      throw StateError(
        'A current authoritative transaction is required for this mutation.',
      );
    }
    return snapshot;
  }

  void _setState(CashierSessionState nextState) {
    _state = nextState;
    notifyListeners();
  }
}
