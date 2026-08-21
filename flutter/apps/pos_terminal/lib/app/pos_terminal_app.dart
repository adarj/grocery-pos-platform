import 'package:flutter/material.dart';

import '../core/pos_core/pos_core_client.dart';
import '../features/cashier/cashier_session_controller.dart';
import '../features/status/pos_core_status_screen.dart';

final class PosTerminalApp extends StatelessWidget {
  const PosTerminalApp({
    required this.client,
    required this.cashierController,
    super.key,
  });

  final PosCoreClient client;
  final CashierSessionController cashierController;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Grocery POS Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: PosCoreStatusScreen(
        client: client,
        cashierController: cashierController,
      ),
    );
  }
}
