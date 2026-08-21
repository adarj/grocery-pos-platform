import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_health.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/core/pos_core/pos_core_client.dart';
import 'package:pos_terminal/features/cashier/cashier_id_generator.dart';
import 'package:pos_terminal/features/cashier/cashier_screen.dart';
import 'package:pos_terminal/features/cashier/cashier_session_controller.dart';

typedef CommandHandler =
    Future<PosCommandResult> Function(TransactionCommand command);
typedef TransactionHandler =
    Future<TransactionSnapshot> Function(String transactionId);

final class FakeCashierClient implements PosCoreClient {
  final Queue<CommandHandler> commandHandlers = Queue();
  final Queue<TransactionHandler> transactionHandlers = Queue();
  final List<TransactionCommand> commands = [];
  final List<String> reads = [];

  @override
  Future<PosCoreHealth> fetchHealth() {
    throw UnimplementedError();
  }

  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) {
    commands.add(command);
    if (commandHandlers.isEmpty) {
      throw StateError('No command response queued.');
    }
    return commandHandlers.removeFirst()(command);
  }

  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) {
    reads.add(transactionId);
    if (transactionHandlers.isEmpty) {
      throw StateError('No transaction response queued.');
    }
    return transactionHandlers.removeFirst()(transactionId);
  }

  void enqueueResult(
    PosCommandOutcomeKind kind, {
    String? code,
    int version = 1,
  }) {
    commandHandlers.add((command) async {
      return resultFor(command, kind: kind, code: code, version: version);
    });
  }

  void enqueueCommandFailure(PosCoreFailure failure) {
    commandHandlers.add((_) async => throw failure);
  }

  void enqueueSnapshot(TransactionSnapshot value) {
    transactionHandlers.add((_) async => value);
  }

  void enqueueReadFailure(PosCoreFailure failure) {
    transactionHandlers.add((_) async => throw failure);
  }
}

final class DeterministicCashierIds implements CashierIdGenerator {
  DeterministicCashierIds({
    Iterable<String> commandIds = const ['cmd-start', 'cmd-scan'],
    Iterable<String> transactionIds = const ['txn-1'],
  }) : _commandIds = Queue.of(commandIds),
       _transactionIds = Queue.of(transactionIds);

  final Queue<String> _commandIds;
  final Queue<String> _transactionIds;

  @override
  String nextCommandId() => _commandIds.removeFirst();

  @override
  String nextTransactionId() => _transactionIds.removeFirst();
}

PosCommandResult resultFor(
  TransactionCommand command, {
  PosCommandOutcomeKind kind = PosCommandOutcomeKind.accepted,
  String? code,
  int version = 1,
}) {
  return PosCommandResult(
    commandId: command.commandId,
    transactionId: command.transactionId,
    outcomeKind: kind,
    outcomeCode: code ?? kind.wireName,
    outcomeStreamVersion: version,
  );
}

TransactionSnapshot snapshot({
  int version = 1,
  TransactionStatus status = TransactionStatus.open,
  List<TransactionLineItem> lineItems = const [],
  int subtotal = 0,
  int total = 0,
}) {
  return TransactionSnapshot(
    transactionId: 'txn-1',
    version: version,
    status: status,
    lineItems: lineItems,
    subtotalMinorUnits: subtotal,
    totalMinorUnits: total,
    tenderedCashMinorUnits: null,
    changeDueMinorUnits: null,
  );
}

({FakeCashierClient client, CashierSessionController controller}) fixture({
  Iterable<String> commandIds = const ['cmd-start', 'cmd-scan'],
  Iterable<String> transactionIds = const ['txn-1'],
}) {
  final client = FakeCashierClient();
  final controller = CashierSessionController(
    client: client,
    idGenerator: DeterministicCashierIds(
      commandIds: commandIds,
      transactionIds: transactionIds,
    ),
  );
  return (client: client, controller: controller);
}

Future<void> establishTransaction(
  ({FakeCashierClient client, CashierSessionController controller}) testFixture,
  TransactionSnapshot authoritative,
) async {
  testFixture.client.enqueueResult(PosCommandOutcomeKind.accepted);
  testFixture.client.enqueueSnapshot(authoritative);
  await testFixture.controller.startTransaction();
}

Future<void> pumpCashier(
  WidgetTester tester,
  CashierSessionController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(home: CashierScreen(controller: controller)),
  );
  await tester.pump();
}

Finder get barcodeField => find.byKey(const Key('cashier-barcode-field'));

