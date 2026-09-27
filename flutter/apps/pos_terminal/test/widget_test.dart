import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/app/pos_terminal_app.dart';
import 'package:pos_terminal/core/pos_core/authentication_client.dart';
import 'package:pos_terminal/core/pos_core/models/authentication.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/canonical_receipt.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_health.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_readiness.dart';
import 'package:pos_terminal/core/pos_core/models/register_operations.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/core/pos_core/pos_core_client.dart';
import 'package:pos_terminal/features/cashier/cashier_id_generator.dart';
import 'package:pos_terminal/features/cashier/cashier_session_controller.dart';
import 'package:pos_terminal/features/cashier/cashier_session_store.dart';
import 'package:pos_terminal/features/authentication/authentication_controller.dart';

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
  int registerContextRequests = 0;
  String shiftCashierId = 'operator-test';

  Future<RegisterContext> fetchRegisterContext() async {
    registerContextRequests += 1;
    return RegisterContext(
      configured: true,
      register: RegisterIdentity(
        registerId: 'register-test',
        displayName: 'Test Register',
      ),
      activeShift: RegisterShift(
        shiftId: 'shift-test',
        registerId: 'register-test',
        registerDisplayName: 'Test Register',
        cashierId: shiftCashierId,
        cashierDisplayName: 'Test Cashier',
        openedAtEpochMs: 0,
        closedAtEpochMs: null,
        activeTransactionId: null,
      ),
    );
  }

  Future<List<CashierIdentity>> fetchActiveCashiers() async => const [];

  Future<ShiftOperationResult> openShift(int openingCashMinorUnits) =>
      throw UnimplementedError();

  Future<ShiftOperationResult> closeShift(
    String shiftId,
    int countedCashMinorUnits,
  ) => throw UnimplementedError();

  Future<ShiftCashSummary> fetchShiftCashSummary(String shiftId) async =>
      const ShiftCashSummary(
        shiftId: 'shift-test',
        status: ShiftCashStatus.open,
        view: ShiftCashSummaryView.limited,
        openingCashMinorUnits: null,
        completedCashSaleCount: null,
        cashSalesMinorUnits: null,
        expectedCashMinorUnits: null,
        countedCashMinorUnits: null,
        overShortMinorUnits: null,
      );
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
  Future<PosCoreReadiness> fetchReadiness() async => PosCoreReadiness.fromJson({
    'ok': true,
    'service': 'grocery-pos-core',
    'status': 'ready',
    'database_schema_version': 9,
  });

  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) {
    throw UnimplementedError();
  }
}

final class FakeAuthenticationClient implements PosAuthenticationClient {
  FakeAuthenticationClient({
    this.loginFailure,
    this.logoutFailure,
    this.loginResult,
  });

  Object? loginFailure;
  Object? logoutFailure;
  Object? changePinFailure;
  AuthenticationLogin? loginResult;
  int logoutRequests = 0;
  int changePinRequests = 0;
  String? submittedCurrentPin;
  String? submittedNewPin;
  String? logoutToken;

  static const session = AuthenticatedOperatorSession(
    operatorId: 'operator-test',
    displayName: 'Operator Test',
    role: 'cashier',
    idleTimeoutSeconds: 300,
    absoluteExpiresAtEpochMs: 9999999999999,
  );

  @override
  Future<AuthenticationLogin> login(String operatorId, String pin) async {
    if (loginFailure case final failure?) throw failure;
    return loginResult ??
        const AuthenticationLogin(
          accessToken:
              'gpos_s1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          session: session,
        );
  }

  @override
  Future<AuthenticatedOperatorSession> fetchAuthenticatedSession() async =>
      session;

  @override
  Future<void> logout(String accessToken) async {
    logoutRequests += 1;
    logoutToken = accessToken;
    if (logoutFailure case final failure?) throw failure;
  }

  @override
  Future<int> changePin(String currentPin, String newPin) async {
    changePinRequests += 1;
    submittedCurrentPin = currentPin;
    submittedNewPin = newPin;
    if (changePinFailure case final failure?) throw failure;
    return 2;
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
  Future<PosCoreReadiness> fetchReadiness() async => PosCoreReadiness.fromJson({
    'ok': true,
    'service': 'grocery-pos-core',
    'status': 'ready',
    'database_schema_version': 9,
  });

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
  Future<PosCoreReadiness> fetchReadiness() => throw UnimplementedError();

  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) {
    throw UnimplementedError();
  }

  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) {
    throw UnimplementedError();
  }
}

