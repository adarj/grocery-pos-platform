import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/canonical_receipt.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_health.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/core/pos_core/pos_core_client.dart';
import 'package:pos_terminal/features/cashier/cashier_id_generator.dart';
import 'package:pos_terminal/features/cashier/cashier_local_recovery_failure.dart';
import 'package:pos_terminal/features/cashier/cashier_session_controller.dart';
import 'package:pos_terminal/features/cashier/cashier_session_store.dart';

typedef CommandHandler =
    Future<PosCommandResult> Function(TransactionCommand command);
typedef TransactionHandler =
    Future<TransactionSnapshot> Function(String transactionId);

final class RecordingClient implements PosCoreClient {
  RecordingClient(this.log);

  final List<String> log;
  final Queue<CommandHandler> commandHandlers = Queue();
  final Queue<TransactionHandler> transactionHandlers = Queue();
  final List<TransactionCommand> commands = [];
  final List<String> reads = [];

  @override
  Future<CanonicalReceipt> fetchReceipt(String transactionId) {
    throw UnimplementedError();
  }

  @override
  Future<PosCoreHealth> fetchHealth() => throw UnimplementedError();

  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) {
    log.add('post:${command.commandType}');
    commands.add(command);
    return commandHandlers.removeFirst()(command);
  }

  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) {
    log.add('get:$transactionId');
    reads.add(transactionId);
    return transactionHandlers.removeFirst()(transactionId);
  }

  void enqueueResult({
    PosCommandOutcomeKind kind = PosCommandOutcomeKind.accepted,
    String? code,
  }) {
    commandHandlers.add(
      (command) async => PosCommandResult(
        commandId: command.commandId,
        transactionId: command.transactionId,
        outcomeKind: kind,
        outcomeCode: code ?? kind.wireName,
        outcomeStreamVersion:
            command.expectedVersion +
            (kind == PosCommandOutcomeKind.accepted ? 1 : 0),
      ),
    );
  }

  void enqueueCommandFailure(PosCoreFailure failure) {
    commandHandlers.add((_) async => throw failure);
  }

  void enqueueSnapshot(TransactionSnapshot snapshot) {
    transactionHandlers.add((_) async => snapshot);
  }

  void enqueueReadFailure(PosCoreFailure failure) {
    transactionHandlers.add((_) async => throw failure);
  }
}

final class RecordingStore implements CashierSessionStore {
  RecordingStore(this.log, {this.persisted});

  final List<String> log;
  PersistedCashierSession? persisted;
  CashierSessionStoreFailure? loadFailure;
  CashierSessionStoreFailure? nextSaveFailure;
  CashierSessionStoreFailure? nextClearFailure;
  int loadCalls = 0;
  int saveCalls = 0;
  int clearCalls = 0;

  @override
  Future<PersistedCashierSession?> load() async {
    loadCalls += 1;
    log.add('load');
    final failure = loadFailure;
    if (failure != null) {
      throw failure;
    }
    return persisted;
  }

  @override
  Future<void> save(PersistedCashierSession session) async {
    saveCalls += 1;
    log.add('save:${session.pendingCommand?.commandType ?? 'none'}');
    final failure = nextSaveFailure;
    nextSaveFailure = null;
    if (failure != null) {
      throw failure;
    }
    persisted = session;
  }

  @override
  Future<void> clear() async {
    clearCalls += 1;
    log.add('clear');
    final failure = nextClearFailure;
    nextClearFailure = null;
    if (failure != null) {
      throw failure;
    }
    persisted = null;
  }
}

final class RecordingIds implements CashierIdGenerator {
  RecordingIds({
    Iterable<String> commandIds = const [],
    Iterable<String> transactionIds = const [],
  }) : _commandIds = Queue.of(commandIds),
       _transactionIds = Queue.of(transactionIds);

  final Queue<String> _commandIds;
  final Queue<String> _transactionIds;
  int commandCalls = 0;
  int transactionCalls = 0;

  @override
  String nextCommandId() {
    commandCalls += 1;
    return _commandIds.removeFirst();
  }

  @override
  String nextTransactionId() {
    transactionCalls += 1;
    return _transactionIds.removeFirst();
  }
}

