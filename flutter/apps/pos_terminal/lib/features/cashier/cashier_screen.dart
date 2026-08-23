import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/pos_core/models/command_result.dart';
import '../../core/pos_core/models/transaction_command.dart';
import '../../core/pos_core/models/transaction_snapshot.dart';
import 'cashier_money_format.dart';
import 'cashier_money_input.dart';
import 'cashier_session_controller.dart';
import 'cashier_session_state.dart';

enum _SubmittedAction { scan, tender, completion, removal, voidSale }

final class _FocusBarcodeIntent extends Intent {
  const _FocusBarcodeIntent();
}

final class _FocusCashIntent extends Intent {
  const _FocusCashIntent();
}

final ButtonStyle _primaryActionStyle = FilledButton.styleFrom(
  minimumSize: const Size(0, 56),
);

final class CashierScreen extends StatefulWidget {
  const CashierScreen({required this.controller, super.key});

  final CashierSessionController controller;

  @override
  State<CashierScreen> createState() => _CashierScreenState();
}

final class _CashierScreenState extends State<CashierScreen> {
  final TextEditingController _barcodeController = TextEditingController();
  final FocusNode _barcodeFocusNode = FocusNode();
  final TextEditingController _cashController = TextEditingController();
  final FocusNode _cashFocusNode = FocusNode();

  _SubmittedAction? _submittedAction;
  PosCommandResult? _lastCommandResultBeforeSubmission;
  String? _barcodeValidationMessage;
  String? _cashValidationMessage;
  String? _interactionFeedback;

  @override
  void initState() {
    super.initState();
    _requestBarcodeFocus();
  }

  @override
  void dispose() {
    _barcodeController.dispose();
    _barcodeFocusNode.dispose();
    _cashController.dispose();
    _cashFocusNode.dispose();
    super.dispose();
  }

  Future<void> _startSale() async {
    setState(() {
      _barcodeValidationMessage = null;
      _cashValidationMessage = null;
      _interactionFeedback = null;
    });
    await widget.controller.startTransaction();
    _requestBarcodeFocus();
  }

  Future<void> _submitBarcode(String barcode) async {
    final state = widget.controller.state;
    if (!state.canExecuteNewMutation) {
      return;
    }
    if (barcode.isEmpty) {
      setState(() => _barcodeValidationMessage = 'Enter a barcode.');
      return;
    }

    setState(() {
      _submittedAction = _SubmittedAction.scan;
      _lastCommandResultBeforeSubmission = state.lastCommandResult;
      _barcodeValidationMessage = null;
      _interactionFeedback = null;
    });
    await widget.controller.scanBarcode(barcode);
    _restoreInputWorkflowAfterResolution();
  }

  Future<void> _submitTender(String input) async {
    final state = widget.controller.state;
    if (!state.canExecuteNewMutation) {
      return;
    }

    if (input.trim().isEmpty) {
      setState(() => _cashValidationMessage = 'Enter cash received.');
      return;
    }
    final amountMinorUnits = parseCashInputMinorUnits(input);
    if (amountMinorUnits == null) {
      setState(() => _cashValidationMessage = 'Enter a valid cash amount.');
      return;
    }

    setState(() {
      _submittedAction = _SubmittedAction.tender;
      _lastCommandResultBeforeSubmission = state.lastCommandResult;
      _cashValidationMessage = null;
      _interactionFeedback = null;
    });
    await widget.controller.tenderCash(amountMinorUnits);
    _restoreInputWorkflowAfterResolution();
  }

  Future<void> _completeSale() async {
    final state = widget.controller.state;
    if (!state.canExecuteNewMutation) {
      return;
    }

    setState(() {
      _submittedAction = _SubmittedAction.completion;
      _lastCommandResultBeforeSubmission = state.lastCommandResult;
      _interactionFeedback = null;
    });
    await widget.controller.completeTransaction();
    _restoreInputWorkflowAfterResolution();
  }