void main() {
  testWidgets('initial cashier offers Start Sale and no fabricated basket', (
    tester,
  ) async {
    final testFixture = fixture();
    await pumpCashier(tester, testFixture.controller);

    expect(find.text('Start Sale'), findsOneWidget);
    expect(barcodeField, findsNothing);
    expect(find.text('Basket'), findsNothing);
    expect(find.text('No items scanned yet.'), findsNothing);
    expect(testFixture.client.commands, isEmpty);
  });

  testWidgets('Start Sale submits once and remains disabled while executing', (
    tester,
  ) async {
    final testFixture = fixture();
    final commandCompleter = Completer<PosCommandResult>();
    testFixture.client.commandHandlers.add((_) => commandCompleter.future);
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Start Sale'));
    await tester.pump();

    expect(testFixture.client.commands, hasLength(1));
    expect(find.text('Starting sale...'), findsOneWidget);
    expect(find.text('Start Sale'), findsNothing);

    final command = testFixture.client.commands.single;
    final readCompleter = Completer<TransactionSnapshot>();
    testFixture.client.transactionHandlers.add((_) => readCompleter.future);
    commandCompleter.complete(resultFor(command));
    await tester.pump();
    expect(find.text('Loading latest transaction state...'), findsOneWidget);
    expect(find.text('Basket'), findsNothing);

    readCompleter.complete(snapshot(version: 7));
    await tester.pumpAndSettle();
    expect(find.text('Basket'), findsOneWidget);
    expect(find.text('Status: Open'), findsOneWidget);
    expect(find.text('Transaction version 7'), findsOneWidget);
    expect(find.text('No items scanned yet.'), findsOneWidget);
  });

  testWidgets(
    'start alreadyExists stays detached and permits a new Start Sale',
    (tester) async {
      final testFixture = fixture(
        commandIds: const ['cmd-start-1', 'cmd-start-2'],
        transactionIds: const ['txn-1', 'txn-2'],
      );
      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.alreadyExists,
        code: 'transaction_already_exists',
        version: 5,
      );
      await pumpCashier(tester, testFixture.controller);

      await tester.tap(find.text('Start Sale'));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not start sale. Please try again.'),
        findsOneWidget,
      );
      expect(find.text('Start Sale'), findsOneWidget);
      expect(find.text('Basket'), findsNothing);
      expect(testFixture.client.commands, hasLength(1));

      final secondCommandCompleter = Completer<PosCommandResult>();
      testFixture.client.commandHandlers.add(
        (_) => secondCommandCompleter.future,
      );
      await tester.tap(find.text('Start Sale'));
      await tester.pump();
      expect(testFixture.client.commands, hasLength(2));
    },
  );

  testWidgets('basket preserves backend order and backend totals exactly', (
    tester,
  ) async {
    final testFixture = fixture();
    await establishTransaction(
      testFixture,
      snapshot(
        version: 11,
        lineItems: const [
          TransactionLineItem(
            barcode: 'first-code',
            description: 'First item',
            unitPriceMinorUnits: 199,
          ),
          TransactionLineItem(
            barcode: 'second-code',
            description: 'Second item',
            unitPriceMinorUnits: 500,
          ),
        ],
        subtotal: 999,
        total: 1234,
      ),
    );
    await pumpCashier(tester, testFixture.controller);

    expect(find.text('First item'), findsOneWidget);
    expect(find.text('Barcode: first-code'), findsOneWidget);
    expect(find.text(r'$1.99'), findsOneWidget);
    expect(find.text('Second item'), findsOneWidget);
    expect(find.text('Barcode: second-code'), findsOneWidget);
    expect(find.text(r'$5.00'), findsOneWidget);
    expect(find.text(r'$9.99'), findsOneWidget);
    expect(find.text(r'$12.34'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('First item')).dy,
      lessThan(tester.getTopLeft(find.text('Second item')).dy),
    );
  });

  testWidgets(
    'button submission preserves barcode and clears after safe refresh',
    (tester) async {
      final testFixture = fixture();
      await establishTransaction(testFixture, snapshot(version: 3));
      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.accepted,
        version: 4,
      );
      testFixture.client.enqueueSnapshot(snapshot(version: 4));
      await pumpCashier(tester, testFixture.controller);

      await tester.enterText(barcodeField, ' Mixed-Case Barcode ');
      await tester.tap(find.text('Scan Item'));
      await tester.pumpAndSettle();

      final scan = testFixture.client.commands.last as ScanBarcodeCommand;
      expect(scan.barcode, ' Mixed-Case Barcode ');
      expect(scan.expectedVersion, 3);
      expect(tester.widget<TextField>(barcodeField).controller!.text, isEmpty);
      expect(
        tester.widget<TextField>(barcodeField).focusNode!.hasFocus,
        isTrue,
      );
    },
  );

  testWidgets('keyboard Enter submits one barcode command', (tester) async {
    final testFixture = fixture();
    await establishTransaction(testFixture, snapshot(version: 2));
    testFixture.client.enqueueResult(PosCommandOutcomeKind.accepted);
    testFixture.client.enqueueSnapshot(snapshot(version: 3));
    await pumpCashier(tester, testFixture.controller);

    await tester.enterText(barcodeField, 'keyboard-barcode');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(testFixture.client.commands, hasLength(2));
    expect(
      (testFixture.client.commands.last as ScanBarcodeCommand).barcode,
      'keyboard-barcode',
    );
  });

  testWidgets('empty barcode shows validation and sends no command', (
    tester,
  ) async {
    final testFixture = fixture();
    await establishTransaction(testFixture, snapshot());
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Scan Item'));
    await tester.pump();

    expect(find.text('Enter a barcode.'), findsOneWidget);
    expect(testFixture.client.commands, hasLength(1));
  });

  testWidgets('busy scan prevents a second scan submission', (tester) async {
    final testFixture = fixture();
    await establishTransaction(testFixture, snapshot(version: 2));
    final commandCompleter = Completer<PosCommandResult>();
    testFixture.client.commandHandlers.add((_) => commandCompleter.future);
    await pumpCashier(tester, testFixture.controller);

    await tester.enterText(barcodeField, 'one-scan');
    await tester.tap(find.text('Scan Item'));
    await tester.pump();

    expect(find.text('Processing item...'), findsOneWidget);
    expect(barcodeField, findsNothing);
    expect(testFixture.client.commands, hasLength(2));
  });

  testWidgets('scan item appears only after authoritative GET completes', (
    tester,
  ) async {
    final testFixture = fixture();
    await establishTransaction(testFixture, snapshot(version: 1));
    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.accepted,
      version: 2,
    );
    final readCompleter = Completer<TransactionSnapshot>();
    testFixture.client.transactionHandlers.add((_) => readCompleter.future);
    await pumpCashier(tester, testFixture.controller);

    await tester.enterText(barcodeField, '049000001234');
    await tester.tap(find.text('Scan Item'));
    await tester.pump();

    expect(find.text('Test Apples'), findsNothing);
    expect(find.text('No items scanned yet.'), findsNothing);
    expect(find.text('Loading latest transaction state...'), findsOneWidget);

    readCompleter.complete(
      snapshot(
        version: 2,
        lineItems: const [
          TransactionLineItem(
            barcode: '049000001234',
            description: 'Test Apples',
            unitPriceMinorUnits: 199,
          ),
        ],
        subtotal: 250,
        total: 301,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Test Apples'), findsOneWidget);
    expect(find.text(r'$2.50'), findsOneWidget);
    expect(find.text(r'$3.01'), findsOneWidget);
  });

  testWidgets('unknown barcode shows stable feedback and retains input', (
    tester,
  ) async {
    final testFixture = fixture();
    final authoritative = snapshot(version: 4);
    await establishTransaction(testFixture, authoritative);
    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.domainRejected,
      code: 'unknown_barcode',
      version: 4,
    );
    testFixture.client.enqueueSnapshot(authoritative);
    await pumpCashier(tester, testFixture.controller);

    await tester.enterText(barcodeField, 'unknown-code');
    await tester.tap(find.text('Scan Item'));
    await tester.pumpAndSettle();

    expect(find.text('Item not found.'), findsOneWidget);
    expect(find.text('No items scanned yet.'), findsOneWidget);
    expect(
      tester.widget<TextField>(barcodeField).controller!.text,
      'unknown-code',
    );
    expect(testFixture.client.commands, hasLength(2));
  });

  testWidgets(
    'version conflict renders refreshed state without automatic rescan',
    (tester) async {
      final testFixture = fixture();
      await establishTransaction(testFixture, snapshot(version: 3));
      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.versionConflict,
        code: 'stale_expected_version',
        version: 5,
      );
      testFixture.client.enqueueSnapshot(
        snapshot(
          version: 5,
          lineItems: const [
            TransactionLineItem(
              barcode: 'other',
              description: 'Concurrent item',
              unitPriceMinorUnits: 700,
            ),
          ],
          subtotal: 700,
          total: 700,
        ),
      );
      await pumpCashier(tester, testFixture.controller);

      await tester.enterText(barcodeField, 'stale-scan');
      await tester.tap(find.text('Scan Item'));
      await tester.pumpAndSettle();

      expect(
        find.text('Transaction changed. Latest state loaded.'),
        findsOneWidget,
      );
      expect(find.text('Concurrent item'), findsOneWidget);
      expect(testFixture.client.commands, hasLength(2));
    },
  );

  testWidgets('pending command offers only explicit same-command recovery', (
    tester,
  ) async {
    final testFixture = fixture();
    await establishTransaction(testFixture, snapshot(version: 2));
    testFixture.client.enqueueCommandFailure(
      const PosCoreTransportFailure('unknown', retrySameCommandId: true),
    );
    await pumpCashier(tester, testFixture.controller);

    await tester.enterText(barcodeField, 'pending-scan');
    await tester.tap(find.text('Scan Item'));
    await tester.pumpAndSettle();

    final pending = testFixture.controller.state.pendingCommand!;
    expect(find.text('Command result unknown'), findsOneWidget);
    expect(find.text('Retry Command'), findsOneWidget);
    expect(find.text('Refresh Transaction'), findsNothing);
    expect(find.text('Scan Item'), findsNothing);

    testFixture.client.enqueueCommandFailure(
      const PosCoreServerFailure(
        code: 'command_outcome_unknown',
        message: 'Still unknown.',
        retrySameCommandId: true,
      ),
    );
    await tester.tap(find.text('Retry Command'));
    await tester.pumpAndSettle();
    expect(identical(testFixture.client.commands.last, pending), isTrue);
    expect(find.text('Command result unknown'), findsOneWidget);

    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.accepted,
      version: 3,
    );
    testFixture.client.enqueueSnapshot(
      snapshot(
        version: 3,
        lineItems: const [
          TransactionLineItem(
            barcode: 'pending-scan',
            description: 'Recovered item',
            unitPriceMinorUnits: 199,
          ),
        ],
        subtotal: 199,
        total: 199,
      ),
    );
    await tester.tap(find.text('Retry Command'));
    await tester.pumpAndSettle();

    expect(identical(testFixture.client.commands.last, pending), isTrue);
    expect(find.text('Command result unknown'), findsNothing);
    expect(find.text('Recovered item'), findsOneWidget);
  });

  testWidgets(
    'known command with failed GET offers refresh without another POST',
    (tester) async {
      final testFixture = fixture();
      await establishTransaction(testFixture, snapshot(version: 2));
      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.accepted,
        version: 3,
      );
      testFixture.client.enqueueReadFailure(
        const PosCoreTransportFailure('read unavailable'),
      );
      await pumpCashier(tester, testFixture.controller);

      await tester.enterText(barcodeField, 'accepted-scan');
      await tester.tap(find.text('Scan Item'));
      await tester.pumpAndSettle();

      expect(find.text('Transaction state unavailable'), findsOneWidget);
      expect(find.text('Refresh Transaction'), findsOneWidget);
      expect(find.text('Retry Command'), findsNothing);
      expect(find.text('No items scanned yet.'), findsNothing);
      final postCount = testFixture.client.commands.length;

      testFixture.client.enqueueSnapshot(
        snapshot(
          version: 3,
          lineItems: const [
            TransactionLineItem(
              barcode: 'accepted-scan',
              description: 'Loaded item',
              unitPriceMinorUnits: 199,
            ),
          ],
          subtotal: 199,
          total: 199,
        ),
      );
      await tester.tap(find.text('Refresh Transaction'));
      await tester.pumpAndSettle();

      expect(testFixture.client.commands, hasLength(postCount));
      expect(find.text('Loaded item'), findsOneWidget);
    },
  );

  testWidgets('safe failure UI exposes no command or persistence internals', (
    tester,
  ) async {
    final testFixture = fixture();
    testFixture.client.enqueueCommandFailure(
      const PosCoreTransportFailure('POS Core unavailable.'),
    );
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Start Sale'));
    await tester.pumpAndSettle();

    expect(find.text('POS Core request failed.'), findsOneWidget);
    expect(find.text('POS Core unavailable.'), findsOneWidget);
    expect(find.textContaining('cmd-start'), findsNothing);
    expect(find.textContaining('expected_version'), findsNothing);
    expect(find.textContaining('SQLite'), findsNothing);
    expect(find.text('Tender Cash'), findsNothing);
    expect(find.text('Complete Sale'), findsNothing);
  });

  testWidgets('wide and narrow cashier layouts render without overflow', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final testFixture = fixture();
    await establishTransaction(
      testFixture,
      snapshot(
        lineItems: const [
          TransactionLineItem(
            barcode: 'item',
            description: 'Responsive item',
            unitPriceMinorUnits: 199,
          ),
        ],
        subtotal: 199,
        total: 199,
      ),
    );

    await tester.binding.setSurfaceSize(const Size(1200, 700));
    await pumpCashier(tester, testFixture.controller);
    expect(tester.takeException(), isNull);
    expect(find.text('Responsive item'), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(420, 700));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Responsive item'), findsOneWidget);
  });
}
