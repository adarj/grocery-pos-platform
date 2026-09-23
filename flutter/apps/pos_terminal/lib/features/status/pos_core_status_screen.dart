import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money/money_format.dart';
import '../../core/money/money_input.dart';
import '../../core/pos_core/models/pos_core_failure.dart';
import '../../core/pos_core/models/authentication.dart';
import '../../core/pos_core/models/pos_core_health.dart';
import '../../core/pos_core/models/register_operations.dart';
import '../../core/pos_core/pos_core_client.dart';
import '../cashier/cashier_screen.dart';
import '../cashier/cashier_session_controller.dart';
import '../receipt/receipt_lookup_screen.dart';

final ButtonStyle _primaryStatusActionStyle = FilledButton.styleFrom(
  minimumSize: const Size(0, 56),
);
final ButtonStyle _secondaryStatusActionStyle = OutlinedButton.styleFrom(
  minimumSize: const Size(0, 56),
);

final class PosCoreStatusScreen extends StatefulWidget {
  const PosCoreStatusScreen({
    required this.client,
    required this.cashierController,
    required this.session,
    super.key,
  });

  final PosCoreClient client;
  final CashierSessionController cashierController;
  final AuthenticatedOperatorSession session;

  @override
  State<PosCoreStatusScreen> createState() => _PosCoreStatusScreenState();
}

final class _PosCoreStatusScreenState extends State<PosCoreStatusScreen> {
  late Future<_RegisterHomeData> _homeFuture;
  final TextEditingController _openingCashController = TextEditingController();
  bool _operationPending = false;
  String? _operationFeedback;
  String? _openingCashValidation;
  RegisterShift? _uncertainCloseShift;
  ShiftOperationResult? _closedResult;

  @override
  void initState() {
    super.initState();
    _homeFuture = _loadHome();
  }

  @override
  void dispose() {
    _openingCashController.dispose();
    super.dispose();
  }

  Future<_RegisterHomeData> _loadHome() async {
    final health = await widget.client.fetchHealth();
    if (!health.ok) {
      return _RegisterHomeData(
        health: health,
        context: null,
        cashSummary: null,
      );
    }
    final registerContext = await widget.client.fetchRegisterContext();
    await widget.cashierController.reconcileRecoveryOwnership(registerContext);
    ShiftCashSummary? cashSummary;
    final activeShift = registerContext.activeShift;
    final mayReadActiveSummary =
        activeShift != null &&
        (activeShift.cashierId == widget.session.operatorId ||
            widget.session.permits(OperatorPermission.shiftCashSummaryReadAny));
    if (mayReadActiveSummary) {
      cashSummary = await widget.client.fetchShiftCashSummary(
        activeShift.shiftId,
      );
    } else if (_uncertainCloseShift != null) {
      final recovered = await widget.client.fetchShiftCashSummary(
        _uncertainCloseShift!.shiftId,
      );
      if (recovered.status == ShiftCashStatus.closed) cashSummary = recovered;
    }
    return _RegisterHomeData(
      health: health,
      context: registerContext,
      cashSummary: cashSummary,
    );
  }

  void _refreshRegisterState() {
    setState(() {
      _operationFeedback = null;
      _homeFuture = _loadHome();
    });
  }

