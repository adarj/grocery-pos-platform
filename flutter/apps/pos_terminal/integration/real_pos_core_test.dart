import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/authentication_client.dart';
import 'package:pos_terminal/core/pos_core/http_pos_core_client.dart';
import 'package:pos_terminal/core/pos_core/models/authentication.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_readiness.dart';
import 'package:pos_terminal/core/pos_core/models/register_operations.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/features/cashier/cashier_id_generator.dart';
import 'package:pos_terminal/features/cashier/cashier_session_controller.dart';
import 'package:pos_terminal/features/cashier/cashier_session_store.dart';
import 'package:pos_terminal/features/cashier/file_cashier_session_store.dart';
import 'package:pos_terminal/features/authentication/authentication_controller.dart';

import 'support/real_pos_core_fixture.dart';

const _developmentBarcode = '049000001234';
const _developmentDescription = 'Test Apples';
const _developmentUnitPrice = 199;
const _developmentLineTax = 20;
const _developmentLineTotal = 219;
const _developmentRegisterId = 'register-development-01';
const _developmentRegisterName = 'Development Register 1';
const _developmentCashierId = 'cashier-development-01';
const _developmentCashierName = 'Development Cashier';
const _developmentOpeningCash = 10000;
const _developmentOperatorPin = '80421637';
const _authorizationTestPin = '58310472';

int _crashCampaignIterations() {
  final configured = Platform.environment['M6_CRASH_ITERATIONS'];
  if (configured == null) {
    return 3;
  }
  final parsed = int.tryParse(configured);
  if (parsed == null || parsed <= 0) {
    throw StateError('M6_CRASH_ITERATIONS must be a positive integer.');
  }
  return parsed;
}

final class _SequentialIntegrationIds implements CashierIdGenerator {
  _SequentialIntegrationIds(this.namespace);

  final String namespace;
  int commandIdCalls = 0;
  int transactionIdCalls = 0;

  @override
  String nextCommandId() {
    commandIdCalls += 1;
    return 'cmd_${namespace}_$commandIdCalls';
  }

  @override
  String nextTransactionId() {
    transactionIdCalls += 1;
    return 'txn_${namespace}_$transactionIdCalls';
  }
}

final class _IntegrationCashier {
  _IntegrationCashier._({
    required this.client,
    required this.controller,
    required this.store,
    required this.ids,
  });

  static Future<_IntegrationCashier> create(
    RealPosCoreFixture fixture,
    String namespace,
  ) async {
    final client = await _authenticatedClient(fixture);
    final store = FileCashierSessionStore(filePath: fixture.recoveryFilePath);
    final ids = _SequentialIntegrationIds(namespace);
    final controller = CashierSessionController(
      client: client,
      idGenerator: ids,
      sessionStore: store,
      currentOperatorId: () => client.authenticationSession.session?.operatorId,
    );
    await controller.restoreLocalSession();
    return _IntegrationCashier._(
      client: client,
      controller: controller,
      store: store,
      ids: ids,
    );
  }

  final HttpPosCoreClient client;
  final CashierSessionController controller;
  final FileCashierSessionStore store;
  final _SequentialIntegrationIds ids;
  bool _closed = false;

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    controller.dispose();
    client.close();
  }
}

Future<RealPosCoreFixture> _startFixture({bool openShift = true}) async {
  final fixture = await RealPosCoreFixture.create();
  addTearDown(fixture.dispose);
  await fixture.start();
  if (openShift) {
    await _openDevelopmentShift(fixture);
  }
  return fixture;
}

Future<RegisterShift> _openDevelopmentShift(RealPosCoreFixture fixture) async {
  final client = await _authenticatedClient(fixture);
  try {
    return (await client.openShift(_developmentOpeningCash)).shift;
  } finally {
    client.close();
  }
}

Future<HttpPosCoreClient> _authenticatedClient(
  RealPosCoreFixture fixture,
) async {
  return _authenticatedClientFor(
    fixture,
    _developmentCashierId,
    _developmentOperatorPin,
  );
}

Future<HttpPosCoreClient> _authenticatedClientFor(
  RealPosCoreFixture fixture,
  String operatorId,
  String pin,
) async {
  final client = HttpPosCoreClient(
    baseUri: fixture.baseUri,
    timeout: const Duration(seconds: 3),
  );
  try {
    final login = await client.login(operatorId, pin);
    client.authenticationSession.establish(login);
    return client;
  } catch (error) {
    client.close();
    throw StateError(
      'Integration operator $operatorId could not authenticate: $error\n'
      '${fixture.diagnostics()}',
    );
  }
}

Future<void> _authenticateAs(
  HttpPosCoreClient client,
  String operatorId,
  String pin,
) async {
  final login = await client.login(operatorId, pin);
  client.authenticationSession.establish(login);
}

Future<ShiftOperationResult> _closeAtExpectedCash(
  HttpPosCoreClient client,
  String shiftId,
) async {
  final summary = await client.fetchShiftCashSummary(shiftId);
  return client.closeShift(shiftId, summary.expectedCashMinorUnits!);
}

Future<_IntegrationCashier> _createCashier(
  RealPosCoreFixture fixture,
  String namespace,
) async {
  final cashier = await _IntegrationCashier.create(fixture, namespace);
  addTearDown(cashier.close);
  return cashier;
}

TransactionSnapshot _snapshot(CashierSessionController controller) {
  final snapshot = controller.state.snapshot;
  expect(snapshot, isNotNull);
  return snapshot!;
}

void _expectOpenEmpty(TransactionSnapshot snapshot) {
  expect(snapshot.status, TransactionStatus.open);
  expect(snapshot.version, 1);
  expect(snapshot.lineItems, isEmpty);
  expect(snapshot.subtotalMinorUnits, 0);
  expect(snapshot.taxMinorUnits, 0);
  expect(snapshot.totalMinorUnits, 0);
  expect(snapshot.tenderedCashMinorUnits, isNull);
  expect(snapshot.changeDueMinorUnits, isNull);
}

void _expectDevelopmentItem(TransactionLineItem item) {
  expect(item.barcode, _developmentBarcode);
  expect(item.description, _developmentDescription);
  expect(item.unitPriceMinorUnits, _developmentUnitPrice);
}

Future<void> _scanThreeTimes(CashierSessionController controller) async {
  for (var count = 1; count <= 3; count += 1) {
    await controller.scanBarcode(_developmentBarcode);
    final snapshot = _snapshot(controller);
    expect(snapshot.status, TransactionStatus.open);
    expect(snapshot.version, count + 1);
    expect(snapshot.lineItems, hasLength(count));
    for (final item in snapshot.lineItems) {
      _expectDevelopmentItem(item);
    }
    expect(snapshot.subtotalMinorUnits, _developmentUnitPrice * count);
    expect(snapshot.taxMinorUnits, _developmentLineTax * count);
    expect(snapshot.totalMinorUnits, _developmentLineTotal * count);
  }
}

