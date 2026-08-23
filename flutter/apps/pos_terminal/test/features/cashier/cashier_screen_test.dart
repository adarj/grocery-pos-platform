import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/canonical_receipt.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_health.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/core/pos_core/pos_core_client.dart';
import 'package:pos_terminal/features/cashier/cashier_id_generator.dart';
import 'package:pos_terminal/features/cashier/cashier_screen.dart';
import 'package:pos_terminal/features/cashier/cashier_session_controller.dart';
import 'package:pos_terminal/features/cashier/cashier_session_store.dart';

typedef CommandHandler =
    Future<PosCommandResult> Function(TransactionCommand command);
typedef TransactionHandler =
    Future<TransactionSnapshot> Function(String transactionId);
typedef ReceiptHandler =
    Future<CanonicalReceipt> Function(String transactionId);

final class FakeCashierClient implements PosCoreClient {
  final Queue<CommandHandler> commandHandlers = Queue();
  final Queue<TransactionHandler> transactionHandlers = Queue();
  final Queue<ReceiptHandler> receiptHandlers = Queue();
  final List<TransactionCommand> commands = [];
  final List<String> reads = [];
  final List<String> receiptReads = [];

  @override
  Future<CanonicalReceipt> fetchReceipt(String transactionId) {
    receiptReads.add(transactionId);
    if (receiptHandlers.isEmpty) {
      throw StateError('No receipt response queued.');
    }
    return receiptHandlers.removeFirst()(transactionId);
  }

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
  int commandIdCalls = 0;
  int transactionIdCalls = 0;

  @override
  String nextCommandId() {
    commandIdCalls += 1;
    return _commandIds.removeFirst();
  }

  @override
  String nextTransactionId() {
    transactionIdCalls += 1;
    return _transactionIds.removeFirst();
  }
}

final class MemoryCashierSessionStore implements CashierSessionStore {
  MemoryCashierSessionStore({this.persisted});

  PersistedCashierSession? persisted;
  CashierSessionStoreFailure? loadFailure;
  CashierSessionStoreFailure? nextSaveFailure;
  CashierSessionStoreFailure? nextClearFailure;

  @override
  Future<PersistedCashierSession?> load() async {
    final failure = loadFailure;
    if (failure != null) {
      throw failure;
    }
    return persisted;
  }

  @override
  Future<void> save(PersistedCashierSession session) async {
    final failure = nextSaveFailure;
    nextSaveFailure = null;
    if (failure != null) {
      throw failure;
    }
    persisted = session;
  }

  @override
  Future<void> clear() async {
    final failure = nextClearFailure;
    nextClearFailure = null;
    if (failure != null) {
      throw failure;
    }
    persisted = null;
  }
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
  String transactionId = 'txn-1',
  int version = 1,
  TransactionStatus status = TransactionStatus.open,
  List<TransactionLineItem> lineItems = const [],
  int subtotal = 0,
  int tax = 0,
  int total = 0,
  int? tenderedCash,
  int? changeDue,
}) {
  return TransactionSnapshot(
    transactionId: transactionId,
    version: version,
    status: status,
    lineItems: lineItems,
    subtotalMinorUnits: subtotal,
    taxMinorUnits: tax,
    totalMinorUnits: total,
    tenderedCashMinorUnits: tenderedCash,
    changeDueMinorUnits: changeDue,
  );
}

CanonicalReceipt canonicalReceipt({String transactionId = 'txn-1'}) {
  return CanonicalReceipt(
    schemaVersion: 1,
    transactionId: transactionId,
    transactionVersion: 6,
    lineItems: const [
      CanonicalReceiptLine(
        barcode: 'receipt-barcode',
        description: 'Receipt-only Apples',
        unitPriceMinorUnits: 321,
        taxCategoryId: 'receipt-tax',
        taxRateMillionths: 100000,
        taxAmountMinorUnits: 32,
      ),
    ],
    subtotalMinorUnits: 321,
    taxMinorUnits: 32,
    totalMinorUnits: 353,
    tenderedCashMinorUnits: 500,
    changeDueMinorUnits: 147,
  );
}

({
  FakeCashierClient client,
  CashierSessionController controller,
  DeterministicCashierIds ids,
})
fixture({
  Iterable<String> commandIds = const ['cmd-start', 'cmd-scan'],
  Iterable<String> transactionIds = const ['txn-1'],
  MemoryCashierSessionStore? sessionStore,
}) {
  final client = FakeCashierClient();
  final ids = DeterministicCashierIds(
    commandIds: commandIds,
    transactionIds: transactionIds,
  );
  final controller = CashierSessionController(
    client: client,
    idGenerator: ids,
    sessionStore: sessionStore ?? MemoryCashierSessionStore(),
  );
  return (client: client, controller: controller, ids: ids);
}

Future<void> establishTransaction(
  ({
    FakeCashierClient client,
    CashierSessionController controller,
    DeterministicCashierIds ids,
  })
  testFixture,
  TransactionSnapshot authoritative,
) async {
  testFixture.client.enqueueResult(PosCommandOutcomeKind.accepted);
  testFixture.client.enqueueSnapshot(authoritative);
  await testFixture.controller.startTransaction();
}

Future<void> pumpCashier(
  WidgetTester tester,
  CashierSessionController controller, {
  TextScaler? textScaler,
  PosCoreClient? receiptClient,
}) async {
  Widget screen = CashierScreen(
    controller: controller,
    client: receiptClient ?? FakeCashierClient(),
  );
  if (textScaler != null) {
    screen = MediaQuery(
      data: MediaQueryData(textScaler: textScaler),
      child: screen,
    );
  }
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pump();
}

Finder get barcodeField => find.byKey(const Key('cashier-barcode-field'));
Finder get cashField => find.byKey(const Key('cashier-cash-field'));