  Future<void> _confirmRemoveLine(
    TransactionSnapshot sourceSnapshot,
    int lineIndex,
  ) async {
    final lineItem = sourceSnapshot.lineItems[lineIndex];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove item?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(lineItem.description),
            const SizedBox(height: 8),
            Text(formatUsdMinorUnits(lineItem.unitPriceMinorUnits)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove Item'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }

    final currentState = widget.controller.state;
    if (!identical(currentState.snapshot, sourceSnapshot) ||
        !currentState.canExecuteNewMutation) {
      setState(() {
        _interactionFeedback = 'Transaction changed. Select the item again.';
      });
      return;
    }

    setState(() {
      _submittedAction = _SubmittedAction.removal;
      _lastCommandResultBeforeSubmission = currentState.lastCommandResult;
      _interactionFeedback = null;
    });
    await widget.controller.removeLineItem(lineIndex);
    _restoreInputWorkflowAfterResolution();
  }

  Future<void> _confirmVoidSale(TransactionSnapshot sourceSnapshot) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void this sale?'),
        content: const Text(
          'This cancels the current open transaction. '
          'No payment will be taken.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep Sale'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Void Sale'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }

    final currentState = widget.controller.state;
    if (!identical(currentState.snapshot, sourceSnapshot) ||
        !currentState.canExecuteNewMutation) {
      setState(() {
        _interactionFeedback =
            'Transaction changed. Review the sale and try again.';
      });
      return;
    }

    setState(() {
      _submittedAction = _SubmittedAction.voidSale;
      _lastCommandResultBeforeSubmission = currentState.lastCommandResult;
      _interactionFeedback = null;
    });
    await widget.controller.voidTransaction();
    _restoreInputWorkflowAfterResolution();
  }

  Future<void> _retryPendingCommand() async {
    final pendingCommand = widget.controller.state.pendingCommand;
    if (pendingCommand != null && _submittedAction == null) {
      _lastCommandResultBeforeSubmission =
          widget.controller.state.lastCommandResult;
      _restorePendingInputContext(pendingCommand);
    }
    final action = _submittedAction;
    await widget.controller.retryPendingCommand();
    _restoreInputWorkflowAfterResolution();
    if (action == null) {
      _requestBarcodeFocus();
    }
  }

  Future<void> _refreshTransaction() async {
    await widget.controller.refreshTransaction();
    final state = widget.controller.state;
    if (!mounted || state.snapshot == null) {
      return;
    }
    final action = _submittedAction;
    _restoreInputWorkflowAfterResolution();
    if (action == null) {
      _requestBarcodeFocus();
    }
  }

  Future<void> _beginNextSale() async {
    setState(() => _interactionFeedback = null);
    await widget.controller.beginNextSale();
    _requestBarcodeFocus();
  }

  void _restorePendingInputContext(TransactionCommand command) {
    switch (command) {
      case ScanBarcodeCommand():
        _submittedAction = _SubmittedAction.scan;
        if (_barcodeController.text.isEmpty) {
          _barcodeController.text = command.barcode;
        }
      case TenderCashCommand():
        _submittedAction = _SubmittedAction.tender;
        if (_cashController.text.isEmpty) {
          final dollars = command.amountMinorUnits ~/ 100;
          final cents = (command.amountMinorUnits % 100).toString().padLeft(
            2,
            '0',
          );
          _cashController.text = '$dollars.$cents';
        }
      case CompleteTransactionCommand():
        _submittedAction = _SubmittedAction.completion;
      case RemoveLineItemCommand():
        _submittedAction = _SubmittedAction.removal;
      case VoidTransactionCommand():
        _submittedAction = _SubmittedAction.voidSale;
      case StartTransactionCommand():
        break;
    }
  }

  void _restoreInputWorkflowAfterResolution() {
    if (!mounted) {
      return;
    }
    final state = widget.controller.state;
    final snapshot = state.snapshot;
    final action = _submittedAction;
    if (state.pendingCommand != null || snapshot == null || action == null) {
      return;
    }

    final result = state.lastCommandResult;
    final hasNewCommandResult =
        result != null &&
        !identical(result, _lastCommandResultBeforeSubmission);
    final accepted = hasNewCommandResult && result.accepted;
    switch (action) {
      case _SubmittedAction.scan:
        if (accepted) {
          _barcodeController.clear();
        } else if (snapshot.status == TransactionStatus.open) {
          _selectTextAndFocus(_barcodeController, _barcodeFocusNode);
        }
        if (accepted) {
          _requestBarcodeFocus();
        }
      case _SubmittedAction.tender:
        if (accepted && snapshot.status != TransactionStatus.open) {
          _cashController.clear();
        } else if (snapshot.status == TransactionStatus.open) {
          _selectTextAndFocus(_cashController, _cashFocusNode);
        }
      case _SubmittedAction.completion:
        break;
      case _SubmittedAction.removal:
        if (snapshot.status == TransactionStatus.open) {
          _requestBarcodeFocus();
        }
      case _SubmittedAction.voidSale:
        if (!accepted && snapshot.status == TransactionStatus.open) {
          _requestBarcodeFocus();
        }
    }
    _submittedAction = null;
    _lastCommandResultBeforeSubmission = null;
  }

  void _selectTextAndFocus(
    TextEditingController controller,
    FocusNode focusNode,
  ) {
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _canFocusOpenInputs) {
        focusNode.requestFocus();
      }
    });
  }

  void _requestBarcodeFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _canFocusOpenInputs) {
        _barcodeFocusNode.requestFocus();
      }
    });
  }

  bool get _canFocusOpenInputs {
    final state = widget.controller.state;
    return state.canExecuteNewMutation &&
        state.snapshot?.status == TransactionStatus.open;
  }

  Object? _focusBarcode(_FocusBarcodeIntent intent) {
    if (_canFocusOpenInputs) {
      _barcodeFocusNode.requestFocus();
    }
    return null;
  }

  Object? _focusCash(_FocusCashIntent intent) {
    if (_canFocusOpenInputs) {
      _cashFocusNode.requestFocus();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.f2): _FocusBarcodeIntent(),
        SingleActivator(LogicalKeyboardKey.f4): _FocusCashIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _FocusBarcodeIntent: CallbackAction<_FocusBarcodeIntent>(
            onInvoke: _focusBarcode,
          ),
          _FocusCashIntent: CallbackAction<_FocusCashIntent>(
            onInvoke: _focusCash,
          ),
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('Grocery POS')),
          body: SafeArea(
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final state = widget.controller.state;
                final localRecoveryFailure = state.localRecoveryFailure;
                if (localRecoveryFailure?.blocksSession ?? false) {
                  return _RecoveryView(
                    icon: Icons.warning_amber_outlined,
                    title: 'Register recovery required',
                    message: localRecoveryFailure!.message,
                  );
                }
                if (state.pendingCommand != null) {
                  return _RecoveryView(
                    icon: Icons.help_outline,
                    title: 'Command result unknown',
                    message:
                        'POS Core could not confirm whether the last action '
                        'completed. Retry the same command to safely resolve it.',
                    action: FilledButton.icon(
                      style: _primaryActionStyle,
                      onPressed: state.canRetryPendingCommand
                          ? _retryPendingCommand
                          : null,
                      icon: const Icon(Icons.replay),
                      label: const Text('Retry Command'),
                    ),
                    showProgress: state.isBusy,
                  );
                }

                final snapshot = state.snapshot;
                if (snapshot != null) {
                  return _ActiveTransactionView(
                    state: state,
                    snapshot: snapshot,
                    barcodeController: _barcodeController,
                    barcodeFocusNode: _barcodeFocusNode,
                    cashController: _cashController,
                    cashFocusNode: _cashFocusNode,
                    barcodeValidationMessage: _barcodeValidationMessage,
                    cashValidationMessage: _cashValidationMessage,
                    feedback:
                        localRecoveryFailure?.message ??
                        _interactionFeedback ??
                        _resultFeedback(state.lastCommandResult),
                    onScan: () => _submitBarcode(_barcodeController.text),
                    onBarcodeSubmitted: _submitBarcode,
                    onTender: () => _submitTender(_cashController.text),
                    onCashSubmitted: _submitTender,
                    onComplete: _completeSale,
                    onRemove: _confirmRemoveLine,
                    onVoid: _confirmVoidSale,
                    onNextSale: _beginNextSale,
                  );
                }

                if (state.isBusy) {
                  final message = switch (state.activity) {
                    CashierSessionActivity.executingCommand =>
                      switch (_submittedAction) {
                        null => 'Starting sale...',
                        _SubmittedAction.scan => 'Processing item...',
                        _SubmittedAction.tender => 'Taking cash...',
                        _SubmittedAction.completion => 'Completing sale...',
                        _SubmittedAction.removal => 'Removing item...',
                        _SubmittedAction.voidSale => 'Voiding sale...',
                      },
                    CashierSessionActivity.refreshingTransaction =>
                      'Loading latest transaction state...',
                    CashierSessionActivity.preparingNextSale =>
                      'Preparing the next sale...',
                    CashierSessionActivity.idle => 'Working...',
                  };
                  return _ProgressView(message: message);
                }

                if (state.activeTransactionId != null) {
                  return _RecoveryView(
                    icon: Icons.sync_problem_outlined,
                    title: 'Transaction state unavailable',
                    message:
                        'The last command was resolved, but the latest transaction '
                        'state could not be loaded.',
                    detail: state.failure?.message,
                    action: FilledButton.icon(
                      style: _primaryActionStyle,
                      onPressed: state.canRefresh ? _refreshTransaction : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh Transaction'),
                    ),
                  );
                }

                return _NoTransactionView(
                  state: state,
                  feedback:
                      localRecoveryFailure?.message ??
                      _resultFeedback(state.lastCommandResult),
                  onStart: state.canStartTransaction ? _startSale : null,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

String? _resultFeedback(PosCommandResult? result) {
  if (result == null || result.accepted) {
    return null;
  }

  return switch (result.outcomeCode) {
    'unknown_barcode' => 'Item not found.',
    'insufficient_tender' => 'Cash received is less than the amount due.',
    'empty_transaction' => 'Scan at least one item before taking payment.',
    'line_item_not_found' =>
      'Item could not be removed. Latest transaction state loaded.',
    'invalid_transaction_state' =>
      'That action is no longer valid. Latest state loaded.',
    'stale_expected_version' ||
    'stream_version_conflict' => 'Transaction changed. Latest state loaded.',
    'transaction_already_exists' => 'Could not start sale. Please try again.',
    'transaction_not_found' => 'Transaction not found.',
    _ => 'Action could not be completed.',
  };
}

String _transactionStatusLabel(TransactionStatus status) {
  return switch (status) {
    TransactionStatus.open => 'Open',
    TransactionStatus.paid => 'Paid',
    TransactionStatus.completed => 'Completed',
    TransactionStatus.voided => 'Voided',
  };
}

final class _NoTransactionView extends StatelessWidget {
  const _NoTransactionView({
    required this.state,
    required this.feedback,
    required this.onStart,
  });

  final CashierSessionState state;
  final String? feedback;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final failure = state.failure;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.point_of_sale, size: 64),
                  const SizedBox(height: 20),
                  Semantics(
                    container: true,
                    header: true,
                    child: Text(
                      failure == null
                          ? 'Ready for the next sale'
                          : 'POS Core request failed.',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (feedback != null) ...[
                    const SizedBox(height: 12),
                    Text(feedback!, textAlign: TextAlign.center),
                  ],
                  if (failure != null) ...[
                    const SizedBox(height: 12),
                    Text(failure.message, textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    style: _primaryActionStyle,
                    onPressed: onStart,
                    icon: const Icon(Icons.add_shopping_cart),
                    label: const Text('Start Sale'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ProgressView extends StatelessWidget {
  const _ProgressView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          Text(message, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

final class _RecoveryView extends StatelessWidget {
  const _RecoveryView({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.detail,
    this.showProgress = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? detail;
  final Widget? action;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 56),
                  const SizedBox(height: 16),
                  Semantics(
                    container: true,
                    header: true,
                    label: title,
                    excludeSemantics: true,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(message, textAlign: TextAlign.center),
                  if (detail != null) ...[
                    const SizedBox(height: 8),
                    Text(detail!, textAlign: TextAlign.center),
                  ],
                  if (action != null) ...[const SizedBox(height: 24), action!],
                  if (showProgress) ...[
                    const SizedBox(height: 20),
                    const CircularProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ActiveTransactionView extends StatelessWidget {
  const _ActiveTransactionView({
    required this.state,
    required this.snapshot,
    required this.barcodeController,
    required this.barcodeFocusNode,
    required this.cashController,
    required this.cashFocusNode,
    required this.barcodeValidationMessage,
    required this.cashValidationMessage,
    required this.feedback,
    required this.onScan,
    required this.onBarcodeSubmitted,
    required this.onTender,
    required this.onCashSubmitted,
    required this.onComplete,
    required this.onRemove,
    required this.onVoid,
    required this.onNextSale,
  });

  final CashierSessionState state;
  final TransactionSnapshot snapshot;
  final TextEditingController barcodeController;
  final FocusNode barcodeFocusNode;
  final TextEditingController cashController;
  final FocusNode cashFocusNode;
  final String? barcodeValidationMessage;
  final String? cashValidationMessage;
  final String? feedback;
  final VoidCallback onScan;
  final ValueChanged<String> onBarcodeSubmitted;
  final VoidCallback onTender;
  final ValueChanged<String> onCashSubmitted;
  final VoidCallback onComplete;
  final Future<void> Function(TransactionSnapshot snapshot, int lineIndex)
  onRemove;
  final Future<void> Function(TransactionSnapshot snapshot) onVoid;
  final VoidCallback onNextSale;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final basket = _BasketPanel(
          snapshot: snapshot,
          compact: !wide,
          onRemove:
              snapshot.status == TransactionStatus.open &&
                  state.canExecuteNewMutation
              ? (lineIndex) => onRemove(snapshot, lineIndex)
              : null,
        );
        final controls = switch (snapshot.status) {
          TransactionStatus.open => _OpenTransactionControls(
            state: state,
            barcodeController: barcodeController,
            barcodeFocusNode: barcodeFocusNode,
            cashController: cashController,
            cashFocusNode: cashFocusNode,
            barcodeValidationMessage: barcodeValidationMessage,
            cashValidationMessage: cashValidationMessage,
            feedback: feedback,
            onScan: onScan,
            onBarcodeSubmitted: onBarcodeSubmitted,
            onTender: onTender,
            onCashSubmitted: onCashSubmitted,
            onVoid: state.canExecuteNewMutation ? () => onVoid(snapshot) : null,
          ),
          TransactionStatus.paid => _PaymentControls(
            snapshot: snapshot,
            feedback: feedback,
            onComplete: state.canExecuteNewMutation ? onComplete : null,
          ),
          TransactionStatus.completed => _PaymentControls(
            snapshot: snapshot,
            feedback: feedback,
            onNextSale: state.canBeginNextSale ? onNextSale : null,
          ),
          TransactionStatus.voided => _VoidedControls(
            snapshot: snapshot,
            feedback: feedback,
            onNextSale: state.canBeginNextSale ? onNextSale : null,
          ),
        };

        if (wide) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: basket),
                const SizedBox(width: 20),
                SizedBox(width: 360, child: controls),
              ],
            ),
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [controls, const SizedBox(height: 16), basket],
        );
      },
    );
  }
}

final class _BasketPanel extends StatelessWidget {
  const _BasketPanel({
    required this.snapshot,
    required this.compact,
    this.onRemove,
  });

  final TransactionSnapshot snapshot;
  final bool compact;
  final Future<void> Function(int lineIndex)? onRemove;

  @override
  Widget build(BuildContext context) {
    final lines = snapshot.lineItems.isEmpty
        ? const <Widget>[
            Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Center(child: Text('No items scanned yet.')),
            ),
          ]
        : snapshot.lineItems
              .asMap()
              .entries
              .map(
                (entry) => _BasketLineRow(
                  lineIndex: entry.key,
                  lineItem: entry.value,
                  onRemove: onRemove,
                ),
              )
              .toList(growable: false);

    final lineList = ListView(
      shrinkWrap: compact,
      physics: compact ? const NeverScrollableScrollPhysics() : null,
      children: lines,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Basket', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Semantics(
              container: true,
              label:
                  'Transaction status: '
                  '${_transactionStatusLabel(snapshot.status)}',
              excludeSemantics: true,
              child: Text(
                'Status: ${_transactionStatusLabel(snapshot.status)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ExcludeSemantics(
              child: Text(
                'Transaction version ${snapshot.version}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const Divider(height: 28),
            if (compact) lineList else Expanded(child: lineList),
            const Divider(height: 28),
            _MoneyRow(
              label: 'Subtotal',
              minorUnits: snapshot.subtotalMinorUnits,
            ),
            const SizedBox(height: 10),
            _MoneyRow(label: 'Tax', minorUnits: snapshot.taxMinorUnits),
            const SizedBox(height: 10),
            _MoneyRow(
              label: 'Total',
              minorUnits: snapshot.totalMinorUnits,
              prominent: true,
            ),
          ],
        ),
      ),
    );
  }
}

final class _BasketLineRow extends StatelessWidget {
  const _BasketLineRow({
    required this.lineIndex,
    required this.lineItem,
    required this.onRemove,
  });

  final int lineIndex;
  final TransactionLineItem lineItem;
  final Future<void> Function(int lineIndex)? onRemove;

  @override
  Widget build(BuildContext context) {
    final remove = onRemove;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    lineItem.description,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text('Barcode: ${lineItem.barcode}'),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  formatUsdMinorUnits(lineItem.unitPriceMinorUnits),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (remove != null)
                Semantics(
                  button: true,
                  label: 'Remove ${lineItem.description}',
                  excludeSemantics: true,
                  child: TextButton.icon(
                    key: Key('cashier-remove-line-$lineIndex'),
                    style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: () => remove(lineIndex),
                    icon: const Icon(Icons.remove_circle_outline),
                    label: const Text('Remove'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _MoneyRow extends StatelessWidget {
  const _MoneyRow({
    super.key,
    required this.label,
    required this.minorUnits,
    this.prominent = false,
    this.attention = false,
  });

  final String label;
  final int minorUnits;
  final bool prominent;
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = attention
        ? theme.textTheme.headlineMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          )
        : prominent
        ? theme.textTheme.headlineSmall
        : theme.textTheme.titleLarge;
    final formatted = formatUsdMinorUnits(minorUnits);
    return Semantics(
      container: true,
      label: '$label: $formatted',
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scaledText = MediaQuery.textScalerOf(context).scale(1);
            final stack = scaledText >= 1.5 && constraints.maxWidth < 420;
            if (stack) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(label, style: style),
                  const SizedBox(height: 4),
                  Text(formatted, style: style, textAlign: TextAlign.end),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: Text(label, style: style)),
                const SizedBox(width: 12),
                Text(formatted, style: style),
              ],
            );
          },
        ),
      ),
    );
  }
}

final class _OpenTransactionControls extends StatelessWidget {
  const _OpenTransactionControls({
    required this.state,
    required this.barcodeController,
    required this.barcodeFocusNode,
    required this.cashController,
    required this.cashFocusNode,
    required this.barcodeValidationMessage,
    required this.cashValidationMessage,
    required this.feedback,
    required this.onScan,
    required this.onBarcodeSubmitted,
    required this.onTender,
    required this.onCashSubmitted,
    required this.onVoid,
  });

  final CashierSessionState state;
  final TextEditingController barcodeController;
  final FocusNode barcodeFocusNode;
  final TextEditingController cashController;
  final FocusNode cashFocusNode;
  final String? barcodeValidationMessage;
  final String? cashValidationMessage;
  final String? feedback;
  final VoidCallback onScan;
  final ValueChanged<String> onBarcodeSubmitted;
  final VoidCallback onTender;
  final ValueChanged<String> onCashSubmitted;
  final VoidCallback? onVoid;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Cashier controls',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('cashier-barcode-field'),
              controller: barcodeController,
              focusNode: barcodeFocusNode,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              enabled: state.canExecuteNewMutation,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Barcode',
                hintText: 'Scan or enter a barcode',
                suffixText: 'F2',
                errorText: barcodeValidationMessage,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: state.canExecuteNewMutation
                  ? onBarcodeSubmitted
                  : null,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: _primaryActionStyle,
              onPressed: state.canExecuteNewMutation ? onScan : null,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan Item'),
            ),
            const Divider(height: 36),
            TextField(
              key: const Key('cashier-cash-field'),
              controller: cashController,
              focusNode: cashFocusNode,
              enabled: state.canExecuteNewMutation,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Cash received',
                hintText: '0.00',
                suffixText: 'F4',
                errorText: cashValidationMessage,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: state.canExecuteNewMutation ? onCashSubmitted : null,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: _primaryActionStyle,
              onPressed: state.canExecuteNewMutation ? onTender : null,
              icon: const Icon(Icons.payments_outlined),
              label: const Text('Take Cash'),
            ),
            if (feedback != null) ...[
              const SizedBox(height: 20),
              _FeedbackBanner(message: feedback!),
            ],
            const Divider(height: 36),
            OutlinedButton.icon(
              key: const Key('cashier-void-sale'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
              onPressed: onVoid,
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('Void Sale'),
            ),
          ],
        ),
      ),
    );
  }
}

