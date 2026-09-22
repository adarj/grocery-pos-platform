import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/canonical_receipt.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_health.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_readiness.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/core/pos_core/pos_core_client.dart';
import 'package:pos_terminal/features/cashier/cashier_id_generator.dart';
import 'package:pos_terminal/features/cashier/cashier_session_controller.dart';
import 'package:pos_terminal/features/cashier/cashier_session_state.dart';
import 'package:pos_terminal/features/cashier/cashier_session_store.dart';

import '../../support/unimplemented_register_operations_client.dart';

typedef CommandHandler =
    Future<PosCommandResult> Function(TransactionCommand command);
typedef TransactionHandler =
    Future<TransactionSnapshot> Function(String transactionId);

final class FakePosCoreClient
    with UnimplementedRegisterOperationsClient
    implements PosCoreClient {
  @override
  Future<CanonicalReceipt> fetchReceipt(String transactionId) {
    throw UnimplementedError();
  }

  final Queue<CommandHandler> commandHandlers = Queue();
  final Queue<TransactionHandler> transactionHandlers = Queue();
  final List<TransactionCommand> commands = [];
  final List<String> transactionReads = [];

  @override
  Future<PosCoreHealth> fetchHealth() {
    throw UnimplementedError();
  }

  @override
  Future<PosCoreReadiness> fetchReadiness() => throw UnimplementedError();

  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) {
    commands.add(command);
    if (commandHandlers.isEmpty) {
      throw StateError('No command handler was queued.');
    }
    return commandHandlers.removeFirst()(command);
  }

  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) {
    transactionReads.add(transactionId);
    if (transactionHandlers.isEmpty) {
      throw StateError('No transaction handler was queued.');
    }
    return transactionHandlers.removeFirst()(transactionId);
  }

  void enqueueCommandResult(
    PosCommandOutcomeKind kind, {
    String? code,
    int outcomeVersion = 1,
  }) {
    commandHandlers.add((command) async {
      return resultFor(
        command,
        kind: kind,
        code: code,
        outcomeVersion: outcomeVersion,
      );
    });
  }

  void enqueueCommandFailure(PosCoreFailure failure) {
    commandHandlers.add((_) async => throw failure);
  }

  void enqueueSnapshot(TransactionSnapshot snapshot) {
    transactionHandlers.add((_) async => snapshot);
  }

  void enqueueTransactionFailure(PosCoreFailure failure) {
    transactionHandlers.add((_) async => throw failure);
  }
}

final class FakeCashierIdGenerator implements CashierIdGenerator {
  FakeCashierIdGenerator({
    Iterable<String> commandIds = const [],
    Iterable<String> transactionIds = const [],
  }) : _commandIds = Queue.of(commandIds),
       _transactionIds = Queue.of(transactionIds);

  final Queue<String> _commandIds;
  final Queue<String> _transactionIds;
  int commandIdCalls = 0;
  int transactionIdCalls = 0;

  @override
  String nextCommandId() {
    commandIdCalls += 1;
    if (_commandIds.isEmpty) {
      throw StateError('No command ID was queued.');
    }
    return _commandIds.removeFirst();
  }

  @override
  String nextTransactionId() {
    transactionIdCalls += 1;
    if (_transactionIds.isEmpty) {
      throw StateError('No transaction ID was queued.');
    }
    return _transactionIds.removeFirst();
  }
}

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

PosCommandResult resultFor(
  TransactionCommand command, {
  PosCommandOutcomeKind kind = PosCommandOutcomeKind.accepted,
  String? code,
  int outcomeVersion = 1,
}) {
  return PosCommandResult(
    commandId: command.commandId,
    transactionId: command.transactionId,
    outcomeKind: kind,
    outcomeCode: code ?? kind.wireName,
    outcomeStreamVersion: outcomeVersion,
  );
}

TransactionSnapshot snapshot({
  String transactionId = 'txn-1',
  int version = 1,
  TransactionStatus status = TransactionStatus.open,
  List<TransactionLineItem> lineItems = const [],
  int subtotalMinorUnits = 0,
  int taxMinorUnits = 0,
  int totalMinorUnits = 0,
  int? tenderedCashMinorUnits,
  int? changeDueMinorUnits,
}) {
  return TransactionSnapshot(
    transactionId: transactionId,
    version: version,
    status: status,
    lineItems: lineItems,
    subtotalMinorUnits: subtotalMinorUnits,
    taxMinorUnits: taxMinorUnits,
    totalMinorUnits: totalMinorUnits,
    tenderedCashMinorUnits: tenderedCashMinorUnits,
    changeDueMinorUnits: changeDueMinorUnits,
  );
}