TransactionSnapshot snapshot({
  String transactionId = 'txn-1',
  int version = 1,
  TransactionStatus status = TransactionStatus.open,
}) {
  final hasPayment =
      status == TransactionStatus.paid || status == TransactionStatus.completed;
  return TransactionSnapshot(
    transactionId: transactionId,
    version: version,
    status: status,
    lineItems: const [],
    subtotalMinorUnits: 0,
    taxMinorUnits: 0,
    totalMinorUnits: 0,
    tenderedCashMinorUnits: hasPayment ? 500 : null,
    changeDueMinorUnits: hasPayment ? 0 : null,
  );
}

({
  CashierSessionController controller,
  RecordingClient client,
  RecordingStore store,
  RecordingIds ids,
  List<String> log,
})
fixture({
  PersistedCashierSession? persisted,
  Iterable<String> commandIds = const ['cmd-start'],
  Iterable<String> transactionIds = const ['txn-1'],
}) {
  final log = <String>[];
  final client = RecordingClient(log);
  final store = RecordingStore(log, persisted: persisted);
  final ids = RecordingIds(
    commandIds: commandIds,
    transactionIds: transactionIds,
  );
  return (
    controller: CashierSessionController(
      client: client,
      idGenerator: ids,
      sessionStore: store,
    ),
    client: client,
    store: store,
    ids: ids,
    log: log,
  );
}

Future<void> startOpen(
  ({
    CashierSessionController controller,
    RecordingClient client,
    RecordingStore store,
    RecordingIds ids,
    List<String> log,
  })
  testFixture, {
  int version = 1,
}) async {
  testFixture.client.enqueueResult();
  testFixture.client.enqueueSnapshot(snapshot(version: version));
  await testFixture.controller.startTransaction();
}

