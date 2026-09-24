import 'package:flutter/material.dart';

import '../core/pos_core/pos_core_client.dart';
import '../features/cashier/cashier_session_controller.dart';
import '../features/authentication/authentication_controller.dart';
import '../features/authentication/change_pin_dialog.dart';
import '../features/authentication/register_lock_screen.dart';

final class PosTerminalApp extends StatefulWidget {
  const PosTerminalApp({
    required this.client,
    required this.cashierController,
    required this.authenticationController,
    super.key,
  });

  final PosCoreClient client;
  final CashierSessionController cashierController;
  final AuthenticationController authenticationController;

  @override
  State<PosTerminalApp> createState() => _PosTerminalAppState();
}

final class _PosTerminalAppState extends State<PosTerminalApp> {
  GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late bool _wasAuthenticated;

  @override
  void initState() {
    super.initState();
    _wasAuthenticated = widget.authenticationController.authenticated;
    widget.authenticationController.addListener(_enforceLockBoundary);
  }

  void _enforceLockBoundary() {
    final authenticated = widget.authenticationController.authenticated;
    final authenticationLost = _wasAuthenticated && !authenticated;
    _wasAuthenticated = authenticated;
    if (!authenticationLost) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.authenticationController.authenticated) return;
      // Replacing the Navigator identity disposes the entire authenticated
      // route tree. Protected routes do not get to retain hidden state or veto
      // the reset; durable cashier recovery lives outside this widget tree.
      setState(() => _navigatorKey = GlobalKey<NavigatorState>());
    });
  }

  @override
  void dispose() {
    widget.authenticationController.removeListener(_enforceLockBoundary);
    widget.authenticationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Grocery POS Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: RegisterLockScreen(
        client: widget.client,
        cashierController: widget.cashierController,
        authenticationController: widget.authenticationController,
      ),
      builder: (context, child) {
        final content = child ?? const SizedBox.shrink();
        return AnimatedBuilder(
          animation: widget.authenticationController,
          builder: (context, _) {
            final protectsPushedRoute =
                !widget.authenticationController.authenticated &&
                (_navigatorKey.currentState?.canPop() ?? false);
            if (protectsPushedRoute) {
              return const ColoredBox(
                color: Colors.white,
                child: Center(
                  child: Text(
                    'Register Locked',
                    key: Key('register-lock-shield'),
                  ),
                ),
              );
            }
            return Focus(
              canRequestFocus: false,
              onKeyEvent: (_, _) {
                widget.authenticationController.recordUserActivity();
                return KeyEventResult.ignored;
              },
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) =>
                    widget.authenticationController.recordUserActivity(),
                onPointerMove: (_) =>
                    widget.authenticationController.recordUserActivity(),
                onPointerSignal: (_) =>
                    widget.authenticationController.recordUserActivity(),
                child: Stack(
                  children: [
                    content,
                    if (widget.authenticationController.authenticated)
                      Positioned(
                        top: 16,
                        right: 16,
                        child: SafeArea(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FilledButton.tonal(
                                key: const Key('change-pin-button'),
                                onPressed: () {
                                  final routeContext =
                                      _navigatorKey.currentState?.overlay?.context;
                                  if (routeContext == null) return;
                                  showDialog<void>(
                                    context: routeContext,
                                    builder: (_) => ChangePinDialog(
                                      controller:
                                          widget.authenticationController,
                                    ),
                                  );
                                },
                                child: const Text('Change PIN'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.tonalIcon(
                                key: const Key('register-lock-button'),
                                onPressed: widget.authenticationController.lock,
                                icon: const Icon(Icons.lock),
                                label: const Text('Lock'),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
