import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/app/pos_terminal_app.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_health.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/core/pos_core/pos_core_client.dart';

class FakeConnectedPosCoreClient implements PosCoreClient {
  @override
  Future<PosCoreHealth> fetchHealth() async {
    return const PosCoreHealth(
      ok: true,
      service: 'grocery-pos-core',
      version: '0.0.0-dev',
      environment: 'dev',
    );
  }

  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) {
    throw UnimplementedError();
  }
}

class FakeUnavailablePosCoreClient implements PosCoreClient {
  @override
  Future<PosCoreHealth> fetchHealth() async {
    throw const PosCoreTransportFailure('Connection refused.');
  }

  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) {
    throw UnimplementedError();
  }
}

void main() {
  testWidgets('shows connected state when POS Core is healthy', (tester) async {
    await tester.pumpWidget(
      PosTerminalApp(client: FakeConnectedPosCoreClient()),
    );

    await tester.pumpAndSettle();

    expect(find.text('Grocery POS Terminal'), findsOneWidget);
    expect(find.text('POS Core Connected'), findsOneWidget);
    expect(find.text('grocery-pos-core 0.0.0-dev (dev)'), findsOneWidget);
  });

  testWidgets('shows unavailable state when POS Core cannot be reached', (
    tester,
  ) async {
    await tester.pumpWidget(
      PosTerminalApp(client: FakeUnavailablePosCoreClient()),
    );

    await tester.pumpAndSettle();

    expect(find.text('Grocery POS Terminal'), findsOneWidget);
    expect(find.text('POS Core Unavailable'), findsOneWidget);
    expect(find.text('Connection refused.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
