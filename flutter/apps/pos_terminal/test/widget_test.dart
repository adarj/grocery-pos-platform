import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/app/pos_terminal_app.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/canonical_receipt.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_health.dart';
import 'package:pos_terminal/core/pos_core/models/register_operations.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/core/pos_core/pos_core_client.dart';
import 'package:pos_terminal/features/cashier/cashier_id_generator.dart';
import 'package:pos_terminal/features/cashier/cashier_session_controller.dart';
import 'package:pos_terminal/features/cashier/cashier_session_store.dart';

final class MemoryCashierSessionStore implements CashierSessionStore {
  PersistedCashierSession? persisted;

  @override
  Future<PersistedCashierSession?> load() async => persisted;

  @override
  Future<void> save(PersistedCashierSession session) async {
    persisted = session;
  }

  @override
  Future<void> clear() async {
    persisted = null;
  }
}

final class FixedCashierIds implements CashierIdGenerator {
  @override
  String nextCommandId() => 'cmd-widget';

  @override
  String nextTransactionId() => 'txn-widget';
}

mixin FakeRegisterOperations {
  Future<RegisterContext> fetchRegisterContext() async => const RegisterContext(
    configured: true,
    register: RegisterIdentity(
      registerId: 'register-test',
      displayName: 'Test Register',
    ),
    activeShift: RegisterShift(
      shiftId: 'shift-test',
      registerId: 'register-test',
      registerDisplayName: 'Test Register',
      cashierId: 'cashier-test',
      cashierDisplayName: 'Test Cashier',
      openedAtEpochMs: 0,
      closedAtEpochMs: null,
      activeTransactionId: null,
    ),
  );

  Future<List<CashierIdentity>> fetchActiveCashiers() async => const [];

  Future<RegisterShift> openShift(String cashierId) =>
      throw UnimplementedError();

  Future<RegisterShift> closeShift(String shiftId) =>
      throw UnimplementedError();
}

class FakeConnectedPosCoreClient
    with FakeRegisterOperations
    implements PosCoreClient {
  @override
  Future<CanonicalReceipt> fetchReceipt(String transactionId) {
    throw UnimplementedError();
  }

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

class FakeUnavailablePosCoreClient
    with FakeRegisterOperations
    implements PosCoreClient {
  @override
  Future<CanonicalReceipt> fetchReceipt(String transactionId) {
    throw UnimplementedError();
  }

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

final class FakeConnectingPosCoreClient
    with FakeRegisterOperations
    implements PosCoreClient {
  @override
  Future<CanonicalReceipt> fetchReceipt(String transactionId) {
    throw UnimplementedError();
  }

  final Completer<PosCoreHealth> health = Completer();

  @override
  Future<PosCoreHealth> fetchHealth() => health.future;

  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) {
    throw UnimplementedError();
  }
}

PosTerminalApp testApp(PosCoreClient client) {
  return PosTerminalApp(
    client: client,
    cashierController: CashierSessionController(
      client: client,
      idGenerator: FixedCashierIds(),
      sessionStore: MemoryCashierSessionStore(),
    ),
  );
}

void main() {
  testWidgets('shows connected state when POS Core is healthy', (tester) async {
    await tester.pumpWidget(testApp(FakeConnectedPosCoreClient()));

    await tester.pumpAndSettle();

    expect(find.text('Test Register'), findsOneWidget);
    expect(find.text('Shift Open'), findsOneWidget);
    expect(find.textContaining('Cashier: Test Cashier'), findsOneWidget);
    expect(find.text('Open Register'), findsOneWidget);
    expect(find.text('Lookup Completed Sale'), findsOneWidget);
    expect(find.text('Refresh Register State'), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(FilledButton, 'Open Register')).height,
      greaterThanOrEqualTo(52),
    );
  });

  testWidgets('shows connecting state while health request is pending', (
    tester,
  ) async {
    final client = FakeConnectingPosCoreClient();
    await tester.pumpWidget(testApp(client));
    await tester.pump();

    expect(find.text('Connecting to POS Core...'), findsOneWidget);
    expect(find.text('Open Register'), findsNothing);
  });

  testWidgets('shows unavailable state when POS Core cannot be reached', (
    tester,
  ) async {
    await tester.pumpWidget(testApp(FakeUnavailablePosCoreClient()));

    await tester.pumpAndSettle();

    expect(find.text('Grocery POS Terminal'), findsOneWidget);
    expect(find.text('POS Core Unavailable'), findsOneWidget);
    expect(
      find.text('Check that POS Core is running, then retry.'),
      findsOneWidget,
    );
    expect(find.text('Connection refused.'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Open Register'), findsNothing);
  });

  testWidgets('Open Register navigates from healthy status to cashier', (
    tester,
  ) async {
    await tester.pumpWidget(testApp(FakeConnectedPosCoreClient()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Register'));
    await tester.pumpAndSettle();

    expect(find.text('Grocery POS'), findsOneWidget);
    expect(find.text('Start Sale'), findsOneWidget);
  });

  testWidgets('connected gateway opens exact completed-sale lookup', (
    tester,
  ) async {
    await tester.pumpWidget(testApp(FakeConnectedPosCoreClient()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lookup Completed Sale'));
    await tester.pumpAndSettle();

    expect(find.text('Lookup Completed Sale'), findsOneWidget);
    expect(
      find.byKey(const Key('receipt-transaction-id-field')),
      findsOneWidget,
    );
    expect(find.text('Find Receipt'), findsOneWidget);
  });
}