void main() {
  final ordinaryTestHttpOverrides = HttpOverrides.current;
  final crashCampaignIterations = _crashCampaignIterations();
  setUpAll(() {
    // This explicitly invoked suite tests real loopback HTTP. flutter_test's
    // default override returns synthetic 400 responses for all network calls.
    HttpOverrides.global = null;
  });
  tearDownAll(() {
    HttpOverrides.global = ordinaryTestHttpOverrides;
  });

  test('real process rejects unsafe host before database startup', () async {
    final fixture = await RealPosCoreFixture.create();
    addTearDown(fixture.dispose);
    final result = await Process.run(
      'racket',
      const ['main.rkt'],
      workingDirectory: fixture.posBackendDirectoryPath,
      environment: {
        ...Platform.environment,
        'RACKET_API_HOST': '0.0.0.0',
        'RACKET_API_PORT': '7340',
        'SQLITE_DB_PATH': fixture.databasePath,
      },
    ).timeout(const Duration(seconds: 30));

    expect(result.exitCode, isNot(0));
    expect(await File(fixture.databasePath).exists(), isFalse);
  });

  test(
    'live process remains healthy when authoritative DB becomes unavailable',
    () async {
      final fixture = await _startFixture(openShift: false);
      final client = HttpPosCoreClient(
        baseUri: fixture.baseUri,
        timeout: const Duration(seconds: 3),
      );
      addTearDown(client.close);

      final initiallyReady = await client.fetchReadiness();
      expect(initiallyReady.ready, isTrue);
      expect(initiallyReady.databaseSchemaVersion, 9);

      await File(
        fixture.databasePath,
      ).rename('${fixture.databasePath}.offline');

      final health = await client.fetchHealth();
      expect(health.ok, isTrue);
      final unavailable = await client.fetchReadiness();
      expect(unavailable.ready, isFalse);
      expect(unavailable.reason, PosCoreReadinessReason.databaseMissing);
    },
  );

  test('repeated readiness probes do not leak process descriptors', () async {
    expect(Platform.isLinux, isTrue);
    final fixture = await _startFixture(openShift: false);
    final client = HttpPosCoreClient(
      baseUri: fixture.baseUri,
      timeout: const Duration(seconds: 3),
    );
    addTearDown(client.close);

    final descriptorDirectory = Directory('/proc/${fixture.processId}/fd');
    final before = await descriptorDirectory.list().length;
    for (var attempt = 0; attempt < 200; attempt += 1) {
      final readiness = await client.fetchReadiness();
      expect(readiness.ready, isTrue);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final after = await descriptorDirectory.list().length;

    // This is deliberately broad leak detection, not a performance target.
    // Persistent listener/pool bookkeeping may legitimately retain a small
    // number of descriptors, but request count must not drive linear growth.
    expect(after, lessThanOrEqualTo(before + 8));
  });

  test(
    'real operational startup exposes configuration and opens one shift',
    () async {
      final fixture = await _startFixture(openShift: false);
      final client = await _authenticatedClient(fixture);
      addTearDown(client.close);

      final before = await client.fetchRegisterContext();
      expect(before.configured, isTrue);
      expect(before.register!.registerId, _developmentRegisterId);
      expect(before.register!.displayName, _developmentRegisterName);
      expect(before.activeShift, isNull);

      final cashiers = await client.fetchActiveCashiers();
      expect(cashiers, hasLength(1));
      expect(cashiers.single.cashierId, _developmentCashierId);
      expect(cashiers.single.displayName, _developmentCashierName);

      final opened = await client.openShift(_developmentOpeningCash);
      expect(opened.shift.shiftId, isNotEmpty);
      expect(opened.shift.registerId, _developmentRegisterId);
      expect(opened.shift.registerDisplayName, _developmentRegisterName);
      expect(opened.shift.cashierId, _developmentCashierId);
      expect(opened.shift.cashierDisplayName, _developmentCashierName);
      expect(opened.shift.closedAtEpochMs, isNull);
      expect(opened.shift.activeTransactionId, isNull);
      expect(opened.cashSummary.openingCashMinorUnits, _developmentOpeningCash);

      final repeated = await client.openShift(999);
      expect(repeated.shift.shiftId, opened.shift.shiftId);
      expect(
        repeated.cashSummary.openingCashMinorUnits,
        _developmentOpeningCash,
      );
      expect(
        (await client.fetchRegisterContext()).activeShift!.shiftId,
        opened.shift.shiftId,
      );
    },
  );

  test(
    'real multi-operator authorization enforces role and ownership',
    () async {
      final fixture = await RealPosCoreFixture.create();
      addTearDown(fixture.dispose);
      await fixture.prepareReferenceData();
      final configurationFile = File(
        '${fixture.temporaryDirectory.path}${Platform.pathSeparator}'
        'authorization-register-configuration-v1.json',
      );
      const operators = <(String, String, String)>[
        ('cashier-alice', 'Alice Cashier', 'cashier'),
        ('cashier-bob', 'Bob Cashier', 'cashier'),
        ('supervisor-sam', 'Sam Supervisor', 'supervisor'),
        (_developmentCashierId, 'Morgan Manager', 'manager'),
      ];
      await configurationFile.writeAsString(
        jsonEncode({
          'schema_version': 1,
          'register': {
            'register_id': _developmentRegisterId,
            'display_name': _developmentRegisterName,
          },
          'cashiers': [
            for (final (operatorId, displayName, _) in operators)
              {
                'cashier_id': operatorId,
                'display_name': displayName,
                'active': true,
              },
          ],
        }),
        flush: true,
      );
      await fixture.activateOperationalConfigurationSnapshot(
        configurationFile.path,
      );
      await fixture.enrollIntegrationOperators(
        operators: <(String, String)>[
          for (final (operatorId, _, role) in operators)
            if (operatorId != _developmentCashierId) (operatorId, role),
        ],
        pin: _authorizationTestPin,
      );
      await fixture.start();

      final alice = await _authenticatedClientFor(
        fixture,
        'cashier-alice',
        _authorizationTestPin,
      );
      addTearDown(alice.close);
      final aliceShift = await alice.openShift(10000);
      expect(aliceShift.shift.cashierId, 'cashier-alice');
      expect(aliceShift.cashSummary.view, ShiftCashSummaryView.limited);

      final start = StartTransactionCommand(
        commandId: 'cmd_cp3_actor_restart',
        transactionId: 'txn_cp3_actor_restart',
        expectedVersion: 0,
      );
      expect((await alice.executeCommand(start)).accepted, isTrue);

      await fixture.killAbruptly();
      await fixture.start();
      final aliceAfterRestart = await _authenticatedClientFor(
        fixture,
        'cashier-alice',
        _authorizationTestPin,
      );
      addTearDown(aliceAfterRestart.close);
      final recovered = await aliceAfterRestart.executeCommand(start);
      expect(recovered.outcomeKind, PosCommandOutcomeKind.accepted);
      expect(recovered.outcomeStreamVersion, 1);

      final bob = aliceAfterRestart;
      await _authenticateAs(bob, 'cashier-bob', _authorizationTestPin);
      await expectLater(
        bob.executeCommand(start),
        throwsA(
          isA<PosCoreServerFailure>()
              .having((failure) => failure.statusCode, 'statusCode', 403)
              .having(
                (failure) => failure.code,
                'code',
                'authorization_denied',
              ),
        ),
      );
      await expectLater(
        bob.fetchTransaction(start.transactionId),
        throwsA(
          isA<PosCoreServerFailure>()
              .having((failure) => failure.statusCode, 'statusCode', 404)
              .having(
                (failure) => failure.code,
                'code',
                'transaction_not_found',
              ),
        ),
      );

      final sam = aliceAfterRestart;
      await _authenticateAs(sam, 'supervisor-sam', _authorizationTestPin);
      expect(
        (await sam.fetchTransaction(start.transactionId)).transactionId,
        start.transactionId,
      );
      expect(await sam.fetchActiveCashiers(), hasLength(4));
      expect(
        (await sam.fetchShiftCashSummary(aliceShift.shift.shiftId)).view,
        ShiftCashSummaryView.full,
      );
      await expectLater(
        sam.executeCommand(
          ScanBarcodeCommand(
            commandId: 'cmd_sam_foreign_scan',
            transactionId: start.transactionId,
            expectedVersion: 1,
            barcode: _developmentBarcode,
          ),
        ),
        throwsA(
          isA<PosCoreServerFailure>().having(
            (failure) => failure.code,
            'code',
            'authorization_denied',
          ),
        ),
      );

      final morgan = aliceAfterRestart;
      await _authenticateAs(
        morgan,
        _developmentCashierId,
        _developmentOperatorPin,
      );
      expect(
        (await morgan.fetchTransaction(start.transactionId)).transactionId,
        start.transactionId,
      );
      await expectLater(
        morgan.executeCommand(
          ScanBarcodeCommand(
            commandId: 'cmd_morgan_foreign_scan',
            transactionId: start.transactionId,
            expectedVersion: 1,
            barcode: _developmentBarcode,
          ),
        ),
        throwsA(
          isA<PosCoreServerFailure>().having(
            (failure) => failure.code,
            'code',
            'authorization_denied',
          ),
        ),
      );

      final aliceAgain = aliceAfterRestart;
      await _authenticateAs(aliceAgain, 'cashier-alice', _authorizationTestPin);
      await expectLater(
        aliceAgain.fetchActiveCashiers(),
        throwsA(
          isA<PosCoreServerFailure>().having(
            (failure) => failure.code,
            'code',
            'authorization_denied',
          ),
        ),
      );
      final limited = await aliceAgain.fetchShiftCashSummary(
        aliceShift.shift.shiftId,
      );
      expect(limited.view, ShiftCashSummaryView.limited);
      expect(limited.expectedCashMinorUnits, isNull);

      final commands = <TransactionCommand>[
        ScanBarcodeCommand(
          commandId: 'cmd_alice_scan',
          transactionId: start.transactionId,
          expectedVersion: 1,
          barcode: _developmentBarcode,
        ),
        TenderCashCommand(
          commandId: 'cmd_alice_tender',
          transactionId: start.transactionId,
          expectedVersion: 2,
          amountMinorUnits: 500,
        ),
        CompleteTransactionCommand(
          commandId: 'cmd_alice_complete',
          transactionId: start.transactionId,
          expectedVersion: 3,
        ),
      ];
      for (final command in commands) {
        expect((await aliceAgain.executeCommand(command)).accepted, isTrue);
      }
      final closedAlice = await aliceAgain.closeShift(
        aliceShift.shift.shiftId,
        10219,
      );
      expect(closedAlice.cashSummary.view, ShiftCashSummaryView.full);
      expect(closedAlice.cashSummary.overShortMinorUnits, 0);
      final recoveredAfterClose = await aliceAgain.executeCommand(start);
      expect(recoveredAfterClose.outcomeKind, PosCommandOutcomeKind.accepted);
      expect(recoveredAfterClose.outcomeStreamVersion, 1);

      final bobAgain = aliceAfterRestart;
      await _authenticateAs(bobAgain, 'cashier-bob', _authorizationTestPin);
      await expectLater(
        bobAgain.fetchReceipt(start.transactionId),
        throwsA(
          isA<PosCoreServerFailure>().having(
            (failure) => failure.code,
            'code',
            'transaction_not_found',
          ),
        ),
      );
      final bobShift = await bobAgain.openShift(5000);

      final managerAgain = aliceAfterRestart;
      await _authenticateAs(
        managerAgain,
        _developmentCashierId,
        _developmentOperatorPin,
      );
      expect(
        (await managerAgain.fetchReceipt(start.transactionId)).transactionId,
        start.transactionId,
      );
      final managerClose = await managerAgain.closeShift(
        bobShift.shift.shiftId,
        5000,
      );
      expect(managerClose.shift.cashierId, 'cashier-bob');
      expect(managerClose.cashSummary.view, ShiftCashSummaryView.full);
    },
  );

  test(
    'manual register lock reaches Core logout and revokes the bearer',
    () async {
      final fixture = await _startFixture(openShift: false);
      final anonymous = HttpPosCoreClient(
        baseUri: fixture.baseUri,
        timeout: const Duration(seconds: 3),
      );
      addTearDown(anonymous.close);

      expect((await anonymous.fetchReadiness()).ready, isTrue);
      await expectLater(
        anonymous.fetchRegisterContext(),
        throwsA(
          isA<PosCoreServerFailure>()
              .having((failure) => failure.statusCode, 'statusCode', 401)
              .having(
                (failure) => failure.code,
                'code',
                'authentication_required',
              ),
        ),
      );

      final memory = MemoryAuthenticationSession();
      final authenticated = HttpPosCoreClient(
        baseUri: fixture.baseUri,
        authenticationSession: memory,
        timeout: const Duration(seconds: 3),
      );
      addTearDown(authenticated.close);
      final controller = AuthenticationController(
        client: authenticated,
        sessionMemory: memory,
      );
      addTearDown(controller.dispose);
      await controller.login(_developmentCashierId, _developmentOperatorPin);
      final session = controller.session!;
      expect(session.operatorId, _developmentCashierId);
      expect((await authenticated.fetchRegisterContext()).configured, isTrue);
      final token = memory.accessToken!;

      await controller.lock();
      expect(controller.status, AuthenticationStatus.locked);
      expect(memory.accessToken, isNull);

      final staleMemory = MemoryAuthenticationSession()
        ..establish(AuthenticationLogin(accessToken: token, session: session));
      final staleClient = HttpPosCoreClient(
        baseUri: fixture.baseUri,
        authenticationSession: staleMemory,
        timeout: const Duration(seconds: 3),
      );
      addTearDown(staleClient.close);
      await expectLater(
        staleClient.fetchRegisterContext(),
        throwsA(
          isA<PosCoreServerFailure>().having(
            (failure) => failure.code,
            'code',
            'authentication_required',
          ),
        ),
      );
      expect(staleMemory.authenticated, isFalse);
    },
  );

  test(
    'POS Core restart invalidates bearer while durable credential can relogin',
    () async {
      final fixture = await _startFixture(openShift: false);
      final firstMemory = MemoryAuthenticationSession();
      final first = HttpPosCoreClient(
        baseUri: fixture.baseUri,
        authenticationSession: firstMemory,
        timeout: const Duration(seconds: 3),
      );
      final firstLogin = await first.login(
        _developmentCashierId,
        _developmentOperatorPin,
      );
      firstMemory.establish(firstLogin);
      expect((await first.fetchRegisterContext()).configured, isTrue);
      first.close();

      await fixture.restart();
      final staleMemory = MemoryAuthenticationSession()..establish(firstLogin);
      final afterRestart = HttpPosCoreClient(
        baseUri: fixture.baseUri,
        authenticationSession: staleMemory,
        timeout: const Duration(seconds: 3),
      );
      addTearDown(afterRestart.close);
      await expectLater(
        afterRestart.fetchRegisterContext(),
        throwsA(
          isA<PosCoreServerFailure>().having(
            (failure) => failure.code,
            'code',
            'authentication_required',
          ),
        ),
      );
      expect(staleMemory.authenticated, isFalse);

      final replacement = await afterRestart.login(
        _developmentCashierId,
        _developmentOperatorPin,
      );
      staleMemory.establish(replacement);
      expect((await afterRestart.fetchRegisterContext()).configured, isTrue);
    },
  );

  test(
    '401 before mutation preserves exact command across reauthentication',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'auth_loss_retry');
      await cashier.controller.startTransaction();
      final before = _snapshot(cashier.controller);
      final token = cashier.client.authenticationSession.accessToken!;

      // Revoke only the server capability. The client learns of that loss on
      // the protected command, after it has durably written the exact command.
      await cashier.client.logout(token);
      await cashier.controller.scanBarcode(_developmentBarcode);

      final pending =
          cashier.controller.state.pendingCommand! as ScanBarcodeCommand;
      expect(pending.transactionId, before.transactionId);
      expect(pending.expectedVersion, before.version);
      expect(pending.barcode, _developmentBarcode);
      expect(cashier.client.authenticationSession.authenticated, isFalse);
      final persisted = await cashier.store.load();
      expect(persisted!.pendingCommand!.toJson(), pending.toJson());
      final commandIdCallsBeforeRetry = cashier.ids.commandIdCalls;

      final relogin = await cashier.client.login(
        _developmentCashierId,
        _developmentOperatorPin,
      );
      cashier.client.authenticationSession.establish(relogin);
      await cashier.controller.retryPendingCommand();

      final recovered = _snapshot(cashier.controller);
      expect(
        cashier.controller.state.lastCommandResult!.commandId,
        pending.commandId,
      );
      expect(recovered.version, 2);
      expect(recovered.lineItems, hasLength(1));
      expect(cashier.controller.state.pendingCommand, isNull);
      expect(cashier.ids.commandIdCalls, commandIdCallsBeforeRetry);
    },
  );

  test(
    'real health and full cash sale cross Flutter, HTTP, Racket, and SQLite',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'full_sale');

      final health = await cashier.client.fetchHealth();
      expect(health.ok, isTrue);
      expect(health.service, 'grocery-pos-core');
      expect(cashier.controller.state.activeTransactionId, isNull);

      await cashier.controller.startTransaction();
      final firstTransactionId = _snapshot(cashier.controller).transactionId;
      _expectOpenEmpty(_snapshot(cashier.controller));
      final activeAfterStart = await cashier.client.fetchRegisterContext();
      expect(
        activeAfterStart.activeShift!.activeTransactionId,
        firstTransactionId,
      );

      await cashier.controller.scanBarcode(_developmentBarcode);
      final scanned = _snapshot(cashier.controller);
      expect(scanned.status, TransactionStatus.open);
      expect(scanned.version, 2);
      expect(scanned.lineItems, hasLength(1));
      _expectDevelopmentItem(scanned.lineItems.single);
      expect(scanned.subtotalMinorUnits, 199);
      expect(scanned.taxMinorUnits, 20);
      expect(scanned.totalMinorUnits, 219);

      // The base subtotal is 199, so 200 would have been sufficient before
      // tax. The real backend must reject it against the tax-inclusive 219.
      await cashier.controller.tenderCash(200);
      final insufficient = _snapshot(cashier.controller);
      expect(insufficient.status, TransactionStatus.open);
      expect(insufficient.version, 2);
      expect(
        cashier.controller.state.lastCommandResult!.outcomeKind,
        PosCommandOutcomeKind.domainRejected,
      );
      expect(
        cashier.controller.state.lastCommandResult!.outcomeCode,
        'insufficient_tender',
      );

      await cashier.controller.tenderCash(500);
      final paid = _snapshot(cashier.controller);
      expect(paid.status, TransactionStatus.paid);
      expect(paid.version, 3);
      expect(paid.taxMinorUnits, 20);
      expect(paid.totalMinorUnits, 219);
      expect(paid.tenderedCashMinorUnits, 500);
      expect(paid.changeDueMinorUnits, 281);

      await cashier.controller.completeTransaction();
      final completed = _snapshot(cashier.controller);
      expect(completed.status, TransactionStatus.completed);
      expect(completed.version, 4);
      final idleAfterCompletion = await cashier.client.fetchRegisterContext();
      expect(idleAfterCompletion.activeShift!.activeTransactionId, isNull);
      final cashSummary = await cashier.client.fetchShiftCashSummary(
        idleAfterCompletion.activeShift!.shiftId,
      );
      expect(cashSummary.openingCashMinorUnits, _developmentOpeningCash);
      expect(cashSummary.completedCashSaleCount, 1);
      expect(cashSummary.cashSalesMinorUnits, _developmentLineTotal);
      expect(
        cashSummary.expectedCashMinorUnits,
        _developmentOpeningCash + _developmentLineTotal,
      );

      final receipt = await cashier.client.fetchReceipt(firstTransactionId);
      expect(receipt.schemaVersion, 2);
      expect(receipt.register!.registerId, _developmentRegisterId);
      expect(receipt.register!.displayName, _developmentRegisterName);
      expect(receipt.cashier!.cashierId, _developmentCashierId);
      expect(receipt.cashier!.displayName, _developmentCashierName);
      expect(receipt.shiftId, idleAfterCompletion.activeShift!.shiftId);
      expect(receipt.startedAtEpochMs, isNotNull);
      expect(receipt.completedAtEpochMs, isNotNull);
      expect(
        receipt.completedAtEpochMs!,
        greaterThanOrEqualTo(receipt.startedAtEpochMs!),
      );

      await cashier.controller.beginNextSale();
      final nextSale = _snapshot(cashier.controller);
      expect(nextSale.transactionId, isNot(firstTransactionId));
      _expectOpenEmpty(nextSale);
    },
  );

  test(
    'three real sequential scans produce authoritative ordered facts',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'repeated_scans');

      await cashier.controller.startTransaction();
      await _scanThreeTimes(cashier.controller);

      final snapshot = _snapshot(cashier.controller);
      expect(snapshot.version, 4);
      expect(snapshot.lineItems.map((item) => item.description), [
        _developmentDescription,
        _developmentDescription,
        _developmentDescription,
      ]);
      expect(snapshot.taxMinorUnits, 60);
      expect(snapshot.totalMinorUnits, 657);
    },
  );

  test(
    'real removal preserves authoritative remaining tax and totals',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'remove_sale');

      await cashier.controller.startTransaction();
      await _scanThreeTimes(cashier.controller);

      await cashier.controller.removeLineItem(1);
      final corrected = _snapshot(cashier.controller);
      expect(corrected.status, TransactionStatus.open);
      expect(corrected.version, 5);
      expect(corrected.lineItems, hasLength(2));
      expect(corrected.subtotalMinorUnits, 398);
      expect(corrected.taxMinorUnits, 40);
      expect(corrected.totalMinorUnits, 438);

      await cashier.controller.tenderCash(500);
      final paid = _snapshot(cashier.controller);
      expect(paid.status, TransactionStatus.paid);
      expect(paid.totalMinorUnits, 438);
      expect(paid.changeDueMinorUnits, 62);

      await cashier.controller.completeTransaction();
      final completed = _snapshot(cashier.controller);
      expect(completed.status, TransactionStatus.completed);
      expect(completed.lineItems, hasLength(2));
      expect(completed.totalMinorUnits, 438);

      final receipt = await cashier.client.fetchReceipt(
        completed.transactionId,
      );
      expect(receipt.schemaVersion, 2);
      expect(receipt.transactionId, completed.transactionId);
      expect(receipt.transactionVersion, 7);
      expect(receipt.lineItems, hasLength(2));
      for (final line in receipt.lineItems) {
        expect(line.barcode, _developmentBarcode);
        expect(line.description, _developmentDescription);
        expect(line.unitPriceMinorUnits, 199);
        expect(line.taxCategoryId, 'development-standard');
        expect(line.taxRateMillionths, 100000);
        expect(line.taxAmountMinorUnits, 20);
      }
      expect(receipt.subtotalMinorUnits, 398);
      expect(receipt.taxMinorUnits, 40);
      expect(receipt.totalMinorUnits, 438);
      expect(receipt.tenderedCashMinorUnits, 500);
      expect(receipt.changeDueMinorUnits, 62);
      final cashSummary = await cashier.client.fetchShiftCashSummary(
        receipt.shiftId!,
      );
      expect(cashSummary.completedCashSaleCount, 1);
      expect(cashSummary.cashSalesMinorUnits, 438);
      expect(cashSummary.expectedCashMinorUnits, 10438);
    },
  );

  test(
    'same-ID real remove retry after backend restart removes one line only',
    () async {
      final fixture = await _startFixture();
      final firstCashier = await _createCashier(fixture, 'remove_retry_before');

      await firstCashier.controller.startTransaction();
      await _scanThreeTimes(firstCashier.controller);
      final beforeRemove = _snapshot(firstCashier.controller);
      final exactCommand = RemoveLineItemCommand(
        commandId: 'cmd_remove_stale_pending_exact',
        transactionId: beforeRemove.transactionId,
        expectedVersion: beforeRemove.version,
        lineIndex: 1,
      );
      await firstCashier.store.save(
        PersistedCashierSession(
          operatorId: _developmentCashierId,
          activeTransactionId: beforeRemove.transactionId,
          pendingCommand: exactCommand,
        ),
      );

      final committed = await firstCashier.client.executeCommand(exactCommand);
      expect(committed.outcomeKind, PosCommandOutcomeKind.accepted);
      expect(committed.outcomeStreamVersion, 5);

      firstCashier.close();
      await fixture.restart();
      final restoredCashier = await _createCashier(
        fixture,
        'remove_retry_after',
      );
      final restoredPending =
          restoredCashier.controller.state.pendingCommand!
              as RemoveLineItemCommand;
      expect(restoredPending.commandId, exactCommand.commandId);
      expect(restoredPending.transactionId, exactCommand.transactionId);
      expect(restoredPending.expectedVersion, exactCommand.expectedVersion);
      expect(restoredPending.lineIndex, exactCommand.lineIndex);
      expect(restoredCashier.ids.commandIdCalls, 0);

      await restoredCashier.controller.retryPendingCommand();
      final retryResult = restoredCashier.controller.state.lastCommandResult!;
      final authoritative = _snapshot(restoredCashier.controller);
      expect(retryResult.outcomeKind, PosCommandOutcomeKind.accepted);
      expect(retryResult.outcomeStreamVersion, 5);
      expect(authoritative.version, 5);
      expect(authoritative.lineItems, hasLength(2));
      expect(authoritative.subtotalMinorUnits, 398);
      expect(authoritative.taxMinorUnits, 40);
      expect(authoritative.totalMinorUnits, 438);
      expect(restoredCashier.controller.state.pendingCommand, isNull);
      expect(restoredCashier.ids.commandIdCalls, 0);
    },
  );

  test(
    'same-ID real completion retry records one net cash-sale movement',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'completion_cash_retry');
      final shiftId =
          (await cashier.client.fetchRegisterContext()).activeShift!.shiftId;

      await cashier.controller.startTransaction();
      await cashier.controller.scanBarcode(_developmentBarcode);
      await cashier.controller.tenderCash(500);
      final paid = _snapshot(cashier.controller);
      final exactCompletion = CompleteTransactionCommand(
        commandId: 'cmd_completion_cash_retry_exact',
        transactionId: paid.transactionId,
        expectedVersion: paid.version,
      );

      final first = await cashier.client.executeCommand(exactCompletion);
      final repeated = await cashier.client.executeCommand(exactCompletion);
      expect(first.outcomeKind, PosCommandOutcomeKind.accepted);
      expect(repeated.commandId, first.commandId);
      expect(repeated.outcomeKind, first.outcomeKind);
      expect(repeated.outcomeCode, first.outcomeCode);
      expect(repeated.outcomeStreamVersion, first.outcomeStreamVersion);

      final authoritative = await cashier.client.fetchTransaction(
        paid.transactionId,
      );
      expect(authoritative.status, TransactionStatus.completed);
      final summary = await cashier.client.fetchShiftCashSummary(shiftId);
      expect(summary.completedCashSaleCount, 1);
      expect(summary.cashSalesMinorUnits, _developmentLineTotal);
      expect(summary.expectedCashMinorUnits, 10219);
    },
  );

  test('real void survives restart and can begin a clean next sale', () async {
    final fixture = await _startFixture();
    final firstCashier = await _createCashier(fixture, 'void_before');

    await firstCashier.controller.startTransaction();
    await firstCashier.controller.scanBarcode(_developmentBarcode);
    await firstCashier.controller.voidTransaction();
    final beforeRestart = _snapshot(firstCashier.controller);
    final voidedTransactionId = beforeRestart.transactionId;
    expect(beforeRestart.status, TransactionStatus.voided);
    expect(beforeRestart.version, 3);
    expect(beforeRestart.lineItems, hasLength(1));
    expect(beforeRestart.subtotalMinorUnits, 199);
    expect(beforeRestart.taxMinorUnits, 20);
    expect(beforeRestart.totalMinorUnits, 219);
    expect(beforeRestart.tenderedCashMinorUnits, isNull);
    final voidedSummary = await firstCashier.client.fetchShiftCashSummary(
      (await firstCashier.client.fetchRegisterContext()).activeShift!.shiftId,
    );
    expect(voidedSummary.completedCashSaleCount, 0);
    expect(voidedSummary.cashSalesMinorUnits, 0);
    expect(voidedSummary.expectedCashMinorUnits, _developmentOpeningCash);
    expect(beforeRestart.changeDueMinorUnits, isNull);
    await expectLater(
      firstCashier.client.fetchReceipt(voidedTransactionId),
      throwsA(
        isA<PosCoreServerFailure>().having(
          (failure) => failure.code,
          'code',
          'receipt_not_available',
        ),
      ),
    );

    firstCashier.close();
    await fixture.restart();
    final restoredCashier = await _createCashier(fixture, 'void_after');
    expect(
      restoredCashier.controller.state.activeTransactionId,
      voidedTransactionId,
    );
    expect(restoredCashier.controller.state.snapshot, isNull);
    expect(restoredCashier.controller.state.pendingCommand, isNull);

    await restoredCashier.controller.refreshTransaction();
    final restored = _snapshot(restoredCashier.controller);
    expect(restored.transactionId, voidedTransactionId);
    expect(restored.status, TransactionStatus.voided);
    expect(restored.lineItems, hasLength(1));
    expect(restored.subtotalMinorUnits, 199);
    expect(restored.taxMinorUnits, 20);
    expect(restored.totalMinorUnits, 219);

    await restoredCashier.controller.beginNextSale();
    final nextSale = _snapshot(restoredCashier.controller);
    expect(nextSale.transactionId, isNot(voidedTransactionId));
    _expectOpenEmpty(nextSale);
  });

  test(
    'real shift close is blocked by an active sale and succeeds after void',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'close_protection');
      final shiftId =
          (await cashier.client.fetchRegisterContext()).activeShift!.shiftId;

      await cashier.controller.startTransaction();
      final transactionId = _snapshot(cashier.controller).transactionId;
      expect(
        (await cashier.client.fetchRegisterContext())
            .activeShift!
            .activeTransactionId,
        transactionId,
      );
      await expectLater(
        cashier.client.closeShift(shiftId, _developmentOpeningCash),
        throwsA(
          isA<PosCoreServerFailure>().having(
            (failure) => failure.code,
            'code',
            'shift_has_active_transaction',
          ),
        ),
      );

      await cashier.controller.voidTransaction();
      expect(_snapshot(cashier.controller).status, TransactionStatus.voided);
      expect(
        (await cashier.client.fetchRegisterContext())
            .activeShift!
            .activeTransactionId,
        isNull,
      );
      final closed = await _closeAtExpectedCash(cashier.client, shiftId);
      expect(closed.shift.closedAtEpochMs, isNotNull);
      expect((await cashier.client.fetchRegisterContext()).activeShift, isNull);
    },
  );

  test(
    'real exact reconciliation is recoverable after close response loss',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'exact_reconciliation');
      final shiftId =
          (await cashier.client.fetchRegisterContext()).activeShift!.shiftId;

      await cashier.controller.startTransaction();
      await cashier.controller.scanBarcode(_developmentBarcode);
      await cashier.controller.tenderCash(500);
      await cashier.controller.completeTransaction();
      final openSummary = await cashier.client.fetchShiftCashSummary(shiftId);
      expect(openSummary.openingCashMinorUnits, 10000);
      expect(openSummary.completedCashSaleCount, 1);
      expect(openSummary.cashSalesMinorUnits, 219);
      expect(openSummary.expectedCashMinorUnits, 10219);

      // Deliberately discard the trusted write result. The read resource is the
      // recovery boundary for an operational write whose response was lost.
      await cashier.client.closeShift(
        shiftId,
        openSummary.expectedCashMinorUnits!,
      );
      final recovered = await cashier.client.fetchShiftCashSummary(shiftId);
      expect(recovered.status, ShiftCashStatus.closed);
      expect(recovered.countedCashMinorUnits, 10219);
      expect(recovered.overShortMinorUnits, 0);

      cashier.close();
      await fixture.restart();
      final restoredCashier = await _createCashier(
        fixture,
        'exact_reconciliation_after',
      );
      final afterRestart = await restoredCashier.client.fetchShiftCashSummary(
        shiftId,
      );
      expect(afterRestart.status, ShiftCashStatus.closed);
      expect(
        afterRestart.expectedCashMinorUnits,
        recovered.expectedCashMinorUnits,
      );
      expect(
        afterRestart.countedCashMinorUnits,
        recovered.countedCashMinorUnits,
      );
      expect(afterRestart.overShortMinorUnits, recovered.overShortMinorUnits);
    },
  );

  test(
    'real shortage closes honestly after multiple completed cash sales',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'short_reconciliation');
      final shiftId =
          (await cashier.client.fetchRegisterContext()).activeShift!.shiftId;

      await cashier.controller.startTransaction();
      for (var sale = 0; sale < 2; sale += 1) {
        await cashier.controller.scanBarcode(_developmentBarcode);
        await cashier.controller.tenderCash(500);
        await cashier.controller.completeTransaction();
        if (sale == 0) await cashier.controller.beginNextSale();
      }
      final summary = await cashier.client.fetchShiftCashSummary(shiftId);
      expect(summary.completedCashSaleCount, 2);
      expect(summary.cashSalesMinorUnits, 438);
      expect(summary.expectedCashMinorUnits, 10438);
      final closed = await cashier.client.closeShift(
        shiftId,
        summary.expectedCashMinorUnits! - 25,
      );
      expect(closed.cashSummary.status, ShiftCashStatus.closed);
      expect(closed.cashSummary.countedCashMinorUnits, 10413);
      expect(closed.cashSummary.overShortMinorUnits, -25);
    },
  );

  test(
    'ten mixed sale cycles reconcile one shift without leaking state',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'endurance');
      final transactionIds = <String>{};
      var expectedCompletedSaleCount = 0;
      var expectedCashSales = 0;
      final shiftId =
          (await cashier.client.fetchRegisterContext()).activeShift!.shiftId;

      await cashier.controller.startTransaction();
      for (var cycle = 0; cycle < 10; cycle += 1) {
        final opened = _snapshot(cashier.controller);
        _expectOpenEmpty(opened);
        expect(transactionIds.add(opened.transactionId), isTrue);

        if (cycle == 3) {
          await cashier.controller.scanBarcode(_developmentBarcode);
          await cashier.controller.voidTransaction();
          expect(
            _snapshot(cashier.controller).status,
            TransactionStatus.voided,
          );
          if (cycle < 9) await cashier.controller.beginNextSale();
          continue;
        }

        await _scanThreeTimes(cashier.controller);
        if (cycle == 5) {
          await cashier.controller.removeLineItem(1);
          final corrected = _snapshot(cashier.controller);
          expect(corrected.lineItems, hasLength(2));
          expect(corrected.totalMinorUnits, 438);
        }
        await cashier.controller.tenderCash(1000);
        final paid = _snapshot(cashier.controller);
        expect(paid.status, TransactionStatus.paid);
        final expectedLineCount = cycle == 5 ? 2 : 3;
        final expectedTotal = cycle == 5 ? 438 : 657;
        expect(paid.lineItems, hasLength(expectedLineCount));
        expect(paid.totalMinorUnits, expectedTotal);
        expect(paid.tenderedCashMinorUnits, 1000);
        expect(paid.changeDueMinorUnits, 1000 - expectedTotal);

        await cashier.controller.completeTransaction();
        final completed = _snapshot(cashier.controller);
        expect(completed.status, TransactionStatus.completed);
        expect(completed.lineItems, hasLength(expectedLineCount));
        expect(completed.totalMinorUnits, expectedTotal);
        expectedCompletedSaleCount += 1;
        expectedCashSales += expectedTotal;
        final receipt = await cashier.client.fetchReceipt(
          completed.transactionId,
        );
        expect(receipt.schemaVersion, 2);
        expect(receipt.shiftId, shiftId);

        if (cycle < 9) {
          await cashier.controller.beginNextSale();
        }
      }
      expect(transactionIds, hasLength(10));
      expect(expectedCompletedSaleCount, 9);
      expect(expectedCashSales, 5694);
      final summary = await cashier.client.fetchShiftCashSummary(shiftId);
      expect(summary.completedCashSaleCount, expectedCompletedSaleCount);
      expect(summary.cashSalesMinorUnits, expectedCashSales);
      expect(
        summary.expectedCashMinorUnits,
        _developmentOpeningCash + expectedCashSales,
      );
      final closed = await cashier.client.closeShift(
        shiftId,
        summary.expectedCashMinorUnits! + 17,
      );
      expect(closed.shift.closedAtEpochMs, isNotNull);
      expect(closed.shift.activeTransactionId, isNull);
      expect(closed.cashSummary.overShortMinorUnits, 17);
      expect((await cashier.client.fetchRegisterContext()).activeShift, isNull);
      cashier.close();
      await fixture.restart();
      final restoredCashier = await _createCashier(fixture, 'endurance_after');
      final durableClosed = await restoredCashier.client.fetchShiftCashSummary(
        shiftId,
      );
      expect(durableClosed.status, ShiftCashStatus.closed);
      expect(durableClosed.completedCashSaleCount, 9);
      expect(durableClosed.cashSalesMinorUnits, 5694);
      expect(durableClosed.overShortMinorUnits, 17);
    },
  );

  test(
    'active sale survives Flutter and POS Core restart and continues',
    () async {
      final fixture = await _startFixture();
      final firstCashier = await _createCashier(fixture, 'active_before');

      await firstCashier.controller.startTransaction();
      await firstCashier.controller.scanBarcode(_developmentBarcode);
      final beforeRestart = _snapshot(firstCashier.controller);
      final transactionId = beforeRestart.transactionId;
      expect(beforeRestart.status, TransactionStatus.open);
      expect(beforeRestart.lineItems, hasLength(1));

      firstCashier.close();
      await fixture.restart();
      final restoredCashier = await _createCashier(fixture, 'active_after');

      final restoredContext = await restoredCashier.client
          .fetchRegisterContext();
      expect(restoredContext.activeShift!.activeTransactionId, transactionId);

      expect(
        restoredCashier.controller.state.activeTransactionId,
        transactionId,
      );
      expect(restoredCashier.controller.state.snapshot, isNull);
      expect(restoredCashier.controller.state.pendingCommand, isNull);
      expect(restoredCashier.ids.commandIdCalls, 0);

      await restoredCashier.controller.refreshTransaction();
      final restored = _snapshot(restoredCashier.controller);
      expect(restored.transactionId, transactionId);
      expect(restored.status, TransactionStatus.open);
      expect(restored.version, 2);
      expect(restored.lineItems, hasLength(1));
      expect(restored.taxMinorUnits, 20);
      expect(restored.totalMinorUnits, 219);

      await restoredCashier.controller.tenderCash(500);
      expect(
        _snapshot(restoredCashier.controller).status,
        TransactionStatus.paid,
      );
      await restoredCashier.controller.completeTransaction();
      expect(
        _snapshot(restoredCashier.controller).status,
        TransactionStatus.completed,
      );
      expect(
        (await restoredCashier.client.fetchRegisterContext())
            .activeShift!
            .activeTransactionId,
        isNull,
      );
    },
  );

  test('paid state and authoritative change survive both restarts', () async {
    final fixture = await _startFixture();
    final firstCashier = await _createCashier(fixture, 'paid_before');
    final shiftId =
        (await firstCashier.client.fetchRegisterContext()).activeShift!.shiftId;

    await firstCashier.controller.startTransaction();
    await firstCashier.controller.scanBarcode(_developmentBarcode);
    await firstCashier.controller.tenderCash(500);
    final beforeRestart = _snapshot(firstCashier.controller);
    final transactionId = beforeRestart.transactionId;
    expect(beforeRestart.status, TransactionStatus.paid);

    firstCashier.close();
    await fixture.restart();
    final restoredCashier = await _createCashier(fixture, 'paid_after');
    expect(restoredCashier.controller.state.snapshot, isNull);

    await restoredCashier.controller.refreshTransaction();
    final restored = _snapshot(restoredCashier.controller);
    expect(restored.transactionId, transactionId);
    expect(restored.status, TransactionStatus.paid);
    expect(restored.taxMinorUnits, 20);
    expect(restored.totalMinorUnits, 219);
    expect(restored.tenderedCashMinorUnits, 500);
    expect(restored.changeDueMinorUnits, 281);

    await restoredCashier.controller.completeTransaction();
    expect(
      _snapshot(restoredCashier.controller).status,
      TransactionStatus.completed,
    );
    final afterCompletion = await restoredCashier.client.fetchShiftCashSummary(
      shiftId,
    );
    expect(afterCompletion.completedCashSaleCount, 1);
    expect(afterCompletion.cashSalesMinorUnits, 219);
    restoredCashier.close();
    await fixture.restart();
    final afterSecondRestartCashier = await _createCashier(
      fixture,
      'paid_after_second_restart',
    );
    final afterSecondRestart = await afterSecondRestartCashier.client
        .fetchShiftCashSummary(shiftId);
    expect(afterSecondRestart.openingCashMinorUnits, 10000);
    expect(afterSecondRestart.completedCashSaleCount, 1);
    expect(afterSecondRestart.cashSalesMinorUnits, 219);
    expect(afterSecondRestart.expectedCashMinorUnits, 10219);
  });

  test(
    'unavailable server leaves exact pending command for restart recovery',
    () async {
      final fixture = await _startFixture();
      final firstCashier = await _createCashier(fixture, 'unavailable_before');

      await firstCashier.controller.startTransaction();
      final transactionId = _snapshot(firstCashier.controller).transactionId;
      await fixture.stop();

      await firstCashier.controller.scanBarcode(_developmentBarcode);
      final pending =
          firstCashier.controller.state.pendingCommand! as ScanBarcodeCommand;
      expect(firstCashier.controller.state.snapshot, isNull);
      expect(pending.transactionId, transactionId);
      expect(pending.expectedVersion, 1);
      expect(pending.barcode, _developmentBarcode);
      final persisted = await firstCashier.store.load();
      final persistedCommand = persisted!.pendingCommand! as ScanBarcodeCommand;
      expect(persistedCommand.commandId, pending.commandId);
      expect(persistedCommand.transactionId, pending.transactionId);
      expect(persistedCommand.expectedVersion, pending.expectedVersion);
      expect(persistedCommand.barcode, pending.barcode);

      firstCashier.close();
      await fixture.start();
      final restoredCashier = await _createCashier(
        fixture,
        'unavailable_after',
      );
      final restoredPending =
          restoredCashier.controller.state.pendingCommand!
              as ScanBarcodeCommand;
      expect(restoredPending.commandId, pending.commandId);
      expect(restoredPending.transactionId, pending.transactionId);
      expect(restoredPending.expectedVersion, pending.expectedVersion);
      expect(restoredPending.barcode, pending.barcode);
      expect(restoredCashier.controller.state.snapshot, isNull);
      expect(restoredCashier.ids.commandIdCalls, 0);
      expect(restoredCashier.ids.transactionIdCalls, 0);

      await restoredCashier.controller.retryPendingCommand();
      final recovered = _snapshot(restoredCashier.controller);
      expect(recovered.transactionId, transactionId);
      expect(recovered.version, 2);
      expect(recovered.lineItems, hasLength(1));
      expect(restoredCashier.controller.state.pendingCommand, isNull);
      expect(restoredCashier.ids.commandIdCalls, 0);
    },
  );

  test(
    'accepted command left pending resolves same receipt after backend restart',
    () async {
      final fixture = await _startFixture();
      final firstCashier = await _createCashier(fixture, 'stale_before');

      await firstCashier.controller.startTransaction();
      final opened = _snapshot(firstCashier.controller);
      final exactCommand = ScanBarcodeCommand(
        commandId: 'cmd_stale_pending_exact',
        transactionId: opened.transactionId,
        expectedVersion: opened.version,
        barcode: _developmentBarcode,
      );
      await firstCashier.store.save(
        PersistedCashierSession(
          operatorId: _developmentCashierId,
          activeTransactionId: opened.transactionId,
          pendingCommand: exactCommand,
        ),
      );

      final committed = await firstCashier.client.executeCommand(exactCommand);
      expect(committed.outcomeKind, PosCommandOutcomeKind.accepted);
      expect(committed.outcomeStreamVersion, 2);

      firstCashier.close();
      await fixture.restart();
      final restoredCashier = await _createCashier(fixture, 'stale_after');
      final restoredPending =
          restoredCashier.controller.state.pendingCommand!
              as ScanBarcodeCommand;
      expect(restoredPending.commandId, exactCommand.commandId);
      expect(restoredPending.transactionId, exactCommand.transactionId);
      expect(restoredPending.expectedVersion, exactCommand.expectedVersion);
      expect(restoredPending.barcode, exactCommand.barcode);

      await restoredCashier.controller.retryPendingCommand();
      final resolved = restoredCashier.controller.state.lastCommandResult!;
      final authoritative = _snapshot(restoredCashier.controller);
      expect(resolved.outcomeKind, PosCommandOutcomeKind.accepted);
      expect(resolved.outcomeStreamVersion, 2);
      expect(authoritative.version, 2);
      expect(authoritative.lineItems, hasLength(1));
      expect(authoritative.taxMinorUnits, 20);
      expect(authoritative.totalMinorUnits, 219);
      _expectDevelopmentItem(authoritative.lineItems.single);
      expect(restoredCashier.controller.state.pendingCommand, isNull);
      expect(restoredCashier.ids.commandIdCalls, 0);
    },
  );

  test(
    'legacy v1 completion recovery rebinds after the active slot is released',
    () async {
      final fixture = await _startFixture();
      final firstCashier = await _createCashier(
        fixture,
        'legacy_completion_before',
      );

      await firstCashier.controller.startTransaction();
      await firstCashier.controller.scanBarcode(_developmentBarcode);
      await firstCashier.controller.tenderCash(500);
      final beforeCompletion = _snapshot(firstCashier.controller);
      final exactCommand = CompleteTransactionCommand(
        commandId: 'cmd_legacy_completion_lost_response',
        transactionId: beforeCompletion.transactionId,
        expectedVersion: beforeCompletion.version,
      );
      final recoveryFile = File(fixture.recoveryFilePath);
      await recoveryFile.parent.create(recursive: true);
      await recoveryFile.writeAsString(
        jsonEncode({
          'schema_version': 1,
          'active_transaction_id': exactCommand.transactionId,
          'pending_command': exactCommand.toJson(),
        }),
        flush: true,
      );

      final discarded = await firstCashier.client.executeCommand(exactCommand);
      expect(discarded.outcomeKind, PosCommandOutcomeKind.accepted);
      expect(
        (await firstCashier.client.fetchRegisterContext())
            .activeShift!
            .activeTransactionId,
        isNull,
      );

      firstCashier.close();
      await fixture.restart();
      final restoredCashier = await _createCashier(
        fixture,
        'legacy_completion_after',
      );
      expect(restoredCashier.controller.legacyRecoveryUnbound, isTrue);
      expect(
        restoredCashier.controller.state.pendingCommand!.toJson(),
        exactCommand.toJson(),
      );

      final context = await restoredCashier.client.fetchRegisterContext();
      expect(context.activeShift!.activeTransactionId, isNull);
      await restoredCashier.controller.reconcileRecoveryOwnership(context);
      expect(restoredCashier.controller.legacyRecoveryUnbound, isFalse);
      expect(
        (await restoredCashier.store.load())!.pendingCommand!.toJson(),
        exactCommand.toJson(),
      );

      await restoredCashier.controller.retryPendingCommand();

      expect(
        restoredCashier.controller.state.lastCommandResult!.commandId,
        exactCommand.commandId,
      );
      expect(restoredCashier.controller.state.pendingCommand, isNull);
      final recovered = _snapshot(restoredCashier.controller);
      expect(recovered.status, TransactionStatus.completed);
      expect(recovered.version, beforeCompletion.version + 1);
      expect(recovered.lineItems, hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'repeated accepted commands survive abrupt POS Core process death',
    () async {
      final fixture = await _startFixture();
      var cashier = await _createCashier(fixture, 'sigkill_initial');
      await cashier.controller.startTransaction();

      for (
        var iteration = 1;
        iteration <= crashCampaignIterations;
        iteration += 1
      ) {
        final crashAtCompletion = iteration.isEven;
        if (crashAtCompletion) {
          await cashier.controller.scanBarcode(_developmentBarcode);
          await cashier.controller.tenderCash(500);
        }
        final beforeCrash = _snapshot(cashier.controller);
        final exactCommand = crashAtCompletion
            ? CompleteTransactionCommand(
                commandId: 'cmd_sigkill_complete_$iteration',
                transactionId: beforeCrash.transactionId,
                expectedVersion: beforeCrash.version,
              )
            : ScanBarcodeCommand(
                commandId: 'cmd_sigkill_scan_$iteration',
                transactionId: beforeCrash.transactionId,
                expectedVersion: beforeCrash.version,
                barcode: _developmentBarcode,
              );
        await cashier.store.save(
          PersistedCashierSession(
            operatorId: _developmentCashierId,
            activeTransactionId: beforeCrash.transactionId,
            pendingCommand: exactCommand,
          ),
        );

        // Deliberately discard the accepted result, then kill only the POS
        // Core process. This is an ambiguous caller outcome around a real
        // durable mutation, but it is not a physical power-loss model.
        final discarded = await cashier.client.executeCommand(exactCommand);
        expect(discarded.outcomeKind, PosCommandOutcomeKind.accepted);
        await fixture.killAbruptly();
        cashier.close();

        await fixture.start();
        cashier = await _createCashier(fixture, 'sigkill_after_$iteration');
        final restoredPending = cashier.controller.state.pendingCommand!;
        expect(restoredPending.toJson(), equals(exactCommand.toJson()));

        await cashier.controller.retryPendingCommand();
        var recovered = _snapshot(cashier.controller);
        expect(
          cashier.controller.state.lastCommandResult!.commandId,
          exactCommand.commandId,
        );
        expect(cashier.controller.state.pendingCommand, isNull);

        if (!crashAtCompletion) {
          expect(recovered.version, 2);
          expect(recovered.lineItems, hasLength(1));
          _expectDevelopmentItem(recovered.lineItems.single);
          await cashier.controller.tenderCash(500);
          await cashier.controller.completeTransaction();
          recovered = _snapshot(cashier.controller);
        }
        expect(recovered.status, TransactionStatus.completed);
        expect(recovered.version, 4);
        expect(recovered.lineItems, hasLength(1));

        if (iteration < crashCampaignIterations) {
          await cashier.controller.beginNextSale();
        }
      }
    },
    timeout: Timeout(Duration(seconds: 30 + (15 * crashCampaignIterations))),
  );

  test('known active session restores through GET only', () async {
    final fixture = await _startFixture();
    final firstCashier = await _createCashier(fixture, 'get_only_before');

    await firstCashier.controller.startTransaction();
    await firstCashier.controller.scanBarcode(_developmentBarcode);
    final transactionId = _snapshot(firstCashier.controller).transactionId;
    final persisted = await firstCashier.store.load();
    expect(persisted!.activeTransactionId, transactionId);
    expect(persisted.pendingCommand, isNull);

    firstCashier.close();
    final restoredCashier = await _createCashier(fixture, 'get_only_after');
    expect(restoredCashier.controller.state.activeTransactionId, transactionId);
    expect(restoredCashier.controller.state.snapshot, isNull);
    expect(restoredCashier.controller.state.pendingCommand, isNull);
    expect(restoredCashier.ids.commandIdCalls, 0);
    expect(restoredCashier.ids.transactionIdCalls, 0);

    await restoredCashier.controller.refreshTransaction();
    final restored = _snapshot(restoredCashier.controller);
    expect(restored.transactionId, transactionId);
    expect(restored.version, 2);
    expect(restored.lineItems, hasLength(1));
    expect(restoredCashier.ids.commandIdCalls, 0);
  });

  test(
    'completed canonical receipt is identical after POS Core restart',
    () async {
      final fixture = await _startFixture();
      final firstCashier = await _createCashier(
        fixture,
        'receipt_restart_before',
      );

      await firstCashier.controller.startTransaction();
      await firstCashier.controller.scanBarcode(_developmentBarcode);
      await firstCashier.controller.tenderCash(500);
      await firstCashier.controller.completeTransaction();
      final transactionId = _snapshot(firstCashier.controller).transactionId;
      final before = await firstCashier.client.fetchReceipt(transactionId);

      firstCashier.close();
      await fixture.restart();
      final restoredCashier = await _createCashier(
        fixture,
        'receipt_restart_after',
      );
      final after = await restoredCashier.client.fetchReceipt(transactionId);

      expect(after.schemaVersion, 2);
      expect(after.schemaVersion, before.schemaVersion);
      expect(after.transactionId, before.transactionId);
      expect(after.transactionVersion, before.transactionVersion);
      expect(after.lineItems, hasLength(before.lineItems.length));
      expect(after.lineItems.single.barcode, before.lineItems.single.barcode);
      expect(
        after.lineItems.single.description,
        before.lineItems.single.description,
      );
      expect(
        after.lineItems.single.unitPriceMinorUnits,
        before.lineItems.single.unitPriceMinorUnits,
      );
      expect(
        after.lineItems.single.taxCategoryId,
        before.lineItems.single.taxCategoryId,
      );
      expect(
        after.lineItems.single.taxRateMillionths,
        before.lineItems.single.taxRateMillionths,
      );
      expect(
        after.lineItems.single.taxAmountMinorUnits,
        before.lineItems.single.taxAmountMinorUnits,
      );
      expect(after.subtotalMinorUnits, before.subtotalMinorUnits);
      expect(after.taxMinorUnits, before.taxMinorUnits);
      expect(after.totalMinorUnits, before.totalMinorUnits);
      expect(after.tenderedCashMinorUnits, before.tenderedCashMinorUnits);
      expect(after.changeDueMinorUnits, before.changeDueMinorUnits);
      expect(after.register!.registerId, before.register!.registerId);
      expect(after.register!.displayName, before.register!.displayName);
      expect(after.cashier!.cashierId, before.cashier!.cashierId);
      expect(after.cashier!.displayName, before.cashier!.displayName);
      expect(after.shiftId, before.shiftId);
      expect(after.startedAtEpochMs, before.startedAtEpochMs);
      expect(after.completedAtEpochMs, before.completedAtEpochMs);
    },
  );

  test(
    'completed receipt ignores later persistent catalog and tax replacement',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'receipt_catalog_change');

      await cashier.controller.startTransaction();
      await cashier.controller.scanBarcode(_developmentBarcode);
      await cashier.controller.tenderCash(500);
      await cashier.controller.completeTransaction();
      final transactionId = _snapshot(cashier.controller).transactionId;

      final replacementFile = File(
        '${fixture.temporaryDirectory.path}${Platform.pathSeparator}'
        'replacement-catalog-v2.json',
      );
      await replacementFile.writeAsString(
        jsonEncode({
          'schema_version': 2,
          'tax_categories': [
            {
              'tax_category_id': 'replacement-exempt',
              'description': 'Replacement development exempt tax',
              'rate_millionths': 0,
            },
          ],
          'items': [
            {
              'item_id': 'replacement-apples',
              'description': 'Replacement Apples',
              'unit_price_minor_units': 299,
              'active': true,
              'tax_category_id': 'replacement-exempt',
            },
          ],
          'barcodes': [
            {'barcode': _developmentBarcode, 'item_id': 'replacement-apples'},
          ],
        }),
        flush: true,
      );
      await fixture.activateCatalogSnapshot(replacementFile.path);

      final receipt = await cashier.client.fetchReceipt(transactionId);
      final line = receipt.lineItems.single;
      expect(line.description, _developmentDescription);
      expect(line.unitPriceMinorUnits, 199);
      expect(line.taxCategoryId, 'development-standard');
      expect(line.taxRateMillionths, 100000);
      expect(line.taxAmountMinorUnits, 20);
      expect(receipt.subtotalMinorUnits, 199);
      expect(receipt.taxMinorUnits, 20);
      expect(receipt.totalMinorUnits, 219);
    },
  );

  test(
    'completed receipt keeps operational identity after configuration rename',
    () async {
      final fixture = await _startFixture();
      final cashier = await _createCashier(fixture, 'configuration_history');
      final firstShift =
          (await cashier.client.fetchRegisterContext()).activeShift!;

      await cashier.controller.startTransaction();
      await cashier.controller.scanBarcode(_developmentBarcode);
      await cashier.controller.tenderCash(500);
      await cashier.controller.completeTransaction();
      final firstTransactionId = _snapshot(cashier.controller).transactionId;
      final firstReceipt = await cashier.client.fetchReceipt(
        firstTransactionId,
      );
      expect(firstReceipt.schemaVersion, 2);
      expect(firstReceipt.register!.displayName, _developmentRegisterName);
      expect(firstReceipt.cashier!.displayName, _developmentCashierName);
      expect(firstReceipt.shiftId, firstShift.shiftId);
      await _closeAtExpectedCash(cashier.client, firstShift.shiftId);

      final replacementFile = File(
        '${fixture.temporaryDirectory.path}${Platform.pathSeparator}'
        'replacement-register-configuration-v1.json',
      );
      await replacementFile.writeAsString(
        jsonEncode({
          'schema_version': 1,
          'register': {
            'register_id': _developmentRegisterId,
            'display_name': 'Renamed Development Register',
          },
          'cashiers': [
            {
              'cashier_id': _developmentCashierId,
              'display_name': 'Renamed Development Cashier',
              'active': true,
            },
          ],
        }),
        flush: true,
      );
      await fixture.activateOperationalConfigurationSnapshot(
        replacementFile.path,
      );

      final secondShift = await cashier.client.openShift(
        _developmentOpeningCash,
      );
      expect(
        secondShift.shift.registerDisplayName,
        'Renamed Development Register',
      );
      expect(
        secondShift.shift.cashierDisplayName,
        'Renamed Development Cashier',
      );
      await cashier.controller.beginNextSale();
      await cashier.controller.scanBarcode(_developmentBarcode);
      await cashier.controller.tenderCash(500);
      await cashier.controller.completeTransaction();
      final secondReceipt = await cashier.client.fetchReceipt(
        _snapshot(cashier.controller).transactionId,
      );

      final oldReceiptAgain = await cashier.client.fetchReceipt(
        firstTransactionId,
      );
      expect(oldReceiptAgain.register!.displayName, _developmentRegisterName);
      expect(oldReceiptAgain.cashier!.displayName, _developmentCashierName);
      expect(oldReceiptAgain.shiftId, firstShift.shiftId);
      expect(
        secondReceipt.register!.displayName,
        'Renamed Development Register',
      );
      expect(secondReceipt.cashier!.displayName, 'Renamed Development Cashier');
      expect(secondReceipt.shiftId, secondShift.shift.shiftId);
    },
  );

  test(
    'fixture shutdown and temporary-directory cleanup are idempotent',
    () async {
      final fixture = await RealPosCoreFixture.create();
      final temporaryPath = fixture.temporaryDirectory.path;
      addTearDown(fixture.dispose);
      await fixture.start();
      expect(fixture.isRunning, isTrue);

      await fixture.stop();
      await fixture.stop();
      expect(fixture.isRunning, isFalse);
      await fixture.dispose();
      await fixture.dispose();
      expect(await Directory(temporaryPath).exists(), isFalse);
    },
  );
}
