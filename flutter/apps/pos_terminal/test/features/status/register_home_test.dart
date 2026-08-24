import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/canonical_receipt.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_health.dart';
import 'package:pos_terminal/core/pos_core/models/register_operations.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/core/pos_core/pos_core_client.dart';
import 'package:pos_terminal/features/cashier/cashier_id_generator.dart';
import 'package:pos_terminal/features/cashier/cashier_session_controller.dart';
import 'package:pos_terminal/features/cashier/cashier_session_store.dart';
import 'package:pos_terminal/features/status/pos_core_status_screen.dart';

const register = RegisterIdentity(
  registerId: 'register-one',
  displayName: 'Front Register',
);
const cashier = CashierIdentity(cashierId: 'cashier-one', displayName: 'Alice');
const activeShift = RegisterShift(
  shiftId: 'shift-one',
  registerId: 'register-one',
  registerDisplayName: 'Front Register',
  cashierId: 'cashier-one',
  cashierDisplayName: 'Alice',
  openedAtEpochMs: 0,
  closedAtEpochMs: null,
  activeTransactionId: null,
);
const noShift = RegisterContext(
  configured: true,
  register: register,
  activeShift: null,
);
const withShift = RegisterContext(
  configured: true,
  register: register,
  activeShift: activeShift,
);

final class FakeClient implements PosCoreClient {
  final Queue<RegisterContext> contexts = Queue();
  List<CashierIdentity> cashiers = const [cashier];
  Future<RegisterShift> Function(String cashierId)? onOpen;
  Future<RegisterShift> Function(String shiftId)? onClose;
  int openCalls = 0;
  int closeCalls = 0;
  final List<String> openedCashierIds = [];

  @override
  Future<PosCoreHealth> fetchHealth() async => const PosCoreHealth(
    ok: true,
    service: 'grocery-pos-core',
    version: 'dev',
    environment: 'test',
  );

  @override
  Future<RegisterContext> fetchRegisterContext() async =>
      contexts.removeFirst();

  @override
  Future<List<CashierIdentity>> fetchActiveCashiers() async => cashiers;

  @override
  Future<RegisterShift> openShift(String cashierId) {
    openCalls += 1;
    openedCashierIds.add(cashierId);
    return onOpen!(cashierId);
  }

  @override
  Future<RegisterShift> closeShift(String shiftId) {
    closeCalls += 1;
    return onClose!(shiftId);
  }

  @override
  Future<CanonicalReceipt> fetchReceipt(String transactionId) =>
      throw UnimplementedError();
  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) =>
      throw UnimplementedError();
  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) =>
      throw UnimplementedError();
}

final class MemoryStore implements CashierSessionStore {
  @override
  Future<void> clear() async {}
  @override
  Future<PersistedCashierSession?> load() async => null;
  @override
  Future<void> save(PersistedCashierSession session) async {}
}

final class FixedIds implements CashierIdGenerator {
  @override
  String nextCommandId() => 'cmd';
  @override
  String nextTransactionId() => 'txn';
}

Widget app(FakeClient client) => MaterialApp(
  home: PosCoreStatusScreen(
    client: client,
    cashierController: CashierSessionController(
      client: client,
      idGenerator: FixedIds(),
      sessionStore: MemoryStore(),
    ),
  ),
);

void main() {
  testWidgets(
    'unconfigured register blocks cashier but retains receipt lookup',
    (tester) async {
      final client = FakeClient()
        ..contexts.add(
          const RegisterContext(
            configured: false,
            register: null,
            activeShift: null,
          ),
        );
      await tester.pumpWidget(app(client));
      await tester.pumpAndSettle();
      expect(find.text('Register configuration required'), findsOneWidget);
      expect(find.text('Open Register'), findsNothing);
      expect(find.text('Lookup Completed Sale'), findsOneWidget);
      expect(find.textContaining('PIN'), findsNothing);
      expect(find.textContaining('Authenticated'), findsNothing);
    },
  );

  testWidgets(
    'Open Shift selects identity once and disables duplicate submission',
    (tester) async {
      final completer = Completer<RegisterShift>();
      final client = FakeClient()
        ..contexts.addAll([noShift, withShift])
        ..onOpen = (_) => completer.future;
      await tester.pumpWidget(app(client));
      await tester.pumpAndSettle();
      expect(find.text('Select Cashier'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      await tester.tap(find.text('Open Shift'));
      await tester.pump();
      expect(client.openCalls, 1);
      expect(client.openedCashierIds, ['cashier-one']);
      await tester.tap(find.text('Opening...'));
      await tester.pump();
      expect(client.openCalls, 1);
      completer.complete(activeShift);
      await tester.pumpAndSettle();
      expect(find.text('Shift Open'), findsOneWidget);
      expect(find.textContaining('Cashier: Alice'), findsOneWidget);
      expect(find.textContaining('1970-01-01 00:00:00 UTC'), findsOneWidget);
      expect(find.text('Open Register'), findsOneWidget);
    },
  );

  testWidgets(
    'uncertain open offers register-state refresh, not command retry',
    (tester) async {
      final client = FakeClient()
        ..contexts.add(noShift)
        ..onOpen = (_) async => throw const PosCoreTransportFailure('lost');
      await tester.pumpWidget(app(client));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Shift'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Open Shift result could not be confirmed. Refresh Register State.',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry Command'), findsNothing);
      expect(find.text('Refresh Register State'), findsOneWidget);
    },
  );

  testWidgets(
    'Close Shift confirms and preserves active-sale conflict safely',
    (tester) async {
      final client = FakeClient()
        ..contexts.add(withShift)
        ..onClose = (_) async => throw const PosCoreServerFailure(
          code: 'shift_has_active_transaction',
          message: 'safe',
          statusCode: 409,
        );
      await tester.pumpWidget(app(client));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close Shift'));
      await tester.pumpAndSettle();
      expect(find.text('Close shift?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Close Shift'));
      await tester.pumpAndSettle();
      expect(client.closeCalls, 1);
      expect(
        find.text('Finish or void the active sale before closing the shift.'),
        findsOneWidget,
      );
      expect(find.text('Shift Open'), findsOneWidget);
    },
  );

  testWidgets('successful close returns to cashier selection workflow', (
    tester,
  ) async {
    const closedShift = RegisterShift(
      shiftId: 'shift-one',
      registerId: 'register-one',
      registerDisplayName: 'Front Register',
      cashierId: 'cashier-one',
      cashierDisplayName: 'Alice',
      openedAtEpochMs: 0,
      closedAtEpochMs: 100,
      activeTransactionId: null,
    );
    final client = FakeClient()
      ..contexts.addAll([withShift, noShift])
      ..onClose = (_) async => closedShift;
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Close Shift'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Close Shift'));
    await tester.pumpAndSettle();

    expect(client.closeCalls, 1);
    expect(find.text('Select Cashier'), findsOneWidget);
    expect(find.text('Open Shift'), findsOneWidget);
    expect(find.text('Open Register'), findsNothing);
    expect(find.text('Lookup Completed Sale'), findsOneWidget);
  });
}