void main() {
  test('every new command is persisted before its POST', () async {
    final testFixture = fixture(
      commandIds: const [
        'cmd-start',
        'cmd-scan',
        'cmd-tender',
        'cmd-complete',
        'cmd-remove',
        'cmd-void',
      ],
    );
    await startOpen(testFixture, version: 1);
    testFixture.client.enqueueResult();
    testFixture.client.enqueueSnapshot(snapshot(version: 2));
    await testFixture.controller.scanBarcode('barcode');
    testFixture.client.enqueueResult(
      kind: PosCommandOutcomeKind.domainRejected,
    );
    testFixture.client.enqueueSnapshot(snapshot(version: 2));
    await testFixture.controller.tenderCash(500);
    testFixture.client.enqueueResult(
      kind: PosCommandOutcomeKind.domainRejected,
    );
    testFixture.client.enqueueSnapshot(snapshot(version: 2));
    await testFixture.controller.completeTransaction();
    testFixture.client.enqueueResult(
      kind: PosCommandOutcomeKind.domainRejected,
    );
    testFixture.client.enqueueSnapshot(snapshot(version: 2));
    await testFixture.controller.removeLineItem(0);
    testFixture.client.enqueueResult(
      kind: PosCommandOutcomeKind.domainRejected,
    );
    testFixture.client.enqueueSnapshot(snapshot(version: 2));
    await testFixture.controller.voidTransaction();

    for (final commandType in <String>[
      'start_transaction',
      'scan_barcode',
      'tender_cash',
      'complete_transaction',
      'remove_line_item',
      'void_transaction',
    ]) {
      expect(
        testFixture.log.indexOf('save:$commandType'),
        lessThan(testFixture.log.indexOf('post:$commandType')),
      );
    }
  });

  test(
    'save failure prevents POST and preserves authoritative state',
    () async {
      final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-scan']);
      await startOpen(testFixture, version: 3);
      final authoritative = testFixture.controller.state.snapshot;
      testFixture.store.nextSaveFailure =
          const CashierSessionStoreFailure.storageUnavailable();

      await testFixture.controller.scanBarcode('barcode');

      expect(testFixture.client.commands, hasLength(1));
      expect(testFixture.controller.state.snapshot, same(authoritative));
      expect(
        testFixture.controller.state.localRecoveryFailure!.kind,
        CashierLocalRecoveryFailureKind.storageUnavailable,
      );
      expect(testFixture.controller.state.pendingCommand, isNull);
      expect(testFixture.controller.state.canExecuteNewMutation, isTrue);
    },
  );

  test(
    'pre-send correction persistence failure performs zero correction POSTs',
    () async {
      for (final action in <String>['remove', 'void']) {
        final testFixture = fixture(
          commandIds: const ['cmd-start', 'cmd-correction'],
        );
        await startOpen(testFixture, version: 3);
        final authoritative = testFixture.controller.state.snapshot;
        testFixture.store.nextSaveFailure =
            const CashierSessionStoreFailure.storageUnavailable();

        if (action == 'remove') {
          await testFixture.controller.removeLineItem(0);
        } else {
          await testFixture.controller.voidTransaction();
        }

        expect(testFixture.client.commands, hasLength(1), reason: action);
        expect(testFixture.controller.state.snapshot, same(authoritative));
        expect(testFixture.controller.state.pendingCommand, isNull);
        expect(testFixture.controller.state.canExecuteNewMutation, isTrue);
      }
    },
  );

  test('known correction plus failed GET remains refresh-only', () async {
    for (final action in <String>['remove', 'void']) {
      final testFixture = fixture(
        commandIds: const ['cmd-start', 'cmd-correction'],
      );
      await startOpen(testFixture, version: 3);
      testFixture.client.enqueueResult();
      testFixture.client.enqueueReadFailure(
        const PosCoreTransportFailure('read failed'),
      );

      if (action == 'remove') {
        await testFixture.controller.removeLineItem(0);
      } else {
        await testFixture.controller.voidTransaction();
      }

      expect(testFixture.controller.state.pendingCommand, isNull);
      expect(testFixture.controller.state.snapshot, isNull);
      expect(testFixture.controller.state.canRefresh, isTrue);
      expect(testFixture.store.persisted!.pendingCommand, isNull);
      expect(testFixture.client.commands, hasLength(2));

      final restored = snapshot(
        version: 4,
        status: action == 'void'
            ? TransactionStatus.voided
            : TransactionStatus.open,
      );
      testFixture.client.enqueueSnapshot(restored);
      await testFixture.controller.refreshTransaction();
      expect(testFixture.client.commands, hasLength(2));
      expect(testFixture.controller.state.snapshot, same(restored));
    }
  });

  test(
    'pending command is recoverable while POST is still unresolved',
    () async {
      final testFixture = fixture();
      final commandCompleter = Completer<PosCommandResult>();
      testFixture.client.commandHandlers.add((_) => commandCompleter.future);

      final operation = testFixture.controller.startTransaction();
      await Future<void>.delayed(Duration.zero);

      final saved = testFixture.store.persisted!;
      final pending = saved.pendingCommand! as StartTransactionCommand;
      expect(pending.commandId, 'cmd-start');
      expect(pending.transactionId, 'txn-1');
      expect(pending.expectedVersion, 0);
      expect(testFixture.client.commands.single, same(pending));

      testFixture.client.enqueueSnapshot(snapshot());
      commandCompleter.complete(
        PosCommandResult(
          commandId: pending.commandId,
          transactionId: pending.transactionId,
          outcomeKind: PosCommandOutcomeKind.accepted,
          outcomeCode: 'accepted',
          outcomeStreamVersion: 1,
        ),
      );
      await operation;
    },
  );

  test(
    'startup restores pending command without network and retry uses it',
    () async {
      final restoredCommand = ScanBarcodeCommand(
        commandId: 'cmd-restored',
        transactionId: 'txn-restored',
        expectedVersion: 7,
        barcode: 'restored-barcode',
      );
      final testFixture = fixture(
        persisted: PersistedCashierSession(
          activeTransactionId: 'txn-restored',
          pendingCommand: restoredCommand,
        ),
        commandIds: const [],
        transactionIds: const [],
      );

      await testFixture.controller.restoreLocalSession();

      expect(testFixture.controller.state.activeTransactionId, 'txn-restored');
      expect(
        testFixture.controller.state.pendingCommand,
        same(restoredCommand),
      );
      expect(testFixture.controller.state.snapshot, isNull);
      expect(testFixture.client.commands, isEmpty);
      expect(testFixture.client.reads, isEmpty);

      testFixture.client.enqueueResult();
      final authoritative = snapshot(transactionId: 'txn-restored', version: 8);
      testFixture.client.enqueueSnapshot(authoritative);
      await testFixture.controller.retryPendingCommand();

      expect(testFixture.client.commands.single, same(restoredCommand));
      expect(testFixture.ids.commandCalls, 0);
      expect(testFixture.ids.transactionCalls, 0);
      expect(testFixture.controller.state.snapshot, same(authoritative));
      expect(testFixture.store.persisted!.pendingCommand, isNull);
    },
  );

  test('startup restores known session for GET-only refresh', () async {
    final testFixture = fixture(
      persisted: PersistedCashierSession(activeTransactionId: 'txn-restored'),
      commandIds: const [],
      transactionIds: const [],
    );
    await testFixture.controller.restoreLocalSession();

    expect(testFixture.controller.state.activeTransactionId, 'txn-restored');
    expect(testFixture.controller.state.pendingCommand, isNull);
    expect(testFixture.client.commands, isEmpty);
    expect(testFixture.client.reads, isEmpty);

    final authoritative = snapshot(transactionId: 'txn-restored', version: 9);
    testFixture.client.enqueueSnapshot(authoritative);
    await testFixture.controller.refreshTransaction();

    expect(testFixture.client.commands, isEmpty);
    expect(testFixture.client.reads, ['txn-restored']);
    expect(testFixture.ids.commandCalls, 0);
    expect(testFixture.controller.state.snapshot, same(authoritative));
  });

  test(
    'known result clears pending before GET and failed GET stays refresh-only',
    () async {
      final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-scan']);
      await startOpen(testFixture, version: 3);
      testFixture.client.enqueueResult();
      testFixture.client.enqueueReadFailure(
        const PosCoreTransportFailure('read unavailable'),
      );

      await testFixture.controller.scanBarcode('barcode');

      expect(testFixture.store.persisted!.activeTransactionId, 'txn-1');
      expect(testFixture.store.persisted!.pendingCommand, isNull);
      expect(testFixture.controller.state.pendingCommand, isNull);
      expect(testFixture.controller.state.snapshot, isNull);
      expect(testFixture.controller.state.canRefresh, isTrue);
      final saveNone = testFixture.log.lastIndexOf('save:none');
      final get = testFixture.log.lastIndexOf('get:txn-1');
      expect(saveNone, lessThan(get));
    },
  );

  test(
    'failed known-result cleanup leaves conservative retry-safe persisted command',
    () async {
      final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-scan']);
      await startOpen(testFixture, version: 3);
      testFixture.client.commandHandlers.add((command) async {
        testFixture.store.nextSaveFailure =
            const CashierSessionStoreFailure.storageUnavailable();
        return PosCommandResult(
          commandId: command.commandId,
          transactionId: command.transactionId,
          outcomeKind: PosCommandOutcomeKind.accepted,
          outcomeCode: 'accepted',
          outcomeStreamVersion: 4,
        );
      });
      final refreshed = snapshot(version: 4);
      testFixture.client.enqueueSnapshot(refreshed);

      await testFixture.controller.scanBarcode('barcode');

      final stalePending = testFixture.store.persisted!.pendingCommand!;
      expect(stalePending.commandId, 'cmd-scan');
      expect(testFixture.controller.state.pendingCommand, isNull);
      expect(testFixture.controller.state.lastCommandResult!.accepted, isTrue);
      expect(testFixture.controller.state.snapshot, same(refreshed));
      expect(
        testFixture.controller.state.localRecoveryFailure!.kind,
        CashierLocalRecoveryFailureKind.storageUnavailable,
      );

      final restartedLog = <String>[];
      final restartedClient = RecordingClient(restartedLog);
      final restartedIds = RecordingIds();
      final restarted = CashierSessionController(
        client: restartedClient,
        idGenerator: restartedIds,
        sessionStore: testFixture.store,
      );
      await restarted.restoreLocalSession();
      expect(restarted.state.pendingCommand, same(stalePending));

      restartedClient.enqueueResult();
      restartedClient.enqueueSnapshot(snapshot(version: 4));
      await restarted.retryPendingCommand();
      expect(restartedClient.commands.single, same(stalePending));
      expect(restartedIds.commandCalls, 0);
    },
  );

  test(
    'non-retryable command failure clears persisted pending marker',
    () async {
      final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-scan']);
      await startOpen(testFixture, version: 3);
      testFixture.client.enqueueCommandFailure(
        const PosCoreServerFailure(
          code: 'command_id_reused',
          message: 'Command ID reused.',
        ),
      );

      await testFixture.controller.scanBarcode('barcode');

      expect(testFixture.store.persisted!.activeTransactionId, 'txn-1');
      expect(testFixture.store.persisted!.pendingCommand, isNull);
      expect(testFixture.controller.state.pendingCommand, isNull);
      expect(testFixture.controller.state.canRefresh, isTrue);
    },
  );

  test(
    'accepted scan tender and completion with failed GET persist refresh-only state',
    () async {
      for (final action in <String>['scan', 'tender', 'complete']) {
        final testFixture = fixture(commandIds: ['cmd-start', 'cmd-$action']);
        await startOpen(testFixture, version: 3);
        testFixture.client.enqueueResult();
        testFixture.client.enqueueReadFailure(
          const PosCoreTransportFailure('read unavailable'),
        );

        switch (action) {
          case 'scan':
            await testFixture.controller.scanBarcode('barcode');
            break;
          case 'tender':
            await testFixture.controller.tenderCash(500);
            break;
          case 'complete':
            await testFixture.controller.completeTransaction();
            break;
        }

        expect(testFixture.store.persisted!.activeTransactionId, 'txn-1');
        expect(testFixture.store.persisted!.pendingCommand, isNull);
        expect(testFixture.controller.state.pendingCommand, isNull);
        expect(testFixture.controller.state.snapshot, isNull);
        expect(testFixture.controller.state.canRefresh, isTrue);
      }
    },
  );

  test(
    'corrupt startup recovery blocks all work without deleting state',
    () async {
      final testFixture = fixture();
      testFixture.store.loadFailure =
          const CashierSessionStoreFailure.corruptData();

      await testFixture.controller.restoreLocalSession();

      expect(
        testFixture.controller.state.localRecoveryFailure!.kind,
        CashierLocalRecoveryFailureKind.corruptState,
      );
      expect(testFixture.controller.state.canStartTransaction, isFalse);
      await expectLater(
        testFixture.controller.startTransaction(),
        throwsStateError,
      );
      expect(testFixture.ids.commandCalls, 0);
      expect(testFixture.ids.transactionCalls, 0);
      expect(testFixture.client.commands, isEmpty);
      expect(testFixture.client.reads, isEmpty);
      expect(testFixture.store.clearCalls, 0);
    },
  );

  test(
    'known rejections update or clear persisted session by policy',
    () async {
      final testFixture = fixture(
        commandIds: const ['cmd-start', 'cmd-tender', 'cmd-scan'],
      );
      await startOpen(testFixture, version: 1);
      testFixture.client.enqueueResult(
        kind: PosCommandOutcomeKind.domainRejected,
        code: 'insufficient_tender',
      );
      testFixture.client.enqueueSnapshot(snapshot(version: 1));
      await testFixture.controller.tenderCash(100);
      expect(testFixture.store.persisted!.pendingCommand, isNull);

      testFixture.client.enqueueResult(
        kind: PosCommandOutcomeKind.notFound,
        code: 'transaction_not_found',
      );
      await testFixture.controller.scanBarcode('barcode');
      expect(testFixture.store.persisted, isNull);
      expect(testFixture.controller.state.activeTransactionId, isNull);
    },
  );

  test('start alreadyExists clears generated persisted session', () async {
    final testFixture = fixture();
    testFixture.client.enqueueResult(
      kind: PosCommandOutcomeKind.alreadyExists,
      code: 'transaction_already_exists',
    );

    await testFixture.controller.startTransaction();

    expect(testFixture.store.persisted, isNull);
    expect(testFixture.controller.state.activeTransactionId, isNull);
    expect(testFixture.client.reads, isEmpty);
  });

  test('next sale rejects open and paid authoritative sessions', () async {
    for (final status in <TransactionStatus>[
      TransactionStatus.open,
      TransactionStatus.paid,
    ]) {
      final testFixture = fixture();
      await startOpen(testFixture);
      if (status == TransactionStatus.paid) {
        testFixture.client.enqueueSnapshot(snapshot(status: status));
        await testFixture.controller.refreshTransaction();
      }

      await expectLater(
        testFixture.controller.beginNextSale(),
        throwsStateError,
      );
      expect(testFixture.ids.commandCalls, 1);
      expect(testFixture.ids.transactionCalls, 1);
    }
  });

  test('authoritative voided session can begin the next sale', () async {
    final testFixture = fixture(
      commandIds: const ['cmd-old', 'cmd-next'],
      transactionIds: const ['txn-old', 'txn-next'],
    );
    testFixture.client.enqueueResult();
    testFixture.client.enqueueSnapshot(
      snapshot(transactionId: 'txn-old', status: TransactionStatus.voided),
    );
    await testFixture.controller.startTransaction();
    testFixture.log.clear();
    testFixture.client.enqueueResult();
    final nextSnapshot = snapshot(transactionId: 'txn-next');
    testFixture.client.enqueueSnapshot(nextSnapshot);

    await testFixture.controller.beginNextSale();

    expect(testFixture.log.take(3), [
      'clear',
      'save:start_transaction',
      'post:start_transaction',
    ]);
    expect(testFixture.controller.state.snapshot, same(nextSnapshot));
  });

  test(
    'restored pending removal retries exact command without generating IDs',
    () async {
      final pending = RemoveLineItemCommand(
        commandId: 'cmd-restored-remove',
        transactionId: 'txn-restored',
        expectedVersion: 8,
        lineIndex: 1,
      );
      final testFixture = fixture(
        persisted: PersistedCashierSession(
          activeTransactionId: 'txn-restored',
          pendingCommand: pending,
        ),
        commandIds: const [],
        transactionIds: const [],
      );

      await testFixture.controller.restoreLocalSession();
      testFixture.client.enqueueResult();
      final authoritative = snapshot(transactionId: 'txn-restored', version: 9);
      testFixture.client.enqueueSnapshot(authoritative);
      await testFixture.controller.retryPendingCommand();

      expect(testFixture.client.commands, [same(pending)]);
      expect(testFixture.ids.commandCalls, 0);
      expect(testFixture.ids.transactionCalls, 0);
      expect(testFixture.store.persisted!.pendingCommand, isNull);
      expect(testFixture.controller.state.snapshot, same(authoritative));
    },
  );

  test(
    'next sale clear failure preserves completed sale and consumes no IDs',
    () async {
      final testFixture = fixture();
      testFixture.client.enqueueResult();
      final completed = snapshot(status: TransactionStatus.completed);
      testFixture.client.enqueueSnapshot(completed);
      await testFixture.controller.startTransaction();
      testFixture.store.nextClearFailure =
          const CashierSessionStoreFailure.storageUnavailable();

      await testFixture.controller.beginNextSale();

      expect(testFixture.controller.state.snapshot, same(completed));
      expect(testFixture.controller.state.canBeginNextSale, isTrue);
      expect(testFixture.ids.commandCalls, 1);
      expect(testFixture.ids.transactionCalls, 1);
      expect(testFixture.client.commands, hasLength(1));
    },
  );

  test(
    'next sale clears old session then persists and sends one new start',
    () async {
      final testFixture = fixture(
        commandIds: const ['cmd-old', 'cmd-next'],
        transactionIds: const ['txn-old', 'txn-next'],
      );
      testFixture.client.enqueueResult();
      testFixture.client.enqueueSnapshot(
        snapshot(transactionId: 'txn-old', status: TransactionStatus.completed),
      );
      await testFixture.controller.startTransaction();
      testFixture.log.clear();
      testFixture.client.enqueueResult();
      final nextSnapshot = snapshot(transactionId: 'txn-next');
      testFixture.client.enqueueSnapshot(nextSnapshot);

      await testFixture.controller.beginNextSale();

      expect(testFixture.log.take(3), [
        'clear',
        'save:start_transaction',
        'post:start_transaction',
      ]);
      final next = testFixture.client.commands.last as StartTransactionCommand;
      expect(next.commandId, 'cmd-next');
      expect(next.transactionId, 'txn-next');
      expect(next.expectedVersion, 0);
      expect(testFixture.controller.state.snapshot, same(nextSnapshot));
    },
  );

  test('uncertain next-sale start remains exactly recoverable', () async {
    final testFixture = fixture(
      commandIds: const ['cmd-old', 'cmd-next'],
      transactionIds: const ['txn-old', 'txn-next'],
    );
    testFixture.client.enqueueResult();
    testFixture.client.enqueueSnapshot(
      snapshot(transactionId: 'txn-old', status: TransactionStatus.completed),
    );
    await testFixture.controller.startTransaction();
    testFixture.client.enqueueCommandFailure(
      const PosCoreTransportFailure('unknown', retrySameCommandId: true),
    );

    await testFixture.controller.beginNextSale();

    final pending = testFixture.controller.state.pendingCommand!;
    expect(pending, isA<StartTransactionCommand>());
    expect(pending.commandId, 'cmd-next');
    expect(pending.transactionId, 'txn-next');
    expect(testFixture.store.persisted!.pendingCommand, same(pending));
  });
}