  Future<void> _openRegister() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => CashierScreen(
          controller: widget.cashierController,
          client: widget.client,
          requesterDisplayName: widget.session.displayName,
        ),
      ),
    );
    if (mounted) _refreshRegisterState();
  }

  void _openReceiptLookup() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ReceiptLookupScreen(client: widget.client),
      ),
    );
  }

  Future<void> _openShift() async {
    if (_operationPending) return;
    final openingCash = parseMoneyInputMinorUnits(_openingCashController.text);
    if (openingCash == null) {
      setState(() {
        _openingCashValidation = 'Enter a valid opening cash amount.';
      });
      return;
    }
    setState(() {
      _operationPending = true;
      _operationFeedback = null;
      _openingCashValidation = null;
    });
    try {
      await widget.client.openShift(openingCash);
      if (!mounted) return;
      setState(() {
        _operationPending = false;
        _openingCashController.clear();
        _homeFuture = _loadHome();
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _operationPending = false;
        _operationFeedback = _operationalFailureMessage(
          error,
          unknownOutcome:
              'Open Shift result could not be confirmed. Refresh Register State.',
        );
      });
    }
  }

  Future<void> _confirmCloseShift(RegisterShift shift) async {
    final countedCash = await showDialog<int>(
      context: context,
      builder: (context) => _CloseShiftDialog(shift: shift),
    );
    if (countedCash == null || !mounted || _operationPending) return;
    setState(() {
      _operationPending = true;
      _operationFeedback = null;
    });
    try {
      final result = await widget.client.closeShift(shift.shiftId, countedCash);
      if (!mounted) return;
      setState(() {
        _operationPending = false;
        _uncertainCloseShift = null;
        _closedResult = result;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _operationPending = false;
        if (error is! PosCoreServerFailure) _uncertainCloseShift = shift;
        _operationFeedback = _operationalFailureMessage(
          error,
          unknownOutcome:
              'Close Shift result could not be confirmed. Refresh Register State.',
        );
      });
    }
  }

  void _finishClosedShift() {
    setState(() {
      _closedResult = null;
      _uncertainCloseShift = null;
      _operationFeedback = null;
      _homeFuture = _loadHome();
    });
  }

  String _operationalFailureMessage(
    Object error, {
    required String unknownOutcome,
  }) {
    if (error is PosCoreServerFailure &&
        error.code == 'shift_has_active_transaction') {
      return 'Finish or void the active sale before closing the shift.';
    }
    if (error is PosCoreServerFailure && error.code == 'shift_already_open') {
      return 'A different cashier shift is already open. Refresh Register State.';
    }
    if (error is PosCoreServerFailure && error.code == 'cashier_inactive') {
      return 'That cashier is inactive. Refresh Register State.';
    }
    return unknownOutcome;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<_RegisterHomeData>(
          future: _homeFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _StatusLayout(
                title: 'Grocery POS Terminal',
                status: 'Connecting to POS Core...',
                detail: 'Loading register state.',
                icon: Icons.sync,
              );
            }
            if (snapshot.hasError) {
              return _StatusLayout(
                title: 'Grocery POS Terminal',
                status: 'POS Core Unavailable',
                detail: 'Check that POS Core is running, then retry.',
                icon: Icons.error_outline,
                actions: [
                  FilledButton.icon(
                    style: _primaryStatusActionStyle,
                    onPressed: _refreshRegisterState,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              );
            }
            final data = snapshot.data!;
            if (!data.health.ok) {
              return _StatusLayout(
                title: 'Grocery POS Terminal',
                status: 'POS Core Unavailable',
                detail: 'Health endpoint returned ok=false.',
                icon: Icons.warning_amber_outlined,
                actions: [
                  FilledButton.icon(
                    style: _primaryStatusActionStyle,
                    onPressed: _refreshRegisterState,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              );
            }
            return _buildOperationalHome(data);
          },
        ),
      ),
    );
  }

  Widget _buildOperationalHome(_RegisterHomeData data) {
    final completedClose = _closedResult;
    if (completedClose != null) {
      return _buildClosedShiftResult(
        completedClose.shift,
        completedClose.cashSummary,
      );
    }
    final registerContext = data.context!;
    if (!registerContext.configured) {
      return _StatusLayout(
        title: 'Grocery POS Terminal',
        status: 'Register configuration required',
        detail:
            'Activate register and cashier configuration with the operator CLI.',
        icon: Icons.settings_outlined,
        feedback: _operationFeedback,
        actions: [_lookupButton(), _refreshButton()],
      );
    }

    final shift = registerContext.activeShift;
    if (shift == null) {
      if (data.cashSummary?.status == ShiftCashStatus.closed &&
          _uncertainCloseShift != null) {
        return _buildClosedShiftResult(
          _uncertainCloseShift!,
          data.cashSummary!,
        );
      }
      return _StatusLayout(
        title: registerContext.register!.displayName,
        status: 'Open Shift',
        detail:
            'Operator: ${widget.session.displayName}\n'
            'Open your shift to begin cashier transactions.',
        icon: Icons.badge_outlined,
        feedback: _operationFeedback,
        body: Column(
          children: [
            TextField(
              key: const Key('opening-cash-input'),
              controller: _openingCashController,
              enabled: !_operationPending,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: 'Opening Cash',
                errorText: _openingCashValidation,
              ),
            ),
          ],
        ),
        actions: [
          FilledButton.icon(
            key: const Key('open-shift-button'),
            style: _primaryStatusActionStyle,
            onPressed: _operationPending ? null : _openShift,
            icon: const Icon(Icons.login),
            label: Text(_operationPending ? 'Opening...' : 'Open Shift'),
          ),
          _lookupButton(),
          _refreshButton(),
        ],
      );
    }

    final ownsShift = shift.cashierId == widget.session.operatorId;
    final mayCloseForeign = widget.session.permits(
      OperatorPermission.shiftCloseAny,
    );
    if (!ownsShift) {
      return _StatusLayout(
        title: shift.registerDisplayName,
        status: 'Register In Use',
        detail:
            'The active shift belongs to ${shift.cashierDisplayName}.\n'
            'Sign in as that operator to continue cashier work.',
        icon: Icons.person_off_outlined,
        feedback: _operationFeedback,
        actions: [
          if (mayCloseForeign)
            OutlinedButton.icon(
              style: _secondaryStatusActionStyle,
              onPressed: _operationPending
                  ? null
                  : () => _confirmCloseShift(shift),
              icon: const Icon(Icons.logout),
              label: const Text('Close Shift'),
            ),
          _refreshButton(),
        ],
      );
    }

    return _StatusLayout(
      title: shift.registerDisplayName,
      status: 'Shift Open',
      detail:
          'Cashier: ${shift.cashierDisplayName}\n'
          'Shift: ${shift.shiftId}\n'
          'Opened: ${_formatUtcEpochMs(shift.openedAtEpochMs)}',
      icon: Icons.point_of_sale,
      feedback: _operationFeedback,
      actions: [
        FilledButton.icon(
          style: _primaryStatusActionStyle,
          onPressed: _operationPending ? null : _openRegister,
          icon: const Icon(Icons.point_of_sale),
          label: const Text('Open Register'),
        ),
        _lookupButton(),
        OutlinedButton.icon(
          style: _secondaryStatusActionStyle,
          onPressed: _operationPending ? null : () => _confirmCloseShift(shift),
          icon: const Icon(Icons.logout),
          label: const Text('Close Shift'),
        ),
        _refreshButton(),
      ],
    );
  }

  Widget _buildClosedShiftResult(
    RegisterShift shift,
    ShiftCashSummary summary,
  ) {
    return _StatusLayout(
      title: shift.registerDisplayName,
      status: 'Shift Closed',
      detail: 'Cashier: ${shift.cashierDisplayName}\nShift: ${shift.shiftId}',
      icon: Icons.fact_check_outlined,
      body: _CashReconciliationView(summary: summary),
      actions: [
        FilledButton(
          style: _primaryStatusActionStyle,
          onPressed: _finishClosedShift,
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _lookupButton() => OutlinedButton.icon(
    style: _secondaryStatusActionStyle,
    onPressed: _operationPending ? null : _openReceiptLookup,
    icon: const Icon(Icons.receipt_long_outlined),
    label: const Text('Lookup Completed Sale'),
  );

  Widget _refreshButton() => OutlinedButton.icon(
    style: _secondaryStatusActionStyle,
    onPressed: _operationPending ? null : _refreshRegisterState,
    icon: const Icon(Icons.refresh),
    label: const Text('Refresh Register State'),
  );
}

final class _RegisterHomeData {
  const _RegisterHomeData({
    required this.health,
    required this.context,
    required this.cashSummary,
  });

  final PosCoreHealth health;
  final RegisterContext? context;
  final ShiftCashSummary? cashSummary;
}

final class _CashReconciliationView extends StatelessWidget {
  const _CashReconciliationView({required this.summary});

  final ShiftCashSummary summary;

  @override
  Widget build(BuildContext context) {
    if (summary.view != ShiftCashSummaryView.full) {
      return const Text('Full reconciliation is unavailable.');
    }
    return Column(
      children: [
        _row(
          'Opening Cash',
          formatUsdMinorUnits(summary.openingCashMinorUnits!),
        ),
        _row('Cash Sales', formatUsdMinorUnits(summary.cashSalesMinorUnits!)),
        _row(
          'Expected Cash',
          formatUsdMinorUnits(summary.expectedCashMinorUnits!),
        ),
        _row(
          'Counted Cash',
          formatUsdMinorUnits(summary.countedCashMinorUnits!),
        ),
        _row(
          'Over / Short',
          formatSignedUsdMinorUnits(summary.overShortMinorUnits!),
        ),
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value),
      ],
    ),
  );
}

final class _CloseShiftDialog extends StatefulWidget {
  const _CloseShiftDialog({required this.shift});

  final RegisterShift shift;

  @override
  State<_CloseShiftDialog> createState() => _CloseShiftDialogState();
}

final class _CloseShiftDialogState extends State<_CloseShiftDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _validation;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = parseMoneyInputMinorUnits(_controller.text);
    if (parsed == null) {
      setState(() => _validation = 'Enter a valid closing cash amount.');
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Close Shift'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cashier: ${widget.shift.cashierDisplayName}'),
          Text('Shift: ${widget.shift.shiftId}'),
          const SizedBox(height: 16),
          const Text('Count all physical cash currently in the drawer.'),
          const SizedBox(height: 12),
          TextField(
            key: const Key('closing-cash-input'),
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: InputDecoration(
              labelText: 'Closing Cash',
              errorText: _validation,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Reconcile & Close'),
        ),
      ],
    );
  }
}

String _formatUtcEpochMs(int epochMs) {
  final value = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year.toString().padLeft(4, '0')}-'
      '${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}:${two(value.second)} UTC';
}

final class _StatusLayout extends StatelessWidget {
  const _StatusLayout({
    required this.title,
    required this.status,
    required this.detail,
    required this.icon,
    this.feedback,
    this.body,
    this.actions = const [],
  });

  final String title;
  final String status;
  final String detail;
  final IconData icon;
  final String? feedback;
  final Widget? body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 72),
                    const SizedBox(height: 24),
                    Text(
                      title,
                      style: textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      status,
                      style: textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      detail,
                      style: textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (feedback != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          feedback!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    if (body != null) ...[const SizedBox(height: 24), body!],
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        runSpacing: 12,
                        children: actions,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