final class _PaymentControls extends StatelessWidget {
  const _PaymentControls({
    required this.snapshot,
    required this.feedback,
    this.onComplete,
    this.onNextSale,
  });

  final TransactionSnapshot snapshot;
  final String? feedback;
  final VoidCallback? onComplete;
  final VoidCallback? onNextSale;

  @override
  Widget build(BuildContext context) {
    final completed = snapshot.status == TransactionStatus.completed;
    final tenderedCash = snapshot.tenderedCashMinorUnits;
    final changeDue = snapshot.changeDueMinorUnits;
    final paymentDetailsAvailable = tenderedCash != null && changeDue != null;

    return Card(
      key: const Key('cashier-payment-controls'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              completed ? Icons.check_circle : Icons.payments_outlined,
              size: 52,
            ),
            const SizedBox(height: 14),
            Semantics(
              container: true,
              header: true,
              child: Text(
                completed ? 'Sale Complete' : 'Payment accepted',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            _MoneyRow(
              label: 'Subtotal',
              minorUnits: snapshot.subtotalMinorUnits,
            ),
            const SizedBox(height: 12),
            _MoneyRow(label: 'Tax', minorUnits: snapshot.taxMinorUnits),
            const SizedBox(height: 12),
            _MoneyRow(label: 'Total', minorUnits: snapshot.totalMinorUnits),
            if (paymentDetailsAvailable) ...[
              const SizedBox(height: 12),
              _MoneyRow(label: 'Cash received', minorUnits: tenderedCash),
              const SizedBox(height: 12),
              _MoneyRow(
                key: const Key('cashier-change-due'),
                label: 'Change due',
                minorUnits: changeDue,
                attention: true,
              ),
            ] else ...[
              const SizedBox(height: 20),
              const Text(
                'Payment details unavailable',
                textAlign: TextAlign.center,
              ),
            ],
            if (!completed) ...[
              const SizedBox(height: 28),
              FilledButton.icon(
                style: _primaryActionStyle,
                onPressed: onComplete,
                icon: const Icon(Icons.done_all),
                label: const Text('Complete Sale'),
              ),
            ] else ...[
              const SizedBox(height: 28),
              FilledButton.icon(
                style: _primaryActionStyle,
                onPressed: onNextSale,
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text('Next Sale'),
              ),
            ],
            if (feedback != null) ...[
              const SizedBox(height: 20),
              _FeedbackBanner(message: feedback!),
            ],
          ],
        ),
      ),
    );
  }
}

