import 'package:flutter/material.dart';

import '../../core/pos_core/models/pos_core_failure.dart';
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
    super.key,
  });

  final PosCoreClient client;
  final CashierSessionController cashierController;

  @override
  State<PosCoreStatusScreen> createState() => _PosCoreStatusScreenState();
}

final class _PosCoreStatusScreenState extends State<PosCoreStatusScreen> {
  late Future<_RegisterHomeData> _homeFuture;
  bool _operationPending = false;
  String? _operationFeedback;
  String? _selectedCashierId;

  @override
  void initState() {
    super.initState();
    _homeFuture = _loadHome();
  }

  Future<_RegisterHomeData> _loadHome() async {
    final health = await widget.client.fetchHealth();
    if (!health.ok) {
      return _RegisterHomeData(
        health: health,
        context: null,
        cashiers: const [],
      );
    }
    final registerContext = await widget.client.fetchRegisterContext();
    final cashiers =
        registerContext.configured && registerContext.activeShift == null
        ? await widget.client.fetchActiveCashiers()
        : const <CashierIdentity>[];
    return _RegisterHomeData(
      health: health,
      context: registerContext,
      cashiers: cashiers,
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
    final cashierId = _selectedCashierId;
    if (_operationPending || cashierId == null) return;
    setState(() {
      _operationPending = true;
      _operationFeedback = null;
    });
    try {
      await widget.client.openShift(cashierId);
      if (!mounted) return;
      setState(() {
        _operationPending = false;
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close shift?'),
        content: Text('Cashier: ${shift.cashierDisplayName}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep Shift'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Close Shift'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _operationPending) return;
    setState(() {
      _operationPending = true;
      _operationFeedback = null;
    });
    try {
      await widget.client.closeShift(shift.shiftId);
      if (!mounted) return;
      setState(() {
        _operationPending = false;
        _homeFuture = _loadHome();
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _operationPending = false;
        _operationFeedback = _operationalFailureMessage(
          error,
          unknownOutcome:
              'Close Shift result could not be confirmed. Refresh Register State.',
        );
      });
    }
  }

  String _operationalFailureMessage(
    Object error, {
    required String unknownOutcome,
  }) {
    if (error is PosCoreServerFailure &&
        error.code == 'shift_has_active_transaction') {
      return 'Finish or void the active sale before closing the shift.';
    }
    if (error is PosCoreServerFailure &&
        error.code == 'shift_already_open') {
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
    final registerContext = data.context!;
    if (!registerContext.configured) {
      return _StatusLayout(
        title: 'Grocery POS Terminal',
        status: 'Register configuration required',
        detail:
            'Activate register and cashier configuration with the operator CLI.',
        icon: Icons.settings_outlined,
        feedback: _operationFeedback,
        actions: [
          _lookupButton(),
          _refreshButton(),
        ],
      );
    }

    final shift = registerContext.activeShift;
    if (shift == null) {
      final validSelection = data.cashiers.any(
        (cashier) => cashier.cashierId == _selectedCashierId,
      );
      if (!validSelection) {
        _selectedCashierId = data.cashiers.isEmpty
            ? null
            : data.cashiers.first.cashierId;
      }
      return _StatusLayout(
        title: registerContext.register!.displayName,
        status: 'Select Cashier',
        detail: 'Open a shift to begin cashier transactions.',
        icon: Icons.badge_outlined,
        feedback: _operationFeedback,
        body: DropdownButtonFormField<String>(
          key: const Key('cashier-selection'),
          initialValue: _selectedCashierId,
          decoration: const InputDecoration(labelText: 'Cashier'),
          items: [
            for (final cashier in data.cashiers)
              DropdownMenuItem(
                value: cashier.cashierId,
                child: Text(cashier.displayName),
              ),
          ],
          onChanged: _operationPending
              ? null
              : (value) => setState(() => _selectedCashierId = value),
        ),
        actions: [
          FilledButton.icon(
            style: _primaryStatusActionStyle,
            onPressed: _operationPending || _selectedCashierId == null
                ? null
                : _openShift,
            icon: const Icon(Icons.login),
            label: Text(_operationPending ? 'Opening...' : 'Open Shift'),
          ),
          _lookupButton(),
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
    required this.cashiers,
  });

  final PosCoreHealth health;
  final RegisterContext? context;
  final List<CashierIdentity> cashiers;
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
                    if (body != null) ...[
                      const SizedBox(height: 24),
                      body!,
                    ],
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
