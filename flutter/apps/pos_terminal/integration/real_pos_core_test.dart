import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/http_pos_core_client.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/features/cashier/cashier_id_generator.dart';
import 'package:pos_terminal/features/cashier/cashier_session_controller.dart';
import 'package:pos_terminal/features/cashier/cashier_session_store.dart';
import 'package:pos_terminal/features/cashier/file_cashier_session_store.dart';

import 'support/real_pos_core_fixture.dart';

const _developmentBarcode = '049000001234';
const _developmentDescription = 'Test Apples';
const _developmentUnitPrice = 199;
const _developmentLineTax = 20;
const _developmentLineTotal = 219;

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
    final client = HttpPosCoreClient(
      baseUri: fixture.baseUri,
      timeout: const Duration(seconds: 3),
    );
    final store = FileCashierSessionStore(filePath: fixture.recoveryFilePath);
    final ids = _SequentialIntegrationIds(namespace);
    final controller = CashierSessionController(
      client: client,
      idGenerator: ids,
      sessionStore: store,
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

Future<RealPosCoreFixture> _startFixture() async {
  final fixture = await RealPosCoreFixture.create();
  addTearDown(fixture.dispose);
  await fixture.start();
  return fixture;
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
  setUpAll(() {
    // This explicitly invoked suite tests real loopback HTTP. flutter_test's
    // default override returns synthetic 400 responses for all network calls.
    HttpOverrides.global = null;
  });
  tearDownAll(() {
    HttpOverrides.global = ordinaryTestHttpOverrides;
  });

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

  test('ten bounded complete sale cycles do not leak session state', () async {
    final fixture = await _startFixture();
    final cashier = await _createCashier(fixture, 'endurance');
    final transactionIds = <String>{};

    await cashier.controller.startTransaction();
    for (var cycle = 0; cycle < 10; cycle += 1) {
      final opened = _snapshot(cashier.controller);
      _expectOpenEmpty(opened);
      expect(transactionIds.add(opened.transactionId), isTrue);

      await _scanThreeTimes(cashier.controller);
      await cashier.controller.tenderCash(1000);
      final paid = _snapshot(cashier.controller);
      expect(paid.status, TransactionStatus.paid);
      expect(paid.lineItems, hasLength(3));
      expect(paid.taxMinorUnits, 60);
      expect(paid.totalMinorUnits, 657);
      expect(paid.tenderedCashMinorUnits, 1000);
      expect(paid.changeDueMinorUnits, 343);

      await cashier.controller.completeTransaction();
      final completed = _snapshot(cashier.controller);
      expect(completed.status, TransactionStatus.completed);
      expect(completed.lineItems, hasLength(3));
      expect(completed.taxMinorUnits, 60);
      expect(completed.totalMinorUnits, 657);

      if (cycle < 9) {
        await cashier.controller.beginNextSale();
      }
    }
    expect(transactionIds, hasLength(10));
  });

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
    },
  );

  test('paid state and authoritative change survive both restarts', () async {
    final fixture = await _startFixture();
    final firstCashier = await _createCashier(fixture, 'paid_before');

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
