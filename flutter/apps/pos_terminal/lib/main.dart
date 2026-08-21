import 'package:flutter/material.dart';

import 'app/pos_terminal_app.dart';
import 'core/pos_core/http_pos_core_client.dart';
import 'features/cashier/cashier_id_generator.dart';
import 'features/cashier/cashier_session_controller.dart';

void main() {
  final client = HttpPosCoreClient(baseUri: Uri.parse('http://127.0.0.1:7340'));
  final cashierController = CashierSessionController(
    client: client,
    idGenerator: SecureCashierIdGenerator(),
  );

  runApp(PosTerminalApp(client: client, cashierController: cashierController));
}