PosTerminalApp testApp(
  PosCoreClient client, {
  bool authenticated = false,
  PosAuthenticationClient? authenticationClient,
  MemoryAuthenticationSession? memory,
  CashierSessionStore? cashierStore,
}) {
  final authenticationMemory = memory ?? MemoryAuthenticationSession();
  if (authenticated) {
    authenticationMemory.establish(
      const AuthenticationLogin(
        accessToken:
            'gpos_s1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        session: FakeAuthenticationClient.session,
      ),
    );
  }
  return PosTerminalApp(
    client: client,
    cashierController: CashierSessionController(
      client: client,
      idGenerator: FixedCashierIds(),
      sessionStore: cashierStore ?? MemoryCashierSessionStore(),
      currentOperatorId: () => authenticationMemory.session?.operatorId,
    ),
    authenticationController: AuthenticationController(
      client: authenticationClient ?? FakeAuthenticationClient(),
      sessionMemory: authenticationMemory,
    ),
  );
}

void main() {
  testWidgets('ready terminal starts locked without fetching protected state', (
    tester,
  ) async {
    final client = FakeConnectedPosCoreClient();
    await tester.pumpWidget(testApp(client));
    await tester.pumpAndSettle();

    expect(find.text('Register Locked'), findsOneWidget);
    expect(client.registerContextRequests, 0);
    expect(find.text('Test Register'), findsNothing);
  });

  testWidgets('successful login unlocks and clears the submitted PIN', (
    tester,
  ) async {
    final client = FakeConnectedPosCoreClient();
    await tester.pumpWidget(testApp(client));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('operator-id-input')),
      'operator-test',
    );
    await tester.enterText(
      find.byKey(const Key('operator-pin-input')),
      '80421637',
    );
    await tester.tap(find.byKey(const Key('operator-login-button')));
    await tester.pumpAndSettle();

    expect(find.text('Test Register'), findsOneWidget);
    expect(client.registerContextRequests, 1);
    expect(find.byKey(const Key('operator-pin-input')), findsNothing);
  });

  testWidgets(
    'PIN change clears fields, locks without logout, and keeps recovery',
    (tester) async {
      final client = FakeConnectedPosCoreClient();
      final memory = MemoryAuthenticationSession();
      final authentication = FakeAuthenticationClient();
      final cashierStore = MemoryCashierSessionStore()
        ..persisted = PersistedCashierSession(
          operatorId: 'operator-test',
          activeTransactionId: 'txn-pin-change',
          pendingCommand: ScanBarcodeCommand(
            commandId: 'cmd-pin-change',
            transactionId: 'txn-pin-change',
            expectedVersion: 1,
            barcode: '049000001234',
          ),
        );
      await tester.pumpWidget(
        testApp(
          client,
          authenticated: true,
          authenticationClient: authentication,
          memory: memory,
          cashierStore: cashierStore,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('change-pin-button')));
      await tester.pumpAndSettle();
      expect(find.text('Change PIN'), findsWidgets);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('current-pin-input')))
            .obscureText,
        isTrue,
      );
      await tester.enterText(
        find.byKey(const Key('current-pin-input')),
        '80421637',
      );
      await tester.enterText(
        find.byKey(const Key('new-pin-input')),
        '48295173',
      );
      await tester.enterText(
        find.byKey(const Key('confirm-new-pin-input')),
        '48295173',
      );
      await tester.tap(find.byKey(const Key('change-pin-submit')));
      await tester.pumpAndSettle();

      expect(authentication.changePinRequests, 1);
      expect(authentication.submittedCurrentPin, '80421637');
      expect(authentication.submittedNewPin, '48295173');
      expect(authentication.logoutRequests, 0);
      expect(memory.accessToken, isNull);
      expect(find.text('Register Locked'), findsOneWidget);
      expect(find.byKey(const Key('register-lock-message')), findsOneWidget);
      expect(find.byKey(const Key('current-pin-input')), findsNothing);
      expect(
        cashierStore.persisted!.pendingCommand!.commandId,
        'cmd-pin-change',
      );
    },
  );

  testWidgets(
    'lost PIN-change response clears dialog and locks without retry',
    (tester) async {
      final client = FakeConnectedPosCoreClient();
      final memory = MemoryAuthenticationSession();
      final authentication = FakeAuthenticationClient()
        ..changePinFailure = const PosCoreTransportFailure('Lost response.');
      final cashierStore = MemoryCashierSessionStore()
        ..persisted = PersistedCashierSession(
          operatorId: 'operator-test',
          activeTransactionId: 'txn-pin-uncertain',
          pendingCommand: ScanBarcodeCommand(
            commandId: 'cmd-pin-uncertain',
            transactionId: 'txn-pin-uncertain',
            expectedVersion: 1,
            barcode: '049000001234',
          ),
        );
      await tester.pumpWidget(
        testApp(
          client,
          authenticated: true,
          authenticationClient: authentication,
          memory: memory,
          cashierStore: cashierStore,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('change-pin-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('current-pin-input')),
        '80421637',
      );
      await tester.enterText(
        find.byKey(const Key('new-pin-input')),
        '48295173',
      );
      await tester.enterText(
        find.byKey(const Key('confirm-new-pin-input')),
        '48295173',
      );
      await tester.tap(find.byKey(const Key('change-pin-submit')));
      await tester.pumpAndSettle();

      expect(authentication.changePinRequests, 1);
      expect(authentication.logoutRequests, 0);
      expect(memory.accessToken, isNull);
      expect(find.text('Register Locked'), findsOneWidget);
      expect(find.byKey(const Key('current-pin-input')), findsNothing);
      expect(find.byKey(const Key('new-pin-input')), findsNothing);
      expect(find.byKey(const Key('confirm-new-pin-input')), findsNothing);
      expect(
        cashierStore.persisted!.pendingCommand!.commandId,
        'cmd-pin-uncertain',
      );
    },
  );

  testWidgets('generic login failure remains locked and clears PIN input', (
    tester,
  ) async {
    final client = FakeConnectedPosCoreClient();
    final auth = FakeAuthenticationClient(
      loginFailure: const PosCoreServerFailure(
        code: 'authentication_failed',
        message: 'Operator sign-in failed.',
        statusCode: 401,
      ),
    );
    await tester.pumpWidget(testApp(client, authenticationClient: auth));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('operator-id-input')),
      'operator-test',
    );
    await tester.enterText(
      find.byKey(const Key('operator-pin-input')),
      '80421638',
    );
    await tester.tap(find.byKey(const Key('operator-login-button')));
    await tester.pumpAndSettle();

    expect(find.text('Register Locked'), findsOneWidget);
    expect(find.byKey(const Key('authentication-failure')), findsOneWidget);
    final pinField = tester.widget<TextField>(
      find.byKey(const Key('operator-pin-input')),
    );
    expect(pinField.controller!.text, isEmpty);
    expect(client.registerContextRequests, 0);
  });

  testWidgets('manual lock survives logout failure and preserves recovery', (
    tester,
  ) async {
    final client = FakeConnectedPosCoreClient();
    final memory = MemoryAuthenticationSession();
    final authentication = FakeAuthenticationClient(
      logoutFailure: const PosCoreTransportFailure('Connection refused.'),
    );
    final cashierStore = MemoryCashierSessionStore()
      ..persisted = PersistedCashierSession(
        operatorId: 'operator-test',
        activeTransactionId: 'txn-manual-lock',
        pendingCommand: ScanBarcodeCommand(
          commandId: 'cmd-manual-lock',
          transactionId: 'txn-manual-lock',
          expectedVersion: 1,
          barcode: '049000001234',
        ),
      );
    await tester.pumpWidget(
      testApp(
        client,
        authenticated: true,
        authenticationClient: authentication,
        memory: memory,
        cashierStore: cashierStore,
      ),
    );
    await tester.pumpAndSettle();
    expect(memory.authenticated, isTrue);

    await tester.tap(find.byKey(const Key('register-lock-button')));
    await tester.pumpAndSettle();

    expect(find.text('Register Locked'), findsOneWidget);
    expect(memory.accessToken, isNull);
    expect(find.text('Test Register'), findsNothing);
    expect(authentication.logoutRequests, 1);
    expect(
      authentication.logoutToken,
      'gpos_s1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(cashierStore.persisted!.activeTransactionId, 'txn-manual-lock');
    expect(
      cashierStore.persisted!.pendingCommand!.commandId,
      'cmd-manual-lock',
    );
  });

  testWidgets(
    'operator switch destroys protected navigation and reloads fresh state',
    (tester) async {
      final client = FakeConnectedPosCoreClient()..shiftCashierId = 'alice';
      const aliceSession = AuthenticatedOperatorSession(
        operatorId: 'alice',
        displayName: 'Alice',
        role: 'cashier',
        idleTimeoutSeconds: 300,
        absoluteExpiresAtEpochMs: 9999999999999,
      );
      const bobSession = AuthenticatedOperatorSession(
        operatorId: 'bob',
        displayName: 'Bob',
        role: 'cashier',
        idleTimeoutSeconds: 300,
        absoluteExpiresAtEpochMs: 9999999999999,
      );
      final memory = MemoryAuthenticationSession()
        ..establish(
          const AuthenticationLogin(
            accessToken:
                'gpos_s1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            session: aliceSession,
          ),
        );
      final authentication = FakeAuthenticationClient(
        loginResult: const AuthenticationLogin(
          accessToken:
              'gpos_s1_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          session: bobSession,
        ),
      );
      final cashierStore = MemoryCashierSessionStore()
        ..persisted = PersistedCashierSession(
          operatorId: 'alice',
          activeTransactionId: 'txn-pending',
          pendingCommand: ScanBarcodeCommand(
            commandId: 'cmd-pending',
            transactionId: 'txn-pending',
            expectedVersion: 1,
            barcode: '049000001234',
          ),
        );
      await tester.pumpWidget(
        testApp(
          client,
          authenticationClient: authentication,
          memory: memory,
          cashierStore: cashierStore,
        ),
      );
      await tester.pumpAndSettle();
      expect(client.registerContextRequests, 1);
      await tester.tap(find.text('Open Register'));
      await tester.pumpAndSettle();
      expect(find.text('Grocery POS'), findsOneWidget);

      memory.clear();
      await tester.pump();
      expect(find.text('Grocery POS'), findsNothing);
      expect(find.text('Register Locked'), findsOneWidget);
      await tester.pumpAndSettle();

      expect(find.text('Register Locked'), findsOneWidget);
      expect(cashierStore.persisted!.activeTransactionId, 'txn-pending');
      expect(cashierStore.persisted!.pendingCommand!.commandId, 'cmd-pending');

      await tester.enterText(find.byKey(const Key('operator-id-input')), 'bob');
      await tester.enterText(
        find.byKey(const Key('operator-pin-input')),
        '80421637',
      );
      await tester.tap(find.byKey(const Key('operator-login-button')));
      await tester.pumpAndSettle();

      expect(memory.session!.operatorId, 'bob');
      expect(client.registerContextRequests, 2);
      expect(find.text('Register In Use'), findsOneWidget);
      expect(find.text('Open Register'), findsNothing);
      expect(find.text('Grocery POS'), findsNothing);
      expect(
        Navigator.of(tester.element(find.text('Register In Use'))).canPop(),
        isFalse,
      );
      expect(cashierStore.persisted!.activeTransactionId, 'txn-pending');
      expect(cashierStore.persisted!.pendingCommand!.commandId, 'cmd-pending');
    },
  );

  testWidgets('shows connected state when POS Core is healthy', (tester) async {
    await tester.pumpWidget(
      testApp(FakeConnectedPosCoreClient(), authenticated: true),
    );

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
    await tester.pumpWidget(
      testApp(FakeConnectedPosCoreClient(), authenticated: true),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open Register'));
    await tester.pumpAndSettle();

    expect(find.text('Grocery POS'), findsOneWidget);
    expect(find.text('Start Sale'), findsOneWidget);
  });

  testWidgets('connected gateway opens exact completed-sale lookup', (
    tester,
  ) async {
    await tester.pumpWidget(
      testApp(FakeConnectedPosCoreClient(), authenticated: true),
    );
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
