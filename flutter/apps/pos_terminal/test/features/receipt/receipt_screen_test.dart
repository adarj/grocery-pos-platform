import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/canonical_receipt.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_health.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_readiness.dart';
import 'package:pos_terminal/core/pos_core/models/register_operations.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';
import 'package:pos_terminal/core/pos_core/pos_core_client.dart';
import 'package:pos_terminal/features/receipt/canonical_receipt_view.dart';
import 'package:pos_terminal/features/receipt/receipt_lookup_screen.dart';
import 'package:pos_terminal/features/receipt/receipt_screen.dart';

import '../../support/unimplemented_register_operations_client.dart';

typedef ReceiptHandler =
    Future<CanonicalReceipt> Function(String transactionId);

final class FakeReceiptClient
    with UnimplementedRegisterOperationsClient
    implements PosCoreClient {
  final Queue<ReceiptHandler> receiptHandlers = Queue();
  final List<String> receiptReads = [];
  int commandCalls = 0;
  int transactionReads = 0;

  @override
  Future<CanonicalReceipt> fetchReceipt(String transactionId) {
    receiptReads.add(transactionId);
    if (receiptHandlers.isEmpty) {
      throw StateError('No receipt response queued.');
    }
    return receiptHandlers.removeFirst()(transactionId);
  }

  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) {
    commandCalls += 1;
    throw UnimplementedError();
  }

  @override
  Future<PosCoreHealth> fetchHealth() => throw UnimplementedError();

  @override
  Future<PosCoreReadiness> fetchReadiness() => throw UnimplementedError();

  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) {
    transactionReads += 1;
    throw UnimplementedError();
  }
}

CanonicalReceipt receipt({
  String transactionId = 'txn-receipt',
  String? category = 'development-standard',
  int? rate = 100000,
  int lineTax = 20,
  int subtotal = 199,
  int tax = 777,
  int total = 1234,
  int cash = 2000,
  int change = 999,
}) {
  return CanonicalReceipt(
    schemaVersion: 1,
    transactionId: transactionId,
    transactionVersion: 6,
    lineItems: [
      CanonicalReceiptLine(
        barcode: '049000001234',
        description: 'Test Apples',
        unitPriceMinorUnits: 199,
        taxCategoryId: category,
        taxRateMillionths: rate,
        taxAmountMinorUnits: lineTax,
      ),
    ],
    subtotalMinorUnits: subtotal,
    taxMinorUnits: tax,
    totalMinorUnits: total,
    tenderedCashMinorUnits: cash,
    changeDueMinorUnits: change,
  );
}