void main() {
  testWidgets('initial cashier offers Start Sale and no fabricated basket', (
    tester,
  ) async {
    final testFixture = fixture();
    await pumpCashier(tester, testFixture.controller);

    expect(find.text('Start Sale'), findsOneWidget);
    expect(barcodeField, findsNothing);
    expect(cashField, findsNothing);
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
    expect(tester.widget<TextField>(barcodeField).focusNode!.hasFocus, isTrue);
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
        tax: 777,
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
    expect(find.text('Tax'), findsOneWidget);
    expect(find.text(r'$7.77'), findsOneWidget);
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
    expect(tester.widget<TextField>(barcodeField).focusNode!.hasFocus, isTrue);
    expect(
      tester.widget<TextField>(barcodeField).controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 12),
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

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await pumpCashier(tester, testFixture.controller);
    expect(tester.takeException(), isNull);
    expect(find.text('Responsive item'), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(1024, 768));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(600, 800));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Responsive item'), findsOneWidget);
  });

  testWidgets('open transaction presents scan and cash tender controls', (
    tester,
  ) async {
    final testFixture = fixture();
    await establishTransaction(testFixture, snapshot(version: 4, total: 500));
    await pumpCashier(tester, testFixture.controller);

    expect(barcodeField, findsOneWidget);
    expect(find.text('Scan Item'), findsOneWidget);
    expect(cashField, findsOneWidget);
    expect(find.text('Take Cash'), findsOneWidget);
    expect(find.text('Complete Sale'), findsNothing);
  });

  testWidgets(
    'valid cash input submits exact minor units and current version',
    (tester) async {
      final testFixture = fixture();
      final authoritative = snapshot(version: 8, total: 199);
      await establishTransaction(testFixture, authoritative);
      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.domainRejected,
        code: 'insufficient_tender',
        version: 8,
      );
      testFixture.client.enqueueSnapshot(authoritative);
      await pumpCashier(tester, testFixture.controller);

      await tester.enterText(cashField, '5.00');
      await tester.tap(find.text('Take Cash'));
      await tester.pumpAndSettle();

      final tender = testFixture.client.commands.last as TenderCashCommand;
      expect(tender.amountMinorUnits, 500);
      expect(tender.expectedVersion, 8);
      expect(testFixture.client.commands, hasLength(2));
    },
  );

  testWidgets(
    'cash Enter submits tender and presentation-invalid text does not',
    (tester) async {
      final testFixture = fixture();
      final authoritative = snapshot(version: 3, total: 500);
      await establishTransaction(testFixture, authoritative);
      await pumpCashier(tester, testFixture.controller);

      await tester.tap(find.text('Take Cash'));
      await tester.pump();
      expect(find.text('Enter cash received.'), findsOneWidget);
      expect(testFixture.client.commands, hasLength(1));

      await tester.enterText(cashField, r'$5.00');
      await tester.tap(find.text('Take Cash'));
      await tester.pump();
      expect(find.text('Enter a valid cash amount.'), findsOneWidget);
      expect(testFixture.client.commands, hasLength(1));

      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.domainRejected,
        code: 'insufficient_tender',
        version: 3,
      );
      testFixture.client.enqueueSnapshot(authoritative);
      await tester.enterText(cashField, '4.00');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(testFixture.client.commands.last, isA<TenderCashCommand>());
      expect(
        (testFixture.client.commands.last as TenderCashCommand)
            .amountMinorUnits,
        400,
      );
    },
  );

  testWidgets(
    'below-total tender is sent to Racket rather than blocked locally',
    (tester) async {
      final testFixture = fixture();
      final authoritative = snapshot(version: 6, total: 500);
      await establishTransaction(testFixture, authoritative);
      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.domainRejected,
        code: 'insufficient_tender',
        version: 6,
      );
      testFixture.client.enqueueSnapshot(authoritative);
      await pumpCashier(tester, testFixture.controller);

      await tester.enterText(cashField, '4.00');
      await tester.tap(find.text('Take Cash'));
      await tester.pumpAndSettle();

      final tender = testFixture.client.commands.last as TenderCashCommand;
      expect(tender.amountMinorUnits, 400);
      expect(
        find.text('Cash received is less than the amount due.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('accepted tender does not show paid or change before GET', (
    tester,
  ) async {
    final testFixture = fixture();
    await establishTransaction(testFixture, snapshot(version: 2, total: 199));
    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.accepted,
      version: 3,
    );
    final readCompleter = Completer<TransactionSnapshot>();
    testFixture.client.transactionHandlers.add((_) => readCompleter.future);
    await pumpCashier(tester, testFixture.controller);

    await tester.enterText(cashField, '5.00');
    final barcodeFocusNode = tester.widget<TextField>(barcodeField).focusNode!;
    final cashFocusNode = tester.widget<TextField>(cashField).focusNode!;
    await tester.tap(find.text('Take Cash'));
    await tester.pump();

    expect(find.text('Status: Paid'), findsNothing);
    expect(find.text('Payment accepted'), findsNothing);
    expect(find.text('Change due'), findsNothing);
    expect(find.text('Loading latest transaction state...'), findsOneWidget);
    expect(find.text('Basket'), findsNothing);

    readCompleter.complete(
      snapshot(
        version: 3,
        status: TransactionStatus.paid,
        total: 199,
        tenderedCash: 500,
        changeDue: 777,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Status: Paid'), findsOneWidget);
    expect(find.text('Payment accepted'), findsOneWidget);
    expect(find.text(r'$1.99'), findsWidgets);
    expect(find.text(r'$5.00'), findsOneWidget);
    expect(find.text(r'$7.77'), findsOneWidget);
    expect(find.text(r'$3.01'), findsNothing);
    expect(find.text('Complete Sale'), findsOneWidget);
    expect(barcodeField, findsNothing);
    expect(cashField, findsNothing);
    expect(barcodeFocusNode.hasFocus, isFalse);
    expect(cashFocusNode.hasFocus, isFalse);
  });

  testWidgets(
    'paid snapshot with null payment details fails presentation safely',
    (tester) async {
      final testFixture = fixture();
      await establishTransaction(
        testFixture,
        snapshot(status: TransactionStatus.paid, total: 199),
      );
      await pumpCashier(tester, testFixture.controller);

      expect(find.text('Payment details unavailable'), findsOneWidget);
      expect(find.text('Cash received'), findsNothing);
      expect(find.text('Change due'), findsNothing);
      expect(find.text('Complete Sale'), findsOneWidget);
    },
  );

  for (final testCase in [
    ('insufficient_tender', 'Cash received is less than the amount due.'),
    ('empty_transaction', 'Scan at least one item before taking payment.'),
    (
      'invalid_transaction_state',
      'That action is no longer valid. Latest state loaded.',
    ),
  ]) {
    testWidgets(
      '${testCase.$1} retains tender and never automatically retries',
      (tester) async {
        final testFixture = fixture();
        final authoritative = snapshot(version: 5, total: 900);
        await establishTransaction(testFixture, authoritative);
        testFixture.client.enqueueResult(
          PosCommandOutcomeKind.domainRejected,
          code: testCase.$1,
          version: 5,
        );
        testFixture.client.enqueueSnapshot(authoritative);
        await pumpCashier(tester, testFixture.controller);

        await tester.enterText(cashField, '4.00');
        await tester.tap(find.text('Take Cash'));
        await tester.pumpAndSettle();

        expect(find.text(testCase.$2), findsOneWidget);
        expect(tester.widget<TextField>(cashField).controller!.text, '4.00');
        expect(tester.widget<TextField>(cashField).focusNode!.hasFocus, isTrue);
        expect(
          tester.widget<TextField>(cashField).controller!.selection,
          const TextSelection(baseOffset: 0, extentOffset: 4),
        );
        expect(testFixture.client.commands, hasLength(2));
      },
    );
  }

  testWidgets(
    'uncertain tender retries the exact pending command then renders paid',
    (tester) async {
      final testFixture = fixture();
      await establishTransaction(testFixture, snapshot(version: 2, total: 199));
      testFixture.client.enqueueCommandFailure(
        const PosCoreTransportFailure('unknown', retrySameCommandId: true),
      );
      await pumpCashier(tester, testFixture.controller);

      await tester.enterText(cashField, '5.00');
      await tester.tap(find.text('Take Cash'));
      await tester.pumpAndSettle();

      final pending = testFixture.controller.state.pendingCommand!;
      expect(pending, isA<TenderCashCommand>());
      expect(find.text('Command result unknown'), findsOneWidget);
      expect(find.text('Retry Command'), findsOneWidget);
      expect(find.text('Scan Item'), findsNothing);
      expect(find.text('Take Cash'), findsNothing);

      testFixture.client.enqueueCommandFailure(
        const PosCoreTransportFailure(
          'still unknown',
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
          status: TransactionStatus.paid,
          total: 199,
          tenderedCash: 500,
          changeDue: 301,
        ),
      );
      await tester.tap(find.text('Retry Command'));
      await tester.pumpAndSettle();

      expect(identical(testFixture.client.commands.last, pending), isTrue);
      expect(find.text('Payment accepted'), findsOneWidget);
      expect(find.text(r'$3.01'), findsOneWidget);
    },
  );

  testWidgets(
    'tender accepted with failed GET uses refresh without second POST',
    (tester) async {
      final testFixture = fixture();
      await establishTransaction(testFixture, snapshot(version: 2, total: 199));
      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.accepted,
        version: 3,
      );
      testFixture.client.enqueueReadFailure(
        const PosCoreTransportFailure('read unavailable'),
      );
      await pumpCashier(tester, testFixture.controller);

      await tester.enterText(cashField, '5.00');
      await tester.tap(find.text('Take Cash'));
      await tester.pumpAndSettle();

      expect(find.text('Transaction state unavailable'), findsOneWidget);
      expect(find.text('Refresh Transaction'), findsOneWidget);
      expect(find.text('Retry Command'), findsNothing);
      final posts = testFixture.client.commands.length;

      testFixture.client.enqueueSnapshot(
        snapshot(
          version: 3,
          status: TransactionStatus.paid,
          total: 199,
          tenderedCash: 500,
          changeDue: 301,
        ),
      );
      await tester.tap(find.text('Refresh Transaction'));
      await tester.pumpAndSettle();

      expect(testFixture.client.commands, hasLength(posts));
      expect(find.text('Payment accepted'), findsOneWidget);
    },
  );

  testWidgets('completion waits for authoritative completed snapshot', (
    tester,
  ) async {
    final testFixture = fixture();
    final paid = snapshot(
      version: 3,
      status: TransactionStatus.paid,
      total: 199,
      tenderedCash: 500,
      changeDue: 301,
    );
    await establishTransaction(testFixture, paid);
    final commandCompleter = Completer<PosCommandResult>();
    final readCompleter = Completer<TransactionSnapshot>();
    testFixture.client.commandHandlers.add((_) => commandCompleter.future);
    testFixture.client.transactionHandlers.add((_) => readCompleter.future);
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Complete Sale'));
    await tester.pump();
    expect(find.text('Completing sale...'), findsOneWidget);
    expect(find.text('Sale Complete'), findsNothing);

    final command = testFixture.client.commands.last;
    expect(command, isA<CompleteTransactionCommand>());
    expect(command.expectedVersion, 3);
    commandCompleter.complete(resultFor(command, version: 4));
    await tester.pump();
    expect(find.text('Loading latest transaction state...'), findsOneWidget);
    expect(find.text('Sale Complete'), findsNothing);

    readCompleter.complete(
      snapshot(
        version: 4,
        status: TransactionStatus.completed,
        total: 199,
        tenderedCash: 500,
        changeDue: 301,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Status: Completed'), findsOneWidget);
    expect(find.text('Sale Complete'), findsOneWidget);
    expect(find.text(r'$1.99'), findsWidgets);
    expect(find.text(r'$5.00'), findsOneWidget);
    expect(find.text(r'$3.01'), findsOneWidget);
    expect(find.text('Scan Item'), findsNothing);
    expect(find.text('Take Cash'), findsNothing);
    expect(find.text('Complete Sale'), findsNothing);
  });

  testWidgets('completion rejection refreshes without automatic completion', (
    tester,
  ) async {
    final testFixture = fixture();
    final paid = snapshot(
      version: 3,
      status: TransactionStatus.paid,
      total: 199,
      tenderedCash: 500,
      changeDue: 301,
    );
    await establishTransaction(testFixture, paid);
    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.domainRejected,
      code: 'invalid_transaction_state',
      version: 3,
    );
    testFixture.client.enqueueSnapshot(paid);
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Complete Sale'));
    await tester.pumpAndSettle();

    expect(
      find.text('That action is no longer valid. Latest state loaded.'),
      findsOneWidget,
    );
    expect(find.text('Complete Sale'), findsOneWidget);
    expect(testFixture.client.commands, hasLength(2));
  });

  testWidgets('uncertain completion uses generic exact-command recovery', (
    tester,
  ) async {
    final testFixture = fixture();
    await establishTransaction(
      testFixture,
      snapshot(
        version: 3,
        status: TransactionStatus.paid,
        total: 199,
        tenderedCash: 500,
        changeDue: 301,
      ),
    );
    testFixture.client.enqueueCommandFailure(
      const PosCoreTransportFailure('unknown', retrySameCommandId: true),
    );
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Complete Sale'));
    await tester.pumpAndSettle();
    final pending = testFixture.controller.state.pendingCommand!;

    expect(pending, isA<CompleteTransactionCommand>());
    expect(find.text('Command result unknown'), findsOneWidget);
    expect(find.text('Retry Command'), findsOneWidget);

    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.accepted,
      version: 4,
    );
    testFixture.client.enqueueSnapshot(
      snapshot(
        version: 4,
        status: TransactionStatus.completed,
        total: 199,
        tenderedCash: 500,
        changeDue: 301,
      ),
    );
    await tester.tap(find.text('Retry Command'));
    await tester.pumpAndSettle();

    expect(identical(testFixture.client.commands.last, pending), isTrue);
    expect(find.text('Sale Complete'), findsOneWidget);
  });

  testWidgets(
    'completion accepted with failed GET refreshes without new command',
    (tester) async {
      final testFixture = fixture();
      await establishTransaction(
        testFixture,
        snapshot(
          version: 3,
          status: TransactionStatus.paid,
          total: 199,
          tenderedCash: 500,
          changeDue: 301,
        ),
      );
      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.accepted,
        version: 4,
      );
      testFixture.client.enqueueReadFailure(
        const PosCoreTransportFailure('read unavailable'),
      );
      await pumpCashier(tester, testFixture.controller);

      await tester.tap(find.text('Complete Sale'));
      await tester.pumpAndSettle();
      expect(find.text('Refresh Transaction'), findsOneWidget);
      expect(find.text('Retry Command'), findsNothing);
      final posts = testFixture.client.commands.length;

      testFixture.client.enqueueSnapshot(
        snapshot(
          version: 4,
          status: TransactionStatus.completed,
          total: 199,
          tenderedCash: 500,
          changeDue: 301,
        ),
      );
      await tester.tap(find.text('Refresh Transaction'));
      await tester.pumpAndSettle();

      expect(testFixture.client.commands, hasLength(posts));
      expect(find.text('Sale Complete'), findsOneWidget);
    },
  );

  testWidgets('tender and completed controls remain overflow-safe', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final openFixture = fixture();
    await establishTransaction(openFixture, snapshot(version: 2, total: 199));

    await tester.binding.setSurfaceSize(const Size(1200, 700));
    await pumpCashier(tester, openFixture.controller);
    expect(tester.takeException(), isNull);
    expect(find.text('Take Cash'), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(420, 700));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final completedFixture = fixture();
    await establishTransaction(
      completedFixture,
      snapshot(
        status: TransactionStatus.completed,
        total: 199,
        tenderedCash: 500,
        changeDue: 301,
      ),
    );
    await pumpCashier(tester, completedFixture.controller);
    expect(tester.takeException(), isNull);
    expect(find.text('Sale Complete'), findsOneWidget);
  });

  testWidgets('restored pending command shows only same-command recovery', (
    tester,
  ) async {
    final store = MemoryCashierSessionStore(
      persisted: PersistedCashierSession(
        activeTransactionId: 'txn-1',
        pendingCommand: ScanBarcodeCommand(
          commandId: 'cmd-restored',
          transactionId: 'txn-1',
          expectedVersion: 4,
          barcode: 'restored-barcode',
        ),
      ),
    );
    final testFixture = fixture(
      commandIds: const [],
      transactionIds: const [],
      sessionStore: store,
    );
    await testFixture.controller.restoreLocalSession();

    await pumpCashier(tester, testFixture.controller);

    expect(find.text('Command result unknown'), findsOneWidget);
    expect(find.text('Retry Command'), findsOneWidget);
    expect(find.text('Start Sale'), findsNothing);
    expect(find.text('Refresh Transaction'), findsNothing);
    expect(barcodeField, findsNothing);
    expect(testFixture.client.commands, isEmpty);
    expect(testFixture.client.reads, isEmpty);
  });

  testWidgets('restored known active session offers GET-only refresh', (
    tester,
  ) async {
    final store = MemoryCashierSessionStore(
      persisted: PersistedCashierSession(activeTransactionId: 'txn-1'),
    );
    final testFixture = fixture(
      commandIds: const [],
      transactionIds: const [],
      sessionStore: store,
    );
    await testFixture.controller.restoreLocalSession();
    await pumpCashier(tester, testFixture.controller);

    expect(find.text('Transaction state unavailable'), findsOneWidget);
    expect(find.text('Refresh Transaction'), findsOneWidget);
    expect(find.text('Retry Command'), findsNothing);
    expect(find.text('Start Sale'), findsNothing);

    testFixture.client.enqueueSnapshot(snapshot(version: 8));
    await tester.tap(find.text('Refresh Transaction'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(barcodeField).focusNode!.hasFocus, isTrue);
  });

  testWidgets('corrupt recovery state blocks register with safe guidance', (
    tester,
  ) async {
    final store = MemoryCashierSessionStore()
      ..loadFailure = const CashierSessionStoreFailure.corruptData();
    final testFixture = fixture(sessionStore: store);
    await testFixture.controller.restoreLocalSession();

    await pumpCashier(tester, testFixture.controller);

    expect(find.text('Register recovery required'), findsOneWidget);
    expect(find.textContaining('could not be read safely'), findsOneWidget);
    expect(find.text('Start Sale'), findsNothing);
    expect(find.text('Retry Command'), findsNothing);
    expect(testFixture.client.commands, isEmpty);
  });

  testWidgets('pre-send storage failure never claims command uncertainty', (
    tester,
  ) async {
    final store = MemoryCashierSessionStore()
      ..nextSaveFailure = const CashierSessionStoreFailure.storageUnavailable();
    final testFixture = fixture(sessionStore: store);
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Start Sale'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Local recovery storage unavailable. The command was not sent.',
      ),
      findsOneWidget,
    );
    expect(find.text('Command result unknown'), findsNothing);
    expect(find.text('Retry Command'), findsNothing);
    expect(find.text('Start Sale'), findsOneWidget);
    expect(testFixture.client.commands, isEmpty);
  });

  testWidgets('pre-send scan storage failure retains the unsent barcode', (
    tester,
  ) async {
    final store = MemoryCashierSessionStore();
    final testFixture = fixture(
      commandIds: const ['cmd-start', 'cmd-unsent-scan'],
      sessionStore: store,
    );
    await establishTransaction(testFixture, snapshot(version: 3));
    store.nextSaveFailure =
        const CashierSessionStoreFailure.storageUnavailable();
    await pumpCashier(tester, testFixture.controller);

    await tester.enterText(barcodeField, 'unsent-code');
    await tester.tap(find.text('Scan Item'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Local recovery storage unavailable. The command was not sent.',
      ),
      findsOneWidget,
    );
    expect(testFixture.client.commands, hasLength(1));
    expect(
      tester.widget<TextField>(barcodeField).controller!.text,
      'unsent-code',
    );
    expect(tester.widget<TextField>(barcodeField).focusNode!.hasFocus, isTrue);
  });

  testWidgets('completed sale exposes explicit Next Sale controller path', (
    tester,
  ) async {
    final testFixture = fixture(
      commandIds: const ['cmd-old', 'cmd-next'],
      transactionIds: const ['txn-1', 'txn-next'],
    );
    await establishTransaction(
      testFixture,
      snapshot(
        status: TransactionStatus.completed,
        total: 199,
        tenderedCash: 500,
        changeDue: 301,
      ),
    );
    testFixture.client.enqueueResult(PosCommandOutcomeKind.accepted);
    testFixture.client.enqueueSnapshot(
      TransactionSnapshot(
        transactionId: 'txn-next',
        version: 1,
        status: TransactionStatus.open,
        lineItems: const [],
        subtotalMinorUnits: 0,
        taxMinorUnits: 0,
        totalMinorUnits: 0,
        tenderedCashMinorUnits: null,
        changeDueMinorUnits: null,
      ),
    );
    await pumpCashier(tester, testFixture.controller);

    expect(find.text('Next Sale'), findsOneWidget);
    await tester.tap(find.text('Next Sale'));
    await tester.pumpAndSettle();

    final next = testFixture.client.commands.last as StartTransactionCommand;
    expect(next.commandId, 'cmd-next');
    expect(next.transactionId, 'txn-next');
    expect(next.expectedVersion, 0);
    expect(find.text('Status: Open'), findsOneWidget);
    expect(tester.widget<TextField>(barcodeField).focusNode!.hasFocus, isTrue);
  });

  testWidgets('Next Sale storage failure preserves completed presentation', (
    tester,
  ) async {
    final store = MemoryCashierSessionStore();
    final testFixture = fixture(sessionStore: store);
    await establishTransaction(
      testFixture,
      snapshot(
        status: TransactionStatus.completed,
        total: 199,
        tenderedCash: 500,
        changeDue: 301,
      ),
    );
    store.nextClearFailure =
        const CashierSessionStoreFailure.storageUnavailable();
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Next Sale'));
    await tester.pumpAndSettle();

    expect(find.text('Sale Complete'), findsOneWidget);
    expect(find.text('Next Sale'), findsOneWidget);
    expect(find.text('Local recovery storage unavailable.'), findsOneWidget);
    expect(testFixture.client.commands, hasLength(1));
  });

  testWidgets(
    'open sale uses scanner-safe text behavior and focus-only shortcuts',
    (tester) async {
      final testFixture = fixture(commandIds: const ['cmd-start']);
      await establishTransaction(testFixture, snapshot(version: 4));
      await pumpCashier(tester, testFixture.controller);

      final barcode = tester.widget<TextField>(barcodeField);
      expect(barcode.autocorrect, isFalse);
      expect(barcode.enableSuggestions, isFalse);
      expect(barcode.smartDashesType, SmartDashesType.disabled);
      expect(barcode.smartQuotesType, SmartQuotesType.disabled);
      expect(barcode.focusNode!.hasFocus, isTrue);

      await tester.tap(cashField);
      await tester.pump();
      expect(tester.widget<TextField>(cashField).focusNode!.hasFocus, isTrue);
      expect(
        tester.widget<TextField>(barcodeField).focusNode!.hasFocus,
        isFalse,
      );

      final commandsBeforeShortcuts = testFixture.client.commands.length;
      final commandIdsBeforeShortcuts = testFixture.ids.commandIdCalls;
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(
        tester.widget<TextField>(barcodeField).focusNode!.hasFocus,
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.pump();
      expect(tester.widget<TextField>(cashField).focusNode!.hasFocus, isTrue);
      expect(testFixture.client.commands, hasLength(commandsBeforeShortcuts));
      expect(testFixture.ids.commandIdCalls, commandIdsBeforeShortcuts);
    },
  );

  testWidgets('busy input and focus shortcuts cannot enqueue another scan', (
    tester,
  ) async {
    final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-scan']);
    await establishTransaction(testFixture, snapshot(version: 1));
    final commandCompleter = Completer<PosCommandResult>();
    testFixture.client.commandHandlers.add((_) => commandCompleter.future);
    await pumpCashier(tester, testFixture.controller);

    await tester.enterText(barcodeField, 'only-scan');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Processing item...'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pump();
    expect(testFixture.client.commands, hasLength(2));
    expect(testFixture.ids.commandIdCalls, 2);

    final command = testFixture.client.commands.last;
    testFixture.client.enqueueSnapshot(snapshot(version: 2));
    commandCompleter.complete(resultFor(command, version: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('three scans remain sequential and follow authoritative order', (
    tester,
  ) async {
    final testFixture = fixture(
      commandIds: const ['cmd-start', 'cmd-a', 'cmd-b', 'cmd-c'],
    );
    await establishTransaction(testFixture, snapshot(version: 1));
    await pumpCashier(tester, testFixture.controller);

    for (var index = 0; index < 3; index += 1) {
      final lines = List<TransactionLineItem>.generate(
        index + 1,
        (lineIndex) => TransactionLineItem(
          barcode: 'code-$lineIndex',
          description: 'Item $lineIndex',
          unitPriceMinorUnits: 100 + lineIndex,
        ),
      );
      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.accepted,
        version: index + 2,
      );
      testFixture.client.enqueueSnapshot(
        snapshot(
          version: index + 2,
          lineItems: lines,
          subtotal: 900 + index,
          total: 1000 + index,
        ),
      );

      await tester.enterText(barcodeField, 'code-$index');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(barcodeField).controller!.text, isEmpty);
      expect(
        tester.widget<TextField>(barcodeField).focusNode!.hasFocus,
        isTrue,
      );
      expect(find.text('Item $index'), findsOneWidget);
    }

    final scans = testFixture.client.commands.whereType<ScanBarcodeCommand>();
    expect(scans.map((command) => command.commandId), [
      'cmd-a',
      'cmd-b',
      'cmd-c',
    ]);
    expect(scans.map((command) => command.barcode), [
      'code-0',
      'code-1',
      'code-2',
    ]);
    expect(
      tester.getTopLeft(find.text('Item 0')).dy,
      lessThan(tester.getTopLeft(find.text('Item 1')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Item 1')).dy,
      lessThan(tester.getTopLeft(find.text('Item 2')).dy),
    );
  });

  testWidgets(
    'restored pending scan retry restores correction text and barcode focus',
    (tester) async {
      final restored = ScanBarcodeCommand(
        commandId: 'cmd-restored',
        transactionId: 'txn-1',
        expectedVersion: 4,
        barcode: 'restored-code',
      );
      final store = MemoryCashierSessionStore(
        persisted: PersistedCashierSession(
          activeTransactionId: 'txn-1',
          pendingCommand: restored,
        ),
      );
      final testFixture = fixture(
        commandIds: const [],
        transactionIds: const [],
        sessionStore: store,
      );
      await testFixture.controller.restoreLocalSession();
      testFixture.client.enqueueResult(
        PosCommandOutcomeKind.domainRejected,
        code: 'unknown_barcode',
        version: 4,
      );
      testFixture.client.enqueueSnapshot(snapshot(version: 4));
      await pumpCashier(tester, testFixture.controller);

      await tester.tap(find.text('Retry Command'));
      await tester.pumpAndSettle();

      expect(testFixture.client.commands.single, same(restored));
      expect(
        tester.widget<TextField>(barcodeField).controller!.text,
        'restored-code',
      );
      expect(
        tester.widget<TextField>(barcodeField).focusNode!.hasFocus,
        isTrue,
      );
      expect(
        tester.widget<TextField>(barcodeField).controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 13),
      );
    },
  );

  testWidgets('restored pending tender retry restores cash correction focus', (
    tester,
  ) async {
    final restored = TenderCashCommand(
      commandId: 'cmd-restored-tender',
      transactionId: 'txn-1',
      expectedVersion: 4,
      amountMinorUnits: 500,
    );
    final store = MemoryCashierSessionStore(
      persisted: PersistedCashierSession(
        activeTransactionId: 'txn-1',
        pendingCommand: restored,
      ),
    );
    final testFixture = fixture(
      commandIds: const [],
      transactionIds: const [],
      sessionStore: store,
    );
    await testFixture.controller.restoreLocalSession();
    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.domainRejected,
      code: 'insufficient_tender',
      version: 4,
    );
    testFixture.client.enqueueSnapshot(snapshot(version: 4, total: 900));
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Retry Command'));
    await tester.pumpAndSettle();

    expect(testFixture.client.commands.single, same(restored));
    expect(tester.widget<TextField>(cashField).controller!.text, '5.00');
    expect(tester.widget<TextField>(cashField).focusNode!.hasFocus, isTrue);
    expect(tester.widget<TextField>(barcodeField).focusNode!.hasFocus, isFalse);
  });

  testWidgets('restored accepted tender never refocuses open-sale inputs', (
    tester,
  ) async {
    final restored = TenderCashCommand(
      commandId: 'cmd-restored-tender',
      transactionId: 'txn-1',
      expectedVersion: 4,
      amountMinorUnits: 500,
    );
    final store = MemoryCashierSessionStore(
      persisted: PersistedCashierSession(
        activeTransactionId: 'txn-1',
        pendingCommand: restored,
      ),
    );
    final testFixture = fixture(
      commandIds: const [],
      transactionIds: const [],
      sessionStore: store,
    );
    await testFixture.controller.restoreLocalSession();
    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.accepted,
      version: 5,
    );
    testFixture.client.enqueueSnapshot(
      snapshot(
        version: 5,
        status: TransactionStatus.paid,
        total: 199,
        tenderedCash: 500,
        changeDue: 301,
      ),
    );
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Retry Command'));
    await tester.pumpAndSettle();

    expect(testFixture.client.commands.single, same(restored));
    expect(find.text('Payment accepted'), findsOneWidget);
    expect(barcodeField, findsNothing);
    expect(cashField, findsNothing);
  });

  testWidgets('primary cashier actions have POS-sized touch targets', (
    tester,
  ) async {
    void expectPrimaryAction(String label) {
      final button = find.widgetWithText(FilledButton, label);
      expect(button, findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(52));
    }

    final initialFixture = fixture();
    await pumpCashier(tester, initialFixture.controller);
    expectPrimaryAction('Start Sale');

    final openFixture = fixture();
    await establishTransaction(
      openFixture,
      snapshot(
        lineItems: const [
          TransactionLineItem(
            barcode: 'A',
            description: 'Apples',
            unitPriceMinorUnits: 100,
          ),
        ],
        subtotal: 100,
        total: 100,
      ),
    );
    await pumpCashier(tester, openFixture.controller);
    expectPrimaryAction('Scan Item');
    expectPrimaryAction('Take Cash');
    expect(
      tester.getSize(find.byKey(const Key('cashier-remove-line-0'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.byKey(const Key('cashier-void-sale'))).height,
      greaterThanOrEqualTo(52),
    );

    final paidFixture = fixture();
    await establishTransaction(
      paidFixture,
      snapshot(
        status: TransactionStatus.paid,
        tenderedCash: 500,
        changeDue: 301,
      ),
    );
    await pumpCashier(tester, paidFixture.controller);
    expectPrimaryAction('Complete Sale');

    final completedFixture = fixture();
    await establishTransaction(
      completedFixture,
      snapshot(
        status: TransactionStatus.completed,
        tenderedCash: 500,
        changeDue: 301,
      ),
    );
    await pumpCashier(tester, completedFixture.controller);
    expectPrimaryAction('Next Sale');

    final pendingStore = MemoryCashierSessionStore(
      persisted: PersistedCashierSession(
        activeTransactionId: 'txn-1',
        pendingCommand: CompleteTransactionCommand(
          commandId: 'cmd-pending',
          transactionId: 'txn-1',
          expectedVersion: 3,
        ),
      ),
    );
    final pendingFixture = fixture(
      commandIds: const [],
      transactionIds: const [],
      sessionStore: pendingStore,
    );
    await pendingFixture.controller.restoreLocalSession();
    await pumpCashier(tester, pendingFixture.controller);
    expectPrimaryAction('Retry Command');

    final refreshStore = MemoryCashierSessionStore(
      persisted: PersistedCashierSession(activeTransactionId: 'txn-1'),
    );
    final refreshFixture = fixture(
      commandIds: const [],
      transactionIds: const [],
      sessionStore: refreshStore,
    );
    await refreshFixture.controller.restoreLocalSession();
    await pumpCashier(tester, refreshFixture.controller);
    expectPrimaryAction('Refresh Transaction');
  });

  testWidgets('status, money, recovery, and feedback expose useful semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final paidFixture = fixture();
    await establishTransaction(
      paidFixture,
      snapshot(
        status: TransactionStatus.paid,
        total: 199,
        tenderedCash: 500,
        changeDue: 777,
      ),
    );
    await pumpCashier(tester, paidFixture.controller);

    expect(find.bySemanticsLabel('Transaction status: Paid'), findsOneWidget);
    expect(find.bySemanticsLabel(r'Total: $1.99'), findsWidgets);
    expect(find.bySemanticsLabel(r'Cash received: $5.00'), findsOneWidget);
    expect(find.bySemanticsLabel(r'Change due: $7.77'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Transaction version')), findsNothing);

    final recoveryStore = MemoryCashierSessionStore(
      persisted: PersistedCashierSession(
        activeTransactionId: 'txn-1',
        pendingCommand: CompleteTransactionCommand(
          commandId: 'cmd-pending',
          transactionId: 'txn-1',
          expectedVersion: 3,
        ),
      ),
    );
    final recoveryFixture = fixture(
      commandIds: const [],
      transactionIds: const [],
      sessionStore: recoveryStore,
    );
    await recoveryFixture.controller.restoreLocalSession();
    await pumpCashier(tester, recoveryFixture.controller);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Command result unknown')),
      matchesSemantics(label: 'Command result unknown', isHeader: true),
    );

    final rejectedFixture = fixture();
    final authoritative = snapshot(version: 3);
    await establishTransaction(rejectedFixture, authoritative);
    rejectedFixture.client.enqueueResult(
      PosCommandOutcomeKind.domainRejected,
      code: 'unknown_barcode',
      version: 3,
    );
    rejectedFixture.client.enqueueSnapshot(authoritative);
    await pumpCashier(tester, rejectedFixture.controller);
    await tester.enterText(barcodeField, 'unknown');
    await tester.tap(find.text('Scan Item'));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsLabel('Item not found.')),
      matchesSemantics(label: 'Item not found.', isLiveRegion: true),
    );
    semantics.dispose();
  });

  testWidgets('authoritative Change due is the strongest payment value', (
    tester,
  ) async {
    final testFixture = fixture();
    await establishTransaction(
      testFixture,
      snapshot(
        status: TransactionStatus.paid,
        total: 199,
        tenderedCash: 500,
        changeDue: 777,
      ),
    );
    await pumpCashier(tester, testFixture.controller);

    final changeText = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('cashier-change-due')),
        matching: find.text(r'$7.77'),
      ),
    );
    final cashText = tester.widget<Text>(find.text(r'$5.00'));
    expect(changeText.style!.fontSize, greaterThan(cashText.style!.fontSize!));
    expect(changeText.style!.fontWeight, FontWeight.bold);
  });

  for (final testCase in <(TransactionStatus, String)>[
    (TransactionStatus.open, 'Scan Item'),
    (TransactionStatus.paid, 'Complete Sale'),
    (TransactionStatus.completed, 'Next Sale'),
    (TransactionStatus.voided, 'Next Sale'),
  ]) {
    testWidgets('${testCase.$1.name} cashier remains usable at 2x text scale', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      final testFixture = fixture();
      final hasPayment =
          testCase.$1 == TransactionStatus.paid ||
          testCase.$1 == TransactionStatus.completed;
      await establishTransaction(
        testFixture,
        snapshot(
          status: testCase.$1,
          total: 12345,
          tenderedCash: hasPayment ? 20000 : null,
          changeDue: hasPayment ? 7655 : null,
        ),
      );

      await pumpCashier(
        tester,
        testFixture.controller,
        textScaler: const TextScaler.linear(2),
      );

      expect(tester.takeException(), isNull);
      expect(find.text(testCase.$2), findsOneWidget);
    });
  }

  testWidgets('correction controls are offered only for open transactions', (
    tester,
  ) async {
    const line = TransactionLineItem(
      barcode: 'A',
      description: 'Apples',
      unitPriceMinorUnits: 100,
    );
    for (final status in [
      TransactionStatus.paid,
      TransactionStatus.completed,
      TransactionStatus.voided,
    ]) {
      final testFixture = fixture();
      final hasPayment = status != TransactionStatus.voided;
      await establishTransaction(
        testFixture,
        snapshot(
          status: status,
          lineItems: const [line],
          subtotal: 100,
          total: 100,
          tenderedCash: hasPayment ? 100 : null,
          changeDue: hasPayment ? 0 : null,
        ),
      );
      await pumpCashier(tester, testFixture.controller);

      expect(find.text('Remove'), findsNothing);
      expect(find.text('Void Sale'), findsNothing);
    }
  });

  testWidgets('recovery screen remains usable at 2x text scale', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(600, 800));
    final store = MemoryCashierSessionStore()
      ..loadFailure = const CashierSessionStoreFailure.corruptData();
    final testFixture = fixture(sessionStore: store);
    await testFixture.controller.restoreLocalSession();

    await pumpCashier(
      tester,
      testFixture.controller,
      textScaler: const TextScaler.linear(2),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Register recovery required'), findsOneWidget);
    expect(find.text('Start Sale'), findsNothing);
  });

  testWidgets('focus shortcuts are inert outside an open idle sale', (
    tester,
  ) async {
    final completedFixture = fixture();
    await establishTransaction(
      completedFixture,
      snapshot(
        status: TransactionStatus.completed,
        tenderedCash: 500,
        changeDue: 0,
      ),
    );
    await pumpCashier(tester, completedFixture.controller);
    final completedCommandCalls = completedFixture.ids.commandIdCalls;

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pump();

    expect(completedFixture.ids.commandIdCalls, completedCommandCalls);
    expect(completedFixture.client.commands, hasLength(1));
    expect(barcodeField, findsNothing);
    expect(cashField, findsNothing);

    final blockedStore = MemoryCashierSessionStore()
      ..loadFailure = const CashierSessionStoreFailure.corruptData();
    final blockedFixture = fixture(sessionStore: blockedStore);
    await blockedFixture.controller.restoreLocalSession();
    await pumpCashier(tester, blockedFixture.controller);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pump();
    expect(blockedFixture.ids.commandIdCalls, 0);
    expect(blockedFixture.client.commands, isEmpty);
  });

  testWidgets(
    'long authoritative basket scrolls without hiding totals or controls',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      final testFixture = fixture();
      await establishTransaction(
        testFixture,
        snapshot(
          lineItems: List<TransactionLineItem>.generate(
            40,
            (index) => TransactionLineItem(
              barcode: 'code-$index',
              description: 'Long basket item $index',
              unitPriceMinorUnits: 100 + index,
            ),
          ),
          subtotal: 12345,
          total: 12345,
        ),
      );
      await pumpCashier(tester, testFixture.controller);

      expect(find.text('Long basket item 0'), findsOneWidget);
      expect(find.text('Scan Item'), findsOneWidget);
      expect(find.text(r'$123.45'), findsWidgets);
      await tester.fling(
        find.byType(ListView).first,
        const Offset(0, -2400),
        3000,
      );
      await tester.pumpAndSettle();

      expect(find.text('Long basket item 39'), findsOneWidget);
      expect(find.text('Scan Item'), findsOneWidget);
      expect(find.text(r'$123.45'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remove confirmation is explicit and waits for authoritative GET',
    (tester) async {
      final testFixture = fixture(
        commandIds: const ['cmd-start', 'cmd-remove'],
      );
      const lines = [
        TransactionLineItem(
          barcode: 'A',
          description: 'Apples',
          unitPriceMinorUnits: 100,
        ),
        TransactionLineItem(
          barcode: 'B',
          description: 'Bananas',
          unitPriceMinorUnits: 200,
        ),
        TransactionLineItem(
          barcode: 'C',
          description: 'Cherries',
          unitPriceMinorUnits: 300,
        ),
      ];
      await establishTransaction(
        testFixture,
        snapshot(
          version: 4,
          lineItems: lines,
          subtotal: 600,
          tax: 60,
          total: 660,
        ),
      );
      await pumpCashier(tester, testFixture.controller);

      expect(find.text('Remove'), findsNWidgets(3));
      expect(find.text('Void Sale'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cashier-remove-line-1')));
      await tester.pumpAndSettle();
      expect(find.text('Remove item?'), findsOneWidget);
      expect(find.text('Bananas'), findsNWidgets(2));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(testFixture.client.commands, hasLength(1));
      expect(testFixture.ids.commandIdCalls, 1);

      final commandCompleter = Completer<PosCommandResult>();
      final readCompleter = Completer<TransactionSnapshot>();
      testFixture.client.commandHandlers.add((_) => commandCompleter.future);
      testFixture.client.transactionHandlers.add((_) => readCompleter.future);
      await tester.tap(find.byKey(const Key('cashier-remove-line-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove Item'));
      await tester.pump();

      final command = testFixture.client.commands.last as RemoveLineItemCommand;
      expect(command.lineIndex, 1);
      expect(command.expectedVersion, 4);
      // The closing dialog may still paint its item label for one route frame,
      // but the old authoritative basket is already withheld.
      expect(find.text('Basket'), findsNothing);
      expect(find.text('Sale Voided'), findsNothing);

      commandCompleter.complete(resultFor(command, version: 5));
      await tester.pump();
      expect(find.text('Loading latest transaction state...'), findsOneWidget);
      expect(find.text('Basket'), findsNothing);

      readCompleter.complete(
        snapshot(
          version: 5,
          lineItems: [lines[0], lines[2]],
          subtotal: 400,
          tax: 40,
          total: 440,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bananas'), findsNothing);
      expect(find.text('Apples'), findsOneWidget);
      expect(find.text('Cherries'), findsOneWidget);
      expect(find.text(r'$4.00'), findsOneWidget);
      expect(find.text(r'$0.40'), findsOneWidget);
      expect(find.text(r'$4.40'), findsOneWidget);
      expect(
        tester.widget<TextField>(barcodeField).focusNode!.hasFocus,
        isTrue,
      );
    },
  );

  testWidgets('stale removal dialog cannot submit against a newer snapshot', (
    tester,
  ) async {
    final testFixture = fixture(commandIds: const ['cmd-start']);
    const line = TransactionLineItem(
      barcode: 'A',
      description: 'Apples',
      unitPriceMinorUnits: 100,
    );
    await establishTransaction(
      testFixture,
      snapshot(version: 2, lineItems: const [line], subtotal: 100, total: 100),
    );
    await pumpCashier(tester, testFixture.controller);
    await tester.tap(find.byKey(const Key('cashier-remove-line-0')));
    await tester.pumpAndSettle();

    testFixture.client.enqueueSnapshot(
      snapshot(version: 3, lineItems: const [line], subtotal: 100, total: 100),
    );
    await testFixture.controller.refreshTransaction();
    await tester.pump();
    await tester.tap(find.text('Remove Item'));
    await tester.pumpAndSettle();

    expect(testFixture.client.commands, hasLength(1));
    expect(testFixture.ids.commandIdCalls, 1);
    expect(
      find.text('Transaction changed. Select the item again.'),
      findsOneWidget,
    );
  });

  testWidgets('void is authoritative, terminal, and Next Sale starts cleanly', (
    tester,
  ) async {
    final testFixture = fixture(
      commandIds: const ['cmd-start', 'cmd-void', 'cmd-next'],
      transactionIds: const ['txn-1', 'txn-2'],
    );
    const line = TransactionLineItem(
      barcode: 'A',
      description: 'Apples',
      unitPriceMinorUnits: 199,
    );
    await establishTransaction(
      testFixture,
      snapshot(
        version: 2,
        lineItems: const [line],
        subtotal: 199,
        tax: 20,
        total: 219,
      ),
    );
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Void Sale'));
    await tester.pumpAndSettle();
    expect(find.text('Void this sale?'), findsOneWidget);
    await tester.tap(find.text('Keep Sale'));
    await tester.pumpAndSettle();
    expect(testFixture.client.commands, hasLength(1));

    final commandCompleter = Completer<PosCommandResult>();
    final readCompleter = Completer<TransactionSnapshot>();
    testFixture.client.commandHandlers.add((_) => commandCompleter.future);
    testFixture.client.transactionHandlers.add((_) => readCompleter.future);
    await tester.tap(find.text('Void Sale'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Void Sale'));
    await tester.pump();
    expect(find.text('Sale Voided'), findsNothing);
    expect(find.text('Voiding sale...'), findsOneWidget);

    final command = testFixture.client.commands.last as VoidTransactionCommand;
    expect(command.expectedVersion, 2);
    commandCompleter.complete(resultFor(command, version: 3));
    await tester.pump();
    expect(find.text('Loading latest transaction state...'), findsOneWidget);
    expect(find.text('Sale Voided'), findsNothing);

    readCompleter.complete(
      snapshot(
        version: 3,
        status: TransactionStatus.voided,
        lineItems: const [line],
        subtotal: 199,
        tax: 20,
        total: 219,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sale Voided'), findsOneWidget);
    expect(find.text('Status: Voided'), findsOneWidget);
    expect(find.text('Apples'), findsOneWidget);
    expect(find.text(r'$1.99'), findsWidgets);
    expect(find.text(r'$0.20'), findsWidgets);
    expect(find.text(r'$2.19'), findsWidgets);
    expect(find.text('Next Sale'), findsOneWidget);
    expect(find.text('Scan Item'), findsNothing);
    expect(find.text('Take Cash'), findsNothing);
    expect(find.text('Remove'), findsNothing);
    expect(find.text('Complete Sale'), findsNothing);
    expect(find.text('Void Sale'), findsNothing);

    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.accepted,
      version: 1,
    );
    testFixture.client.enqueueSnapshot(
      snapshot(transactionId: 'txn-2', version: 1),
    );
    await tester.tap(find.text('Next Sale'));
    await tester.pumpAndSettle();
    expect(find.text('No items scanned yet.'), findsOneWidget);
    expect(tester.widget<TextField>(barcodeField).focusNode!.hasFocus, isTrue);
  });

  testWidgets(
    'restored pending corrections expose only same-command recovery',
    (tester) async {
      final commands = <TransactionCommand>[
        RemoveLineItemCommand(
          commandId: 'cmd-pending-remove',
          transactionId: 'txn-1',
          expectedVersion: 4,
          lineIndex: 1,
        ),
        VoidTransactionCommand(
          commandId: 'cmd-pending-void',
          transactionId: 'txn-1',
          expectedVersion: 4,
        ),
      ];
      for (final command in commands) {
        final store = MemoryCashierSessionStore(
          persisted: PersistedCashierSession(
            activeTransactionId: 'txn-1',
            pendingCommand: command,
          ),
        );
        final testFixture = fixture(
          commandIds: const [],
          transactionIds: const [],
          sessionStore: store,
        );
        await testFixture.controller.restoreLocalSession();
        await pumpCashier(tester, testFixture.controller);

        expect(find.text('Command result unknown'), findsOneWidget);
        expect(find.text('Retry Command'), findsOneWidget);
        expect(find.text('Start Sale'), findsNothing);
        expect(find.text('Remove'), findsNothing);
        expect(find.text('Void Sale'), findsNothing);
        expect(testFixture.client.commands, isEmpty);
      }
    },
  );

  testWidgets('line-item rejection refreshes without automatic re-removal', (
    tester,
  ) async {
    final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-remove']);
    const line = TransactionLineItem(
      barcode: 'A',
      description: 'Apples',
      unitPriceMinorUnits: 199,
    );
    final refreshed = snapshot(
      version: 2,
      lineItems: const [line],
      subtotal: 199,
      total: 199,
    );
    await establishTransaction(testFixture, refreshed);
    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.domainRejected,
      code: 'line_item_not_found',
      version: 2,
    );
    testFixture.client.enqueueSnapshot(refreshed);
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.byKey(const Key('cashier-remove-line-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove Item'));
    await tester.pumpAndSettle();

    expect(
      find.text('Item could not be removed. Latest transaction state loaded.'),
      findsOneWidget,
    );
    expect(find.text('Apples'), findsOneWidget);
    expect(testFixture.client.commands, hasLength(2));
    expect(testFixture.ids.commandIdCalls, 2);
    expect(tester.widget<TextField>(barcodeField).focusNode!.hasFocus, isTrue);
  });

  testWidgets('known correction with failed GET offers refresh, not retry', (
    tester,
  ) async {
    final testFixture = fixture(commandIds: const ['cmd-start', 'cmd-void']);
    await establishTransaction(testFixture, snapshot(version: 1));
    testFixture.client.enqueueResult(
      PosCommandOutcomeKind.accepted,
      version: 2,
    );
    testFixture.client.enqueueReadFailure(
      const PosCoreTransportFailure('read failed'),
    );
    await pumpCashier(tester, testFixture.controller);

    await tester.tap(find.text('Void Sale'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Void Sale'));
    await tester.pumpAndSettle();

    expect(find.text('Refresh Transaction'), findsOneWidget);
    expect(find.text('Retry Command'), findsNothing);
    expect(find.text('Sale Voided'), findsNothing);
    expect(testFixture.client.commands, hasLength(2));
  });

  testWidgets('completed sale loads View Receipt through receipt query', (
    tester,
  ) async {
    final store = MemoryCashierSessionStore();
    final testFixture = fixture(
      commandIds: const ['cmd-start'],
      sessionStore: store,
    );
    await establishTransaction(
      testFixture,
      snapshot(
        status: TransactionStatus.completed,
        version: 6,
        lineItems: const [
          TransactionLineItem(
            barcode: 'snapshot-barcode',
            description: 'Snapshot Basket Item',
            unitPriceMinorUnits: 1,
          ),
        ],
        subtotal: 1,
        tax: 2,
        total: 3,
        tenderedCash: 4,
        changeDue: 5,
      ),
    );
    final persistedBefore = store.persisted;
    testFixture.client.receiptHandlers.add(
      (transactionId) async => canonicalReceipt(transactionId: transactionId),
    );
    await pumpCashier(
      tester,
      testFixture.controller,
      receiptClient: testFixture.client,
    );

    expect(find.text('View Receipt'), findsOneWidget);
    await tester.ensureVisible(find.text('View Receipt'));
    await tester.tap(find.text('View Receipt'));
    await tester.pumpAndSettle();

    expect(testFixture.client.receiptReads, ['txn-1']);
    expect(testFixture.client.commands, hasLength(1));
    expect(testFixture.ids.commandIdCalls, 1);
    expect(testFixture.ids.transactionIdCalls, 1);
    expect(
      testFixture.controller.state.snapshot!.status,
      TransactionStatus.completed,
    );
    expect(find.text('Receipt-only Apples'), findsOneWidget);
    expect(find.text('Snapshot Basket Item'), findsNothing);
    expect(find.text(r'Subtotal $3.21'), findsOneWidget);
    expect(find.text(r'Total $3.53'), findsOneWidget);
    expect(
      store.persisted!.activeTransactionId,
      persistedBefore!.activeTransactionId,
    );
    expect(store.persisted!.pendingCommand, persistedBefore.pendingCommand);
  });

  testWidgets('receipt query failure leaves completed cashier state intact', (
    tester,
  ) async {
    final testFixture = fixture(commandIds: const ['cmd-start']);
    await establishTransaction(
      testFixture,
      snapshot(
        status: TransactionStatus.completed,
        version: 4,
        tenderedCash: 500,
        changeDue: 500,
      ),
    );
    testFixture.client.receiptHandlers.add(
      (_) async => throw const PosCoreTransportFailure('offline'),
    );
    await pumpCashier(
      tester,
      testFixture.controller,
      receiptClient: testFixture.client,
    );

    await tester.ensureVisible(find.text('View Receipt'));
    await tester.tap(find.text('View Receipt'));
    await tester.pumpAndSettle();
    expect(
      find.text('Unable to load the completed sale receipt.'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Sale Complete'), findsOneWidget);
    expect(find.text('Next Sale'), findsOneWidget);
    expect(
      testFixture.controller.state.snapshot!.status,
      TransactionStatus.completed,
    );
    expect(testFixture.client.commands, hasLength(1));
  });

  testWidgets('voided sale does not offer a completed-sale receipt', (
    tester,
  ) async {
    final testFixture = fixture(commandIds: const ['cmd-start']);
    await establishTransaction(
      testFixture,
      snapshot(status: TransactionStatus.voided, version: 2),
    );
    await pumpCashier(
      tester,
      testFixture.controller,
      receiptClient: testFixture.client,
    );

    expect(find.text('Sale Voided'), findsOneWidget);
    expect(find.text('View Receipt'), findsNothing);
    expect(testFixture.client.receiptReads, isEmpty);
  });
}
