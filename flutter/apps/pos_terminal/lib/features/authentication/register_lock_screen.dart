import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/pos_core/pos_core_client.dart';
import '../cashier/cashier_session_controller.dart';
import '../status/pos_core_status_screen.dart';
import 'authentication_controller.dart';

final class RegisterLockScreen extends StatefulWidget {
  const RegisterLockScreen({
    required this.client,
    required this.cashierController,
    required this.authenticationController,
    super.key,
  });

  final PosCoreClient client;
  final CashierSessionController cashierController;
  final AuthenticationController authenticationController;

  @override
  State<RegisterLockScreen> createState() => _RegisterLockScreenState();
}

final class _RegisterLockScreenState extends State<RegisterLockScreen> {
  late Future<bool> _availability;

  @override
  void initState() {
    super.initState();
    _availability = _checkAvailability();
  }

  Future<bool> _checkAvailability() async {
    final health = await widget.client.fetchHealth();
    if (!health.ok) return false;
    final readiness = await widget.client.fetchReadiness();
    return readiness.ready;
  }

  void _retry() {
    setState(() => _availability = _checkAvailability());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.authenticationController,
      builder: (context, _) {
        if (widget.authenticationController.authenticated) {
          return PosCoreStatusScreen(
            client: widget.client,
            cashierController: widget.cashierController,
          );
        }
        return FutureBuilder<bool>(
          future: _availability,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _LockStatus(
                icon: Icons.sync,
                status: 'Connecting to POS Core...',
                detail: 'Checking register readiness.',
              );
            }
            if (snapshot.hasError || snapshot.data != true) {
              return _LockStatus(
                icon: Icons.error_outline,
                status: 'POS Core Unavailable',
                detail: 'Check that POS Core is running, then retry.',
                action: FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              );
            }
            return _OperatorLogin(controller: widget.authenticationController);
          },
        );
      },
    );
  }
}

final class _OperatorLogin extends StatefulWidget {
  const _OperatorLogin({required this.controller});

  final AuthenticationController controller;

  @override
  State<_OperatorLogin> createState() => _OperatorLoginState();
}

final class _OperatorLoginState extends State<_OperatorLogin> {
  final _operatorId = TextEditingController();
  final _pin = TextEditingController();

  @override
  void dispose() {
    _operatorId.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _pin.text;
    _pin.clear();
    await widget.controller.login(_operatorId.text, pin);
  }

  @override
  Widget build(BuildContext context) {
    final pending =
        widget.controller.status == AuthenticationStatus.authenticating;
    final failed =
        widget.controller.status == AuthenticationStatus.authenticationFailed;
    final unavailable =
        widget.controller.status == AuthenticationStatus.coreUnavailable;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_outline, size: 64),
                  const SizedBox(height: 20),
                  Text(
                    'Register Locked',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    key: const Key('operator-id-input'),
                    controller: _operatorId,
                    enabled: !pending,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Operator ID'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('operator-pin-input'),
                    controller: _pin,
                    enabled: !pending,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                      LengthLimitingTextInputFormatter(12),
                    ],
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(labelText: 'PIN'),
                  ),
                  const SizedBox(height: 16),
                  if (failed)
                    const Text(
                      'Sign-in failed. Check your operator ID and PIN. '
                      'After repeated attempts, wait briefly before trying again.',
                      key: Key('authentication-failure'),
                    ),
                  if (unavailable)
                    const Text(
                      'POS Core is temporarily unavailable. Try again.',
                      key: Key('authentication-unavailable'),
                    ),
                  if (failed || unavailable) const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('operator-login-button'),
                    onPressed: pending ? null : _submit,
                    icon: const Icon(Icons.login),
                    label: Text(pending ? 'Signing in...' : 'Sign In'),
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

final class _LockStatus extends StatelessWidget {
  const _LockStatus({
    required this.icon,
    required this.status,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String status;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 64),
                const SizedBox(height: 16),
                Text(
                  'Grocery POS Terminal',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(detail, textAlign: TextAlign.center),
                if (action != null) ...[const SizedBox(height: 24), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
