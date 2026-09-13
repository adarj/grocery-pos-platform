import 'package:flutter/material.dart';

import 'app/pos_terminal_app.dart';
import 'core/pos_core/http_pos_core_client.dart';
import 'core/pos_core/pos_core_endpoint.dart';
import 'features/cashier/cashier_id_generator.dart';
import 'features/cashier/cashier_session_controller.dart';
import 'features/cashier/file_cashier_session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final client = HttpPosCoreClient(baseUri: resolvePosCoreBaseUri());
  final cashierController = CashierSessionController(
    client: client,
    idGenerator: SecureCashierIdGenerator(),
    sessionStore: FileCashierSessionStore.fromEnvironment(),
  );
  await cashierController.restoreLocalSession();

  runApp(PosTerminalApp(client: client, cashierController: cashierController));
}
