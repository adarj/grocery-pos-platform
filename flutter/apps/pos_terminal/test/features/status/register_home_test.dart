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
const openCashSummary = ShiftCashSummary(
  shiftId: 'shift-one',
  status: ShiftCashStatus.open,
  openingCashMinorUnits: 10000,
  completedCashSaleCount: 0,
  cashSalesMinorUnits: 0,
  expectedCashMinorUnits: 10000,
  countedCashMinorUnits: null,
  overShortMinorUnits: null,
);
const closedCashSummary = ShiftCashSummary(
  shiftId: 'shift-one',
  status: ShiftCashStatus.closed,
  openingCashMinorUnits: 10000,
  completedCashSaleCount: 3,
  cashSalesMinorUnits: 1000,
  expectedCashMinorUnits: 77777,
  countedCashMinorUnits: 80000,
  overShortMinorUnits: -999,
);

final class FakeClient implements PosCoreClient {
  final Queue<RegisterContext> contexts = Queue();
  final Queue<ShiftCashSummary> summaries = Queue();
  List<CashierIdentity> cashiers = const [cashier];
  Future<ShiftOperationResult> Function(
    String cashierId,
    int openingCashMinorUnits,
  )?
  onOpen;
  Future<ShiftOperationResult> Function(
    String shiftId,
    int countedCashMinorUnits,
  )?
  onClose;
  int openCalls = 0;
  int closeCalls = 0;
  final List<String> openedCashierIds = [];
  final List<int> openingCashValues = [];
  final List<int> countedCashValues = [];

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
  Future<ShiftOperationResult> openShift(
    String cashierId,
    int openingCashMinorUnits,
  ) {
    openCalls += 1;
    openedCashierIds.add(cashierId);
    openingCashValues.add(openingCashMinorUnits);
    return onOpen!(cashierId, openingCashMinorUnits);
  }

  @override
  Future<ShiftOperationResult> closeShift(
    String shiftId,
    int countedCashMinorUnits,
  ) {
    closeCalls += 1;
    countedCashValues.add(countedCashMinorUnits);
    return onClose!(shiftId, countedCashMinorUnits);
  }

  @override
  Future<ShiftCashSummary> fetchShiftCashSummary(String shiftId) async =>
      summaries.removeFirst();

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
      final completer = Completer<ShiftOperationResult>();
      final client = FakeClient()
        ..contexts.addAll([noShift, withShift])
        ..summaries.add(openCashSummary)
        ..onOpen = (_, _) => completer.future;
      await tester.pumpWidget(app(client));
      await tester.pumpAndSettle();
      expect(find.text('Select Cashier'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('opening-cash-input')),
        '100.00',
      );
      await tester.tap(find.text('Open Shift'));
      await tester.pump();
      expect(client.openCalls, 1);
      expect(client.openedCashierIds, ['cashier-one']);
      expect(client.openingCashValues, [10000]);
      await tester.tap(find.text('Opening...'));
      await tester.pump();
      expect(client.openCalls, 1);
      completer.complete(
        const ShiftOperationResult(
          shift: activeShift,
          cashSummary: openCashSummary,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Shift Open'), findsOneWidget);
      expect(find.textContaining('Cashier: Alice'), findsOneWidget);
      expect(find.textContaining('1970-01-01 00:00:00 UTC'), findsOneWidget);
      expect(find.textContaining('Opening Cash: \$100.00'), findsOneWidget);
      expect(find.text('Open Register'), findsOneWidget);
    },
  );

  testWidgets(
    'uncertain open offers register-state refresh, not command retry',
    (tester) async {
      final client = FakeClient()
        ..contexts.add(noShift)
        ..onOpen = (_, _) async => throw const PosCoreTransportFailure('lost');
      await tester.pumpWidget(app(client));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('opening-cash-input')),
        '0.00',
      );
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
        ..summaries.add(openCashSummary)
        ..onClose = (_, _) async => throw const PosCoreServerFailure(
          code: 'shift_has_active_transaction',
          message: 'safe',
          statusCode: 409,
        );
      await tester.pumpWidget(app(client));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close Shift'));
      await tester.pumpAndSettle();
      expect(
        find.text('Count all physical cash currently in the drawer.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('closing-cash-input')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('closing-cash-input')),
        '100.00',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Reconcile & Close'));
      await tester.pumpAndSettle();
      expect(client.closeCalls, 1);
      expect(client.countedCashValues, [10000]);
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
      ..summaries.add(openCashSummary)
      ..onClose = (_, _) async => const ShiftOperationResult(
        shift: closedShift,
        cashSummary: closedCashSummary,
      );
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Close Shift'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('closing-cash-input')),
      '800.00',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Reconcile & Close'));
    await tester.pumpAndSettle();

    expect(client.closeCalls, 1);
    expect(find.text('Shift Closed'), findsOneWidget);
    expect(find.text('\$100.00'), findsOneWidget);
    expect(find.text('\$10.00'), findsOneWidget);
    expect(find.text('\$777.77'), findsOneWidget);
    expect(find.text('\$800.00'), findsOneWidget);
    expect(find.text('-\$9.99'), findsOneWidget);
    expect(find.text('\$110.00'), findsNothing);
    expect(find.text('\$22.23'), findsNothing);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Select Cashier'), findsOneWidget);
    expect(find.text('Open Shift'), findsOneWidget);
    expect(find.text('Open Register'), findsNothing);
    expect(find.text('Lookup Completed Sale'), findsOneWidget);
  });

  testWidgets('invalid opening syntax prevents operational write', (
    tester,
  ) async {
    final client = FakeClient()..contexts.add(noShift);
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('opening-cash-input')),
      '1.999',
    );
    await tester.tap(find.text('Open Shift'));
    await tester.pump();
    expect(client.openCalls, 0);
    expect(find.text('Enter a valid opening cash amount.'), findsOneWidget);
  });

  testWidgets('close uncertainty recovers immutable reconciliation by read', (
    tester,
  ) async {
    final client = FakeClient()
      ..contexts.addAll([withShift, noShift])
      ..summaries.addAll([openCashSummary, closedCashSummary])
      ..onClose = (_, _) async => throw const PosCoreTransportFailure('lost');
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close Shift'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('closing-cash-input')),
      '800.00',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Reconcile & Close'));
    await tester.pumpAndSettle();
    expect(find.text('Shift Closed'), findsNothing);
    expect(
      find.text(
        'Close Shift result could not be confirmed. Refresh Register State.',
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Refresh Register State'));
    await tester.tap(find.text('Refresh Register State'));
    await tester.pumpAndSettle();
    expect(client.closeCalls, 1);
    expect(find.text('Shift Closed'), findsOneWidget);
    expect(find.text('-\$9.99'), findsOneWidget);
  });
}