final class _VoidedControls extends StatelessWidget {
  const _VoidedControls({
    required this.snapshot,
    required this.feedback,
    required this.onNextSale,
  });

  final TransactionSnapshot snapshot;
  final String? feedback;
  final VoidCallback? onNextSale;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('cashier-voided-controls'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.cancel_outlined, size: 52),
            const SizedBox(height: 14),
            Semantics(
              container: true,
              header: true,
              label: 'Transaction status: Voided',
              excludeSemantics: true,
              child: Text(
                'Sale Voided',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            _MoneyRow(
              label: 'Subtotal',
              minorUnits: snapshot.subtotalMinorUnits,
            ),
            const SizedBox(height: 12),
            _MoneyRow(label: 'Tax', minorUnits: snapshot.taxMinorUnits),
            const SizedBox(height: 12),
            _MoneyRow(
              label: 'Total',
              minorUnits: snapshot.totalMinorUnits,
              prominent: true,
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              style: _primaryActionStyle,
              onPressed: onNextSale,
              icon: const Icon(Icons.add_shopping_cart),
              label: const Text('Next Sale'),
            ),
            if (feedback != null) ...[
              const SizedBox(height: 20),
              _FeedbackBanner(message: feedback!),
            ],
          ],
        ),
      ),
    );
  }
}

final class _FeedbackBanner extends StatelessWidget {
  const _FeedbackBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