({
  CashierSessionController controller,
  FakePosCoreClient client,
  FakeCashierIdGenerator ids,
})
fixture({
  Iterable<String> commandIds = const ['cmd-start'],
  Iterable<String> transactionIds = const ['txn-1'],
}) {
  final client = FakePosCoreClient();
  final ids = FakeCashierIdGenerator(
    commandIds: commandIds,
    transactionIds: transactionIds,
  );
  return (
    controller: CashierSessionController(
      client: client,
      idGenerator: ids,
      sessionStore: MemoryCashierSessionStore(),
      currentOperatorId: () => 'operator-test',
    ),
    client: client,
    ids: ids,
  );
}

Future<void> establishTransaction(
  ({
    CashierSessionController controller,
    FakePosCoreClient client,
    FakeCashierIdGenerator ids,
  })
  testFixture,
  TransactionSnapshot authoritativeSnapshot,
) async {
  testFixture.client.enqueueCommandResult(PosCommandOutcomeKind.accepted);
  testFixture.client.enqueueSnapshot(authoritativeSnapshot);
  await testFixture.controller.startTransaction();
}

void main() {
  test('initial state exposes only safe initial capabilities', () {
    final testFixture = fixture();
    final state = testFixture.controller.state;

    expect(state.activity, CashierSessionActivity.idle);
    expect(state.activeTransactionId, isNull);
    expect(state.snapshot, isNull);
    expect(state.pendingCommand, isNull);
    expect(state.hasCurrentTransaction, isFalse);
    expect(state.canStartTransaction, isTrue);
    expect(state.canExecuteNewMutation, isFalse);
    expect(state.canRetryPendingCommand, isFalse);
    expect(state.canRefresh, isFalse);
  });

  test(
    'non-start actions require an authoritative snapshot and consume no IDs',
    () async {
      final testFixture = fixture(commandIds: const []);

      await expectLater(
        testFixture.controller.scanBarcode('049000001234'),
        throwsStateError,
      );
      await expectLater(
        testFixture.controller.tenderCash(500),
        throwsStateError,
      );
      await expectLater(
        testFixture.controller.completeTransaction(),
        throwsStateError,
      );
      await expectLater(
        testFixture.controller.removeLineItem(0),
        throwsStateError,
      );
      await expectLater(
        testFixture.controller.voidTransaction(),
        throwsStateError,
      );

      expect(testFixture.ids.commandIdCalls, 0);
      expect(testFixture.ids.transactionIdCalls, 0);
      expect(testFixture.client.commands, isEmpty);
    },
  );

  test(
    'accepted start uses one ID pair and installs only the GET snapshot',
    () async {
      final testFixture = fixture(
        commandIds: const ['cmd-new-sale'],
        transactionIds: const ['txn-new-sale'],
      );
      final authoritative = snapshot(
        transactionId: 'txn-new-sale',
        version: 9,
        status: TransactionStatus.paid,
        lineItems: const [
          TransactionLineItem(
            barcode: 'surprising-item',
            description: 'Backend state',
            unitPriceMinorUnits: 199,
          ),
        ],
        subtotalMinorUnits: 199,
        totalMinorUnits: 199,
        tenderedCashMinorUnits: 500,
        changeDueMinorUnits: 301,
      );
      testFixture.client.enqueueCommandResult(
        PosCommandOutcomeKind.accepted,
        outcomeVersion: 1,
      );
      testFixture.client.enqueueSnapshot(authoritative);

      await testFixture.controller.startTransaction();

      final command = testFixture.client.commands.single;
      expect(command, isA<StartTransactionCommand>());
      expect(command.commandId, 'cmd-new-sale');
      expect(command.transactionId, 'txn-new-sale');
      expect(command.expectedVersion, 0);
      expect(testFixture.ids.commandIdCalls, 1);
      expect(testFixture.ids.transactionIdCalls, 1);
      expect(testFixture.client.transactionReads, ['txn-new-sale']);
      expect(
        identical(testFixture.controller.state.snapshot, authoritative),
        isTrue,
      );
      expect(testFixture.controller.state.snapshot!.version, 9);
      expect(
        testFixture.controller.state.snapshot!.status,
        TransactionStatus.paid,
      );
    },
  );

  test(
    'resolved start survives refresh failure and later refresh uses GET only',
    () async {
      final testFixture = fixture();
      testFixture.client.enqueueCommandResult(PosCommandOutcomeKind.accepted);
      testFixture.client.enqueueTransactionFailure(
        const PosCoreTransportFailure('read unavailable'),
      );

      await testFixture.controller.startTransaction();

      expect(testFixture.controller.state.lastCommandResult, isNotNull);
      expect(testFixture.controller.state.activeTransactionId, 'txn-1');
      expect(testFixture.controller.state.snapshot, isNull);
      expect(testFixture.controller.state.pendingCommand, isNull);
      expect(
        testFixture.controller.state.failure,
        isA<PosCoreTransportFailure>(),
      );
      expect(testFixture.client.commands, hasLength(1));

      final authoritative = snapshot(transactionId: 'txn-1', version: 7);
      testFixture.client.enqueueSnapshot(authoritative);
      await testFixture.controller.refreshTransaction();

      expect(
        identical(testFixture.controller.state.snapshot, authoritative),
        isTrue,
      );
      expect(testFixture.controller.state.failure, isNull);
      expect(testFixture.client.commands, hasLength(1));
      expect(testFixture.ids.commandIdCalls, 1);
      expect(testFixture.ids.transactionIdCalls, 1);
    },
  );

  test(
    'start alreadyExists never adopts or fetches collided transaction',
    () async {
      final testFixture = fixture();
      testFixture.client.enqueueCommandResult(
        PosCommandOutcomeKind.alreadyExists,
        code: 'transaction_already_exists',
        outcomeVersion: 5,
      );

      await testFixture.controller.startTransaction();

      expect(
        testFixture.controller.state.lastCommandResult!.outcomeKind,
        PosCommandOutcomeKind.alreadyExists,
      );
      expect(testFixture.controller.state.activeTransactionId, isNull);
      expect(testFixture.controller.state.snapshot, isNull);
      expect(testFixture.client.transactionReads, isEmpty);
      expect(testFixture.controller.state.canStartTransaction, isTrue);
    },
  );

  test(
    'uncertain start retry preserves both generated IDs and command object',
    () async {
      final testFixture = fixture(
        commandIds: const ['cmd-one-start'],
        transactionIds: const ['txn-one-start'],
      );
      testFixture.client.enqueueCommandFailure(
        const PosCoreTransportFailure(
          'start outcome unknown',
          retrySameCommandId: true,
        ),
      );

      await testFixture.controller.startTransaction();

      final pending = testFixture.controller.state.pendingCommand!;
      expect(pending, isA<StartTransactionCommand>());
      expect(pending.commandId, 'cmd-one-start');
      expect(pending.transactionId, 'txn-one-start');
      expect(pending.expectedVersion, 0);
      expect(testFixture.controller.state.activeTransactionId, 'txn-one-start');
      expect(testFixture.client.transactionReads, isEmpty);

      testFixture.client.enqueueCommandResult(PosCommandOutcomeKind.accepted);
      final authoritative = snapshot(
        transactionId: 'txn-one-start',
        version: 1,
      );
      testFixture.client.enqueueSnapshot(authoritative);
      await testFixture.controller.retryPendingCommand();

      expect(identical(testFixture.client.commands[0], pending), isTrue);
      expect(identical(testFixture.client.commands[1], pending), isTrue);
      expect(testFixture.ids.commandIdCalls, 1);
      expect(testFixture.ids.transactionIdCalls, 1);
      expect(
        identical(testFixture.controller.state.snapshot, authoritative),
        isTrue,
      );
    },
  );

  test(
    'new mutations always use the latest authoritative GET version',
    () async {
      final testFixture = fixture(
        commandIds: const [
          'cmd-start',
          'cmd-scan',
          'cmd-tender',
          'cmd-complete',
        ],
      );
      await establishTransaction(
        testFixture,
        snapshot(transactionId: 'txn-1', version: 10),
      );

      testFixture.client.enqueueCommandResult(
        PosCommandOutcomeKind.accepted,
        outcomeVersion: 200,
      );
      testFixture.client.enqueueSnapshot(
        snapshot(transactionId: 'txn-1', version: 31),
      );
      await testFixture.controller.scanBarcode('049000001234');

      testFixture.client.enqueueCommandResult(
        PosCommandOutcomeKind.domainRejected,
        code: 'insufficient_tender',
        outcomeVersion: 999,
      );
      testFixture.client.enqueueSnapshot(
        snapshot(transactionId: 'txn-1', version: 52),
      );
      await testFixture.controller.tenderCash(500);

      testFixture.client.enqueueCommandResult(
        PosCommandOutcomeKind.versionConflict,
        code: 'stale_expected_version',
        outcomeVersion: 700,
      );
      testFixture.client.enqueueSnapshot(
        snapshot(transactionId: 'txn-1', version: 81),
      );
      await testFixture.controller.completeTransaction();

      final scan = testFixture.client.commands[1] as ScanBarcodeCommand;
      final tender = testFixture.client.commands[2] as TenderCashCommand;
      final complete =
          testFixture.client.commands[3] as CompleteTransactionCommand;
      expect(scan.commandId, 'cmd-scan');
      expect(scan.transactionId, 'txn-1');
      expect(scan.expectedVersion, 10);
      expect(scan.barcode, '049000001234');
      expect(tender.commandId, 'cmd-tender');
      expect(tender.expectedVersion, 31);
      expect(tender.amountMinorUnits, 500);
      expect(complete.commandId, 'cmd-complete');
      expect(complete.expectedVersion, 52);
      expect(testFixture.controller.state.snapshot!.version, 81);
      expect(testFixture.client.commands, hasLength(4));
    },
  );

  test(
    'accepted command invalidates old snapshot and trusts surprising GET state',
    () async {
      final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-scan']);
      final oldSnapshot = snapshot(transactionId: 'txn-1', version: 3);
      await establishTransaction(testFixture, oldSnapshot);
      final commandCompleter = Completer<PosCommandResult>();
      final readCompleter = Completer<TransactionSnapshot>();
      testFixture.client.commandHandlers.add((_) => commandCompleter.future);
      testFixture.client.transactionHandlers.add((_) => readCompleter.future);

      final operation = testFixture.controller.scanBarcode('barcode');

      expect(
        testFixture.controller.state.activity,
        CashierSessionActivity.executingCommand,
      );
      expect(testFixture.controller.state.snapshot, isNull);
      final command = testFixture.client.commands.last;
      commandCompleter.complete(resultFor(command, outcomeVersion: 4));
      await Future<void>.delayed(Duration.zero);
      expect(
        testFixture.controller.state.activity,
        CashierSessionActivity.refreshingTransaction,
      );
      expect(testFixture.controller.state.snapshot, isNull);

      final authoritative = snapshot(
        transactionId: 'txn-1',
        version: 44,
        status: TransactionStatus.completed,
        subtotalMinorUnits: 1234,
        totalMinorUnits: 5678,
        tenderedCashMinorUnits: 9000,
        changeDueMinorUnits: 3322,
      );
      readCompleter.complete(authoritative);
      await operation;

      expect(
        identical(testFixture.controller.state.snapshot, authoritative),
        isTrue,
      );
      expect(testFixture.controller.state.snapshot!.totalMinorUnits, 5678);
    },
  );

  test(
    'domain rejection and version conflict refresh without reissuing command',
    () async {
      for (final kind in [
        PosCommandOutcomeKind.domainRejected,
        PosCommandOutcomeKind.versionConflict,
      ]) {
        final testFixture = fixture(
          commandIds: const ['cmd-start', 'cmd-scan'],
        );
        await establishTransaction(
          testFixture,
          snapshot(transactionId: 'txn-1', version: 4),
        );
        final refreshed = snapshot(transactionId: 'txn-1', version: 12);
        testFixture.client.enqueueCommandResult(kind, outcomeVersion: 9);
        testFixture.client.enqueueSnapshot(refreshed);

        await testFixture.controller.scanBarcode('barcode');

        expect(testFixture.client.commands, hasLength(2));
        expect(testFixture.ids.commandIdCalls, 2);
        expect(
          identical(testFixture.controller.state.snapshot, refreshed),
          isTrue,
        );
        expect(
          testFixture.controller.state.lastCommandResult!.outcomeKind,
          kind,
        );
      }
    },
  );

  test(
    'durable notFound clears active transaction without fabricating state',
    () async {
      final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-scan']);
      await establishTransaction(
        testFixture,
        snapshot(transactionId: 'txn-1', version: 4),
      );
      final priorReads = testFixture.client.transactionReads.length;
      testFixture.client.enqueueCommandResult(
        PosCommandOutcomeKind.notFound,
        code: 'transaction_not_found',
        outcomeVersion: 0,
      );

      await testFixture.controller.scanBarcode('barcode');

      expect(testFixture.controller.state.activeTransactionId, isNull);
      expect(testFixture.controller.state.snapshot, isNull);
      expect(
        testFixture.controller.state.lastCommandResult!.outcomeKind,
        PosCommandOutcomeKind.notFound,
      );
      expect(testFixture.client.transactionReads, hasLength(priorReads));
    },
  );

  test(
    'all retry-required typed failures retain the exact submitted command',
    () async {
      const failures = <PosCoreFailure>[
        PosCoreTransportFailure('connection dropped', retrySameCommandId: true),
        PosCoreServerFailure(
          code: 'command_outcome_unknown',
          message: 'Outcome unknown.',
          retrySameCommandId: true,
        ),
        PosCoreInvalidResponseFailure(
          'Malformed response.',
          retrySameCommandId: true,
        ),
      ];

      for (final failure in failures) {
        final testFixture = fixture(
          commandIds: const ['cmd-start', 'cmd-scan'],
        );
        await establishTransaction(
          testFixture,
          snapshot(transactionId: 'txn-1', version: 6),
        );
        final priorReads = testFixture.client.transactionReads.length;
        testFixture.client.enqueueCommandFailure(failure);

        await testFixture.controller.scanBarcode('barcode');

        final submitted = testFixture.client.commands.last;
        expect(
          identical(testFixture.controller.state.pendingCommand, submitted),
          isTrue,
        );
        expect(testFixture.controller.state.snapshot, isNull);
        expect(testFixture.controller.state.failure, same(failure));
        expect(
          testFixture.controller.state.activity,
          CashierSessionActivity.idle,
        );
        expect(testFixture.client.transactionReads, hasLength(priorReads));
        expect(testFixture.client.commands, hasLength(2));
      }
    },
  );

  test(
    'pending command blocks every new mutation and ordinary refresh',
    () async {
      final testFixture = fixture(
        commandIds: const ['cmd-start', 'cmd-pending', 'must-not-be-used'],
        transactionIds: const ['txn-1', 'must-not-be-used'],
      );
      await establishTransaction(
        testFixture,
        snapshot(transactionId: 'txn-1', version: 2),
      );
      testFixture.client.enqueueCommandFailure(
        const PosCoreTransportFailure('unknown', retrySameCommandId: true),
      );
      await testFixture.controller.scanBarcode('barcode');
      final commandCalls = testFixture.ids.commandIdCalls;
      final transactionCalls = testFixture.ids.transactionIdCalls;
      final posts = testFixture.client.commands.length;

      await expectLater(
        testFixture.controller.startTransaction(),
        throwsStateError,
      );
      await expectLater(
        testFixture.controller.scanBarcode('other'),
        throwsStateError,
      );
      await expectLater(
        testFixture.controller.tenderCash(500),
        throwsStateError,
      );
      await expectLater(
        testFixture.controller.completeTransaction(),
        throwsStateError,
      );
      await expectLater(
        testFixture.controller.refreshTransaction(),
        throwsStateError,
      );

      expect(testFixture.ids.commandIdCalls, commandCalls);
      expect(testFixture.ids.transactionIdCalls, transactionCalls);
      expect(testFixture.client.commands, hasLength(posts));
    },
  );

  test('retry submits the identical command without consuming an ID', () async {
    final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-scan']);
    await establishTransaction(
      testFixture,
      snapshot(transactionId: 'txn-1', version: 8),
    );
    testFixture.client.enqueueCommandFailure(
      const PosCoreTransportFailure('unknown', retrySameCommandId: true),
    );
    await testFixture.controller.scanBarcode('same-payload');
    final pending = testFixture.controller.state.pendingCommand!;
    final commandIdCalls = testFixture.ids.commandIdCalls;
    final refreshed = snapshot(transactionId: 'txn-1', version: 9);
    testFixture.client.enqueueCommandResult(PosCommandOutcomeKind.accepted);
    testFixture.client.enqueueSnapshot(refreshed);

    await testFixture.controller.retryPendingCommand();

    expect(identical(testFixture.client.commands[1], pending), isTrue);
    expect(identical(testFixture.client.commands[2], pending), isTrue);
    expect(testFixture.ids.commandIdCalls, commandIdCalls);
    expect(testFixture.controller.state.pendingCommand, isNull);
    expect(testFixture.controller.state.lastCommandResult!.accepted, isTrue);
    expect(identical(testFixture.controller.state.snapshot, refreshed), isTrue);
  });

  test(
    'retry resolving rejection clears pending and follows normal refresh',
    () async {
      final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-scan']);
      await establishTransaction(
        testFixture,
        snapshot(transactionId: 'txn-1', version: 8),
      );
      testFixture.client.enqueueCommandFailure(
        const PosCoreTransportFailure('unknown', retrySameCommandId: true),
      );
      await testFixture.controller.scanBarcode('same-payload');
      final pending = testFixture.controller.state.pendingCommand!;
      testFixture.client.enqueueCommandResult(
        PosCommandOutcomeKind.domainRejected,
        code: 'unknown_barcode',
        outcomeVersion: 8,
      );
      final refreshed = snapshot(transactionId: 'txn-1', version: 10);
      testFixture.client.enqueueSnapshot(refreshed);

      await testFixture.controller.retryPendingCommand();

      expect(identical(testFixture.client.commands.last, pending), isTrue);
      expect(testFixture.controller.state.pendingCommand, isNull);
      expect(
        testFixture.controller.state.lastCommandResult!.outcomeCode,
        'unknown_barcode',
      );
      expect(
        identical(testFixture.controller.state.snapshot, refreshed),
        isTrue,
      );
    },
  );

  test('retry that remains uncertain keeps the same pending object', () async {
    final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-scan']);
    await establishTransaction(
      testFixture,
      snapshot(transactionId: 'txn-1', version: 8),
    );
    testFixture.client.enqueueCommandFailure(
      const PosCoreTransportFailure('first', retrySameCommandId: true),
    );
    await testFixture.controller.scanBarcode('same-payload');
    final pending = testFixture.controller.state.pendingCommand!;
    final priorReads = testFixture.client.transactionReads.length;
    testFixture.client.enqueueCommandFailure(
      const PosCoreServerFailure(
        code: 'command_outcome_unknown',
        message: 'Still unknown.',
        retrySameCommandId: true,
      ),
    );

    await testFixture.controller.retryPendingCommand();

    expect(identical(testFixture.client.commands.last, pending), isTrue);
    expect(
      identical(testFixture.controller.state.pendingCommand, pending),
      isTrue,
    );
    expect(testFixture.client.transactionReads, hasLength(priorReads));
    expect(testFixture.ids.commandIdCalls, 2);
  });

  test(
    'non-retryable command_id_reused failure requires refresh, not a new ID',
    () async {
      final testFixture = fixture(
        commandIds: const ['cmd-start', 'cmd-scan', 'must-not-be-used'],
      );
      await establishTransaction(
        testFixture,
        snapshot(transactionId: 'txn-1', version: 3),
      );
      testFixture.client.enqueueCommandFailure(
        const PosCoreServerFailure(
          code: 'command_id_reused',
          message: 'ID reused.',
        ),
      );
      await testFixture.controller.scanBarcode('barcode');

      expect(testFixture.controller.state.pendingCommand, isNull);
      expect(testFixture.controller.state.snapshot, isNull);
      expect(testFixture.controller.state.failure, isA<PosCoreServerFailure>());
      expect(testFixture.ids.commandIdCalls, 2);
      expect(testFixture.client.commands, hasLength(2));
      await expectLater(
        testFixture.controller.scanBarcode('new-intent'),
        throwsStateError,
      );
      expect(testFixture.ids.commandIdCalls, 2);

      testFixture.client.enqueueSnapshot(
        snapshot(transactionId: 'txn-1', version: 5),
      );
      await testFixture.controller.refreshTransaction();
      expect(testFixture.controller.state.canExecuteNewMutation, isTrue);
      expect(testFixture.client.commands, hasLength(2));
    },
  );

  test(
    'resolved command with failed GET stays resolved and blocks new mutation',
    () async {
      final testFixture = fixture(
        commandIds: const ['cmd-start', 'cmd-scan', 'must-not-be-used'],
      );
      await establishTransaction(
        testFixture,
        snapshot(transactionId: 'txn-1', version: 3),
      );
      testFixture.client.enqueueCommandResult(
        PosCommandOutcomeKind.accepted,
        outcomeVersion: 4,
      );
      testFixture.client.enqueueTransactionFailure(
        const PosCoreTransportFailure('read failed'),
      );

      await testFixture.controller.scanBarcode('barcode');

      expect(testFixture.controller.state.lastCommandResult!.accepted, isTrue);
      expect(testFixture.controller.state.pendingCommand, isNull);
      expect(testFixture.controller.state.snapshot, isNull);
      expect(testFixture.controller.state.activeTransactionId, 'txn-1');
      await expectLater(
        testFixture.controller.tenderCash(500),
        throwsStateError,
      );
      expect(testFixture.ids.commandIdCalls, 2);

      final posts = testFixture.client.commands.length;
      testFixture.client.enqueueSnapshot(
        snapshot(transactionId: 'txn-1', version: 12),
      );
      await testFixture.controller.refreshTransaction();
      expect(testFixture.controller.state.snapshot!.version, 12);
      expect(testFixture.client.commands, hasLength(posts));
    },
  );

  test(
    'explicit query not-found clears active session without fake snapshot',
    () async {
      final testFixture = fixture();
      testFixture.client.enqueueCommandResult(PosCommandOutcomeKind.accepted);
      testFixture.client.enqueueTransactionFailure(
        const PosCoreServerFailure(
          code: 'transaction_not_found',
          message: 'Missing.',
        ),
      );

      await testFixture.controller.startTransaction();

      expect(testFixture.controller.state.activeTransactionId, isNull);
      expect(testFixture.controller.state.snapshot, isNull);
      expect(testFixture.controller.state.lastCommandResult, isNotNull);
      expect(testFixture.controller.state.failure, isA<PosCoreServerFailure>());
    },
  );

  test(
    'busy command rejects reentrant mutation without consuming an ID',
    () async {
      final testFixture = fixture(
        commandIds: const ['cmd-start', 'cmd-scan', 'must-not-be-used'],
      );
      await establishTransaction(
        testFixture,
        snapshot(transactionId: 'txn-1', version: 3),
      );
      final commandCompleter = Completer<PosCommandResult>();
      testFixture.client.commandHandlers.add((_) => commandCompleter.future);

      final operation = testFixture.controller.scanBarcode('barcode');
      expect(testFixture.controller.state.isBusy, isTrue);
      await expectLater(
        testFixture.controller.tenderCash(500),
        throwsStateError,
      );
      expect(testFixture.ids.commandIdCalls, 2);
      expect(testFixture.client.commands, hasLength(2));

      final submitted = testFixture.client.commands.last;
      testFixture.client.enqueueSnapshot(
        snapshot(transactionId: 'txn-1', version: 4),
      );
      commandCompleter.complete(resultFor(submitted, outcomeVersion: 4));
      await operation;
      expect(
        testFixture.controller.state.activity,
        CashierSessionActivity.idle,
      );
    },
  );

  test('busy refresh rejects mutation and consumes no command ID', () async {
    final testFixture = fixture(
      commandIds: const ['cmd-start', 'must-not-be-used'],
    );
    await establishTransaction(
      testFixture,
      snapshot(transactionId: 'txn-1', version: 3),
    );
    final readCompleter = Completer<TransactionSnapshot>();
    testFixture.client.transactionHandlers.add((_) => readCompleter.future);

    final operation = testFixture.controller.refreshTransaction();
    expect(
      testFixture.controller.state.activity,
      CashierSessionActivity.refreshingTransaction,
    );
    expect(testFixture.controller.state.snapshot, isNull);
    await expectLater(
      testFixture.controller.scanBarcode('barcode'),
      throwsStateError,
    );
    expect(testFixture.ids.commandIdCalls, 1);

    readCompleter.complete(snapshot(transactionId: 'txn-1', version: 4));
    await operation;
    expect(testFixture.controller.state.activity, CashierSessionActivity.idle);
    expect(testFixture.controller.state.snapshot!.version, 4);
  });

  test('invalid payload input consumes no command ID', () async {
    final testFixture = fixture(
      commandIds: const ['cmd-start', 'must-not-be-used'],
    );
    await establishTransaction(
      testFixture,
      snapshot(transactionId: 'txn-1', version: 3),
    );

    await expectLater(
      testFixture.controller.scanBarcode(''),
      throwsArgumentError,
    );
    await expectLater(
      testFixture.controller.tenderCash(-1),
      throwsArgumentError,
    );
    await expectLater(
      testFixture.controller.removeLineItem(-1),
      throwsArgumentError,
    );

    expect(testFixture.ids.commandIdCalls, 1);
    expect(testFixture.client.commands, hasLength(1));
  });

  test(
    'correction commands use the trusted snapshot version and one new ID',
    () async {
      final testFixture = fixture(
        commandIds: const ['cmd-start', 'cmd-remove', 'cmd-void'],
      );
      await establishTransaction(
        testFixture,
        snapshot(transactionId: 'txn-1', version: 7),
      );
      testFixture.client.enqueueCommandResult(PosCommandOutcomeKind.accepted);
      testFixture.client.enqueueSnapshot(
        snapshot(transactionId: 'txn-1', version: 8),
      );

      await testFixture.controller.removeLineItem(2);

      final remove = testFixture.client.commands[1] as RemoveLineItemCommand;
      expect(remove.commandId, 'cmd-remove');
      expect(remove.transactionId, 'txn-1');
      expect(remove.expectedVersion, 7);
      expect(remove.lineIndex, 2);

      testFixture.client.enqueueCommandResult(PosCommandOutcomeKind.accepted);
      testFixture.client.enqueueSnapshot(
        snapshot(
          transactionId: 'txn-1',
          version: 9,
          status: TransactionStatus.voided,
        ),
      );

      await testFixture.controller.voidTransaction();

      final voidCommand =
          testFixture.client.commands[2] as VoidTransactionCommand;
      expect(voidCommand.commandId, 'cmd-void');
      expect(voidCommand.transactionId, 'txn-1');
      expect(voidCommand.expectedVersion, 8);
      expect(
        testFixture.controller.state.snapshot!.status,
        TransactionStatus.voided,
      );
      expect(testFixture.ids.commandIdCalls, 3);
    },
  );

  test(
    'accepted corrections never update state before authoritative GET',
    () async {
      final testFixture = fixture(
        commandIds: const ['cmd-start', 'cmd-remove', 'cmd-void'],
      );
      final original = snapshot(
        transactionId: 'txn-1',
        version: 4,
        lineItems: const [
          TransactionLineItem(
            barcode: 'A',
            description: 'Apples',
            unitPriceMinorUnits: 199,
          ),
        ],
        subtotalMinorUnits: 199,
        totalMinorUnits: 199,
      );
      await establishTransaction(testFixture, original);
      final removeResult = Completer<PosCommandResult>();
      final removeRead = Completer<TransactionSnapshot>();
      testFixture.client.commandHandlers.add((command) => removeResult.future);
      testFixture.client.transactionHandlers.add((_) => removeRead.future);

      final removal = testFixture.controller.removeLineItem(0);
      removeResult.complete(
        resultFor(testFixture.client.commands.last, outcomeVersion: 5),
      );
      await Future<void>.delayed(Duration.zero);

      expect(testFixture.controller.state.snapshot, isNull);
      expect(
        testFixture.controller.state.activity,
        CashierSessionActivity.refreshingTransaction,
      );
      removeRead.complete(snapshot(transactionId: 'txn-1', version: 5));
      await removal;

      final voidResult = Completer<PosCommandResult>();
      final voidRead = Completer<TransactionSnapshot>();
      testFixture.client.commandHandlers.add((command) => voidResult.future);
      testFixture.client.transactionHandlers.add((_) => voidRead.future);
      final voiding = testFixture.controller.voidTransaction();
      voidResult.complete(
        resultFor(testFixture.client.commands.last, outcomeVersion: 6),
      );
      await Future<void>.delayed(Duration.zero);

      expect(testFixture.controller.state.snapshot, isNull);
      expect(
        testFixture.controller.state.activity,
        CashierSessionActivity.refreshingTransaction,
      );
      final authoritativeVoided = snapshot(
        transactionId: 'txn-1',
        version: 6,
        status: TransactionStatus.voided,
      );
      voidRead.complete(authoritativeVoided);
      await voiding;
      expect(testFixture.controller.state.snapshot, same(authoritativeVoided));
    },
  );
}
