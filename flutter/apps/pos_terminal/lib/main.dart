import 'package:flutter/material.dart';

import 'app/pos_terminal_app.dart';
import 'core/pos_core/http_pos_core_client.dart';
import 'core/pos_core/authentication_client.dart';
import 'core/pos_core/pos_core_endpoint.dart';
import 'features/cashier/cashier_id_generator.dart';
import 'features/cashier/cashier_session_controller.dart';
import 'features/cashier/file_cashier_session_store.dart';
import 'features/authentication/authentication_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final authenticationMemory = MemoryAuthenticationSession();
  final client = HttpPosCoreClient(
    baseUri: resolvePosCoreBaseUri(),
    authenticationSession: authenticationMemory,
  );
  final authenticationController = AuthenticationController(
    client: client,
    sessionMemory: authenticationMemory,
  );
  final cashierController = CashierSessionController(
    client: client,
    idGenerator: SecureCashierIdGenerator(),
    sessionStore: FileCashierSessionStore.fromEnvironment(),
    currentOperatorId: () => authenticationMemory.session?.operatorId,
  );
  await cashierController.restoreLocalSession();

  runApp(
    PosTerminalApp(
      client: client,
      cashierController: cashierController,
      authenticationController: authenticationController,
    ),
  );
}
