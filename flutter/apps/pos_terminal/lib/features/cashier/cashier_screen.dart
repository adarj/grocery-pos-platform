import 'package:flutter/material.dart';

import '../../core/pos_core/models/command_result.dart';
import '../../core/pos_core/models/transaction_snapshot.dart';
import 'cashier_money_format.dart';
import 'cashier_session_controller.dart';
import 'cashier_session_state.dart';

final class CashierScreen extends StatefulWidget {
  const CashierScreen({required this.controller, super.key});

  final CashierSessionController controller;

  @override
  State<CashierScreen> createState() => _CashierScreenState();
}

final class _CashierScreenState extends State<CashierScreen> {
  final TextEditingController _barcodeController = TextEditingController();
  final FocusNode _barcodeFocusNode = FocusNode();

  String? _submittedBarcode;
  String? _validationMessage;

  @override
  void dispose() {
    _barcodeController.dispose();
    _barcodeFocusNode.dispose();
    super.dispose();
  }

  Future<void> _startSale() async {
    setState(() => _validationMessage = null);
    await widget.controller.startTransaction();
  }

  Future<void> _submitBarcode(String barcode) async {
    final state = widget.controller.state;
    if (!state.canExecuteNewMutation) {
      return;
    }
    if (barcode.isEmpty) {
      setState(() => _validationMessage = 'Enter a barcode.');
      return;
    }

    setState(() {
      _submittedBarcode = barcode;
      _validationMessage = null;
    });
    await widget.controller.scanBarcode(barcode);
    _restoreBarcodeWorkflowAfterResolution();
  }

  Future<void> _retryPendingCommand() async {
    await widget.controller.retryPendingCommand();
    _restoreBarcodeWorkflowAfterResolution();
  }

  Future<void> _refreshTransaction() async {
    await widget.controller.refreshTransaction();
    final state = widget.controller.state;
    if (!mounted || state.snapshot == null) {
      return;
    }
    if (_submittedBarcode != null &&
        state.lastCommandResult?.outcomeKind ==
            PosCommandOutcomeKind.accepted) {
      _barcodeController.clear();
      _submittedBarcode = null;
    }
    _requestBarcodeFocus();
  }

  void _restoreBarcodeWorkflowAfterResolution() {
    if (!mounted) {
      return;
    }
    final state = widget.controller.state;
    if (state.pendingCommand != null || state.snapshot == null) {
      return;
    }

    if (state.lastCommandResult?.outcomeKind ==
        PosCommandOutcomeKind.accepted) {
      _barcodeController.clear();
      _submittedBarcode = null;
    } else {
      _barcodeController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _barcodeController.text.length,
      );
    }
    _requestBarcodeFocus();
  }

  void _requestBarcodeFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.controller.state.snapshot != null) {
        _barcodeFocusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Grocery POS')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final state = widget.controller.state;
            if (state.pendingCommand != null) {
              return _RecoveryView(
                icon: Icons.help_outline,
                title: 'Command result unknown',
                message:
                    'POS Core could not confirm whether the last action '
                    'completed. Retry the same command to safely resolve it.',
                action: FilledButton.icon(
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
                validationMessage: _validationMessage,
                feedback: _resultFeedback(state.lastCommandResult),
                onScan: () => _submitBarcode(_barcodeController.text),
                onSubmitted: _submitBarcode,
              );
            }

            if (state.isBusy) {
              final message = switch (state.activity) {
                CashierSessionActivity.executingCommand =>
                  _submittedBarcode == null
                      ? 'Starting sale...'
                      : 'Processing item...',
                CashierSessionActivity.refreshingTransaction =>
                  'Loading latest transaction state...',
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
                  onPressed: state.canRefresh ? _refreshTransaction : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh Transaction'),
                ),
              );
            }

            return _NoTransactionView(
              state: state,
              feedback: _resultFeedback(state.lastCommandResult),
              onStart: state.canStartTransaction ? _startSale : null,
            );
          },
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
                  Text(
                    failure == null
                        ? 'Ready for the next sale'
                        : 'POS Core request failed.',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
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
    required this.action,
    this.detail,
    this.showProgress = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? detail;
  final Widget action;
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
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(message, textAlign: TextAlign.center),
                  if (detail != null) ...[
                    const SizedBox(height: 8),
                    Text(detail!, textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 24),
                  action,
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
    required this.validationMessage,
    required this.feedback,
    required this.onScan,
    required this.onSubmitted,
  });

  final CashierSessionState state;
  final TransactionSnapshot snapshot;
  final TextEditingController barcodeController;
  final FocusNode barcodeFocusNode;
  final String? validationMessage;
  final String? feedback;
  final VoidCallback onScan;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final basket = _BasketPanel(snapshot: snapshot, compact: !wide);
        final controls = _ScanControls(
          state: state,
          barcodeController: barcodeController,
          barcodeFocusNode: barcodeFocusNode,
          validationMessage: validationMessage,
          feedback: feedback,
          onScan: onScan,
          onSubmitted: onSubmitted,
        );

        if (wide) {
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: basket),
                const SizedBox(width: 20),
                SizedBox(width: 340, child: controls),
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
  const _BasketPanel({required this.snapshot, required this.compact});

  final TransactionSnapshot snapshot;
  final bool compact;

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
              .map(
                (lineItem) => ListTile(
                  title: Text(lineItem.description),
                  subtitle: Text('Barcode: ${lineItem.barcode}'),
                  trailing: Text(
                    formatUsdMinorUnits(lineItem.unitPriceMinorUnits),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
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
            Text(
              'Status: ${_transactionStatusLabel(snapshot.status)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              'Transaction version ${snapshot.version}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Divider(height: 28),
            if (compact) lineList else Expanded(child: lineList),
            const Divider(height: 28),
            _MoneyRow(
              label: 'Subtotal',
              minorUnits: snapshot.subtotalMinorUnits,
            ),
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

final class _MoneyRow extends StatelessWidget {
  const _MoneyRow({
    required this.label,
    required this.minorUnits,
    this.prominent = false,
  });

  final String label;
  final int minorUnits;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final style = prominent
        ? Theme.of(context).textTheme.headlineSmall
        : Theme.of(context).textTheme.titleLarge;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: style),
        Text(formatUsdMinorUnits(minorUnits), style: style),
      ],
    );
  }
}

final class _ScanControls extends StatelessWidget {
  const _ScanControls({
    required this.state,
    required this.barcodeController,
    required this.barcodeFocusNode,
    required this.validationMessage,
    required this.feedback,
    required this.onScan,
    required this.onSubmitted,
  });

  final CashierSessionState state;
  final TextEditingController barcodeController;
  final FocusNode barcodeFocusNode;
  final String? validationMessage;
  final String? feedback;
  final VoidCallback onScan;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
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
              autofocus: true,
              enabled: state.canExecuteNewMutation,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Barcode',
                hintText: 'Scan or enter a barcode',
                errorText: validationMessage,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: state.canExecuteNewMutation ? onSubmitted : null,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: state.canExecuteNewMutation ? onScan : null,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan Item'),
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
    return DecoratedBox(
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
    );
  }
}
