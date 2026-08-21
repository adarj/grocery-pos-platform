import 'package:flutter/material.dart';

import '../../core/pos_core/models/pos_core_health.dart';
import '../../core/pos_core/pos_core_client.dart';
import '../cashier/cashier_screen.dart';
import '../cashier/cashier_session_controller.dart';

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
  late Future<PosCoreHealth> _healthFuture;

  @override
  void initState() {
    super.initState();
    _healthFuture = widget.client.fetchHealth();
  }

  void _retry() {
    setState(() {
      _healthFuture = widget.client.fetchHealth();
    });
  }

  void _openRegister() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            CashierScreen(controller: widget.cashierController),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<PosCoreHealth>(
          future: _healthFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _StatusLayout(
                title: 'Grocery POS Terminal',
                status: 'Connecting to POS Core...',
                detail: 'Checking http://127.0.0.1:7340/health',
                icon: Icons.sync,
              );
            }

            if (snapshot.hasError) {
              return _StatusLayout(
                title: 'Grocery POS Terminal',
                status: 'POS Core Unavailable',
                detail: snapshot.error.toString(),
                icon: Icons.error_outline,
                actions: [
                  FilledButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              );
            }

            final health = snapshot.data!;

            if (!health.ok) {
              return _StatusLayout(
                title: 'Grocery POS Terminal',
                status: 'POS Core Unavailable',
                detail: 'Health endpoint returned ok=false.',
                icon: Icons.warning_amber_outlined,
                actions: [
                  FilledButton.icon(
                    onPressed: _retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              );
            }

            return _StatusLayout(
              title: 'Grocery POS Terminal',
              status: 'POS Core Connected',
              detail:
                  '${health.service} ${health.version} (${health.environment})',
              icon: Icons.check_circle_outline,
              actions: [
                FilledButton.icon(
                  onPressed: _openRegister,
                  icon: const Icon(Icons.point_of_sale),
                  label: const Text('Open Register'),
                ),
                OutlinedButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

final class _StatusLayout extends StatelessWidget {
  const _StatusLayout({
    required this.title,
    required this.status,
    required this.detail,
    required this.icon,
    this.actions = const [],
  });

  final String title;
  final String status;
  final String detail;
  final IconData icon;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Center(
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
    );
  }
}