void main() {
  testWidgets('receipt view renders authoritative fields independently', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CanonicalReceiptView(receipt: receipt())),
      ),
    );

    expect(find.text('Receipt'), findsOneWidget);
    expect(find.text('Transaction: txn-receipt'), findsOneWidget);
    expect(find.text('Test Apples'), findsOneWidget);
    expect(find.text('049000001234'), findsOneWidget);
    expect(find.text(r'$1.99'), findsOneWidget);
    expect(find.text(r'Subtotal $1.99'), findsOneWidget);
    expect(find.text(r'Tax $7.77'), findsOneWidget);
    expect(find.text(r'Total $12.34'), findsOneWidget);
    expect(find.text(r'Cash $20.00'), findsOneWidget);
    expect(find.text(r'Change $9.99'), findsOneWidget);
    expect(find.text('Print'), findsNothing);
  });

  testWidgets('legacy receipt line does not invent tax category metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CanonicalReceiptView(
            receipt: receipt(category: null, rate: null, lineTax: 0),
          ),
        ),
      ),
    );

    expect(find.textContaining('legacy', findRichText: true), findsNothing);
    expect(find.textContaining('%', findRichText: true), findsNothing);
  });

  testWidgets('Receipt Schema v2 displays exact register cashier shift and UTC time', (
    tester,
  ) async {
    final v2 = CanonicalReceipt(
      schemaVersion: 2,
      transactionId: 'txn-v2',
      transactionVersion: 4,
      lineItems: const [],
      subtotalMinorUnits: 199,
      taxMinorUnits: 777,
      totalMinorUnits: 1234,
      tenderedCashMinorUnits: 2000,
      changeDueMinorUnits: 999,
      register: const RegisterIdentity(
        registerId: 'register-one',
        displayName: 'Front Register',
      ),
      cashier: const CashierIdentity(
        cashierId: 'cashier-one',
        displayName: 'Alice',
      ),
      shiftId: 'shift-one',
      startedAtEpochMs: 0,
      completedAtEpochMs: 1000,
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CanonicalReceiptView(receipt: v2))),
    );
    expect(find.text('Register: Front Register (register-one)'), findsOneWidget);
    expect(find.text('Cashier: Alice (cashier-one)'), findsOneWidget);
    expect(find.text('Shift: shift-one'), findsOneWidget);
    expect(find.text('Started: 1970-01-01 00:00:00 UTC'), findsOneWidget);
    expect(find.text('Completed: 1970-01-01 00:00:01 UTC'), findsOneWidget);
  });

  testWidgets('completed receipt screen performs exact query and displays it', (
    tester,
  ) async {
    final client = FakeReceiptClient()
      ..receiptHandlers.add(
        (transactionId) async => receipt(transactionId: transactionId),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: ReceiptScreen(client: client, transactionId: 'txn/exact value'),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.receiptReads, ['txn/exact value']);
    expect(client.commandCalls, 0);
    expect(client.transactionReads, 0);
    expect(find.text('Transaction: txn/exact value'), findsOneWidget);
  });

  testWidgets('receipt screen failure preserves explicit retry', (
    tester,
  ) async {
    final client = FakeReceiptClient()
      ..receiptHandlers.add(
        (_) async => throw const PosCoreTransportFailure('offline'),
      )
      ..receiptHandlers.add((_) async => receipt());

    await tester.pumpWidget(
      MaterialApp(
        home: ReceiptScreen(client: client, transactionId: 'txn-receipt'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Unable to load the completed sale receipt.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(client.receiptReads, ['txn-receipt']);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(client.receiptReads, ['txn-receipt', 'txn-receipt']);
    expect(find.text('Transaction: txn-receipt'), findsOneWidget);
  });

  testWidgets('lookup submits exact opaque text only on explicit action', (
    tester,
  ) async {
    final client = FakeReceiptClient()
      ..receiptHandlers.add(
        (transactionId) async => receipt(transactionId: transactionId),
      );
    await tester.pumpWidget(
      MaterialApp(home: ReceiptLookupScreen(client: client)),
    );

    await tester.enterText(
      find.byKey(const Key('receipt-transaction-id-field')),
      ' txn/Exact? ',
    );
    await tester.pump();
    expect(client.receiptReads, isEmpty);

    await tester.tap(find.text('Find Receipt'));
    await tester.pumpAndSettle();

    expect(client.receiptReads, [' txn/Exact? ']);
    expect(find.text('Transaction:  txn/Exact? '), findsOneWidget);
    expect(client.commandCalls, 0);
    expect(client.transactionReads, 0);
  });

  testWidgets('empty lookup performs no read', (tester) async {
    final client = FakeReceiptClient();
    await tester.pumpWidget(
      MaterialApp(home: ReceiptLookupScreen(client: client)),
    );

    await tester.tap(find.text('Find Receipt'));
    await tester.pump();

    expect(client.receiptReads, isEmpty);
    expect(find.text('Enter a transaction ID.'), findsOneWidget);
  });

  testWidgets('lookup maps not-found and unavailable responses safely', (
    tester,
  ) async {
    final client = FakeReceiptClient()
      ..receiptHandlers.add(
        (_) async => throw const PosCoreServerFailure(
          code: 'transaction_not_found',
          message: 'backend copy',
          statusCode: 404,
        ),
      )
      ..receiptHandlers.add(
        (_) async => throw const PosCoreServerFailure(
          code: 'receipt_not_available',
          reason: 'transaction_not_completed',
          message: 'backend copy',
          statusCode: 409,
        ),
      );
    await tester.pumpWidget(
      MaterialApp(home: ReceiptLookupScreen(client: client)),
    );
    final field = find.byKey(const Key('receipt-transaction-id-field'));

    await tester.enterText(field, 'txn-missing');
    await tester.tap(find.text('Find Receipt'));
    await tester.pumpAndSettle();
    expect(find.text('Completed sale not found.'), findsOneWidget);

    await tester.enterText(field, 'txn-open');
    await tester.tap(find.text('Find Receipt'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Receipt is not available because this transaction is not completed.',
      ),
      findsOneWidget,
    );
  });
}
