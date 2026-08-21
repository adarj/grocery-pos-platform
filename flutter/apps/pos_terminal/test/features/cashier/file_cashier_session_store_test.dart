import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/features/cashier/cashier_session_store.dart';
import 'package:pos_terminal/features/cashier/file_cashier_session_store.dart';

void main() {
  late Directory temporaryDirectory;
  late String filePath;
  late FileCashierSessionStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'cashier-session-store-test-',
    );
    filePath = '${temporaryDirectory.path}/nested/cashier-session-v1.json';
    store = FileCashierSessionStore(filePath: filePath);
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('missing recovery file loads as no session', () async {
    expect(await store.load(), isNull);
  });

  test('save creates parent and loads the complete semantic record', () async {
    final command = ScanBarcodeCommand(
      commandId: 'cmd-scan',
      transactionId: 'txn-1',
      expectedVersion: 3,
      barcode: '049000001234',
    );

    await store.save(
      PersistedCashierSession(
        activeTransactionId: 'txn-1',
        pendingCommand: command,
      ),
    );
    final restored = await store.load();

    expect(await File(filePath).exists(), isTrue);
    expect(restored!.activeTransactionId, 'txn-1');
    final restoredCommand = restored.pendingCommand! as ScanBarcodeCommand;
    expect(restoredCommand.commandId, 'cmd-scan');
    expect(restoredCommand.expectedVersion, 3);
    expect(restoredCommand.barcode, '049000001234');
  });

  test(
    'replacement save atomically publishes one complete new record',
    () async {
      await store.save(
        PersistedCashierSession(
          activeTransactionId: 'txn-1',
          pendingCommand: StartTransactionCommand(
            commandId: 'cmd-start',
            transactionId: 'txn-1',
            expectedVersion: 0,
          ),
        ),
      );

      await store.save(PersistedCashierSession(activeTransactionId: 'txn-1'));

      final raw = await File(filePath).readAsString();
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      expect(decoded['active_transaction_id'], 'txn-1');
      expect(decoded['pending_command'], isNull);
      final siblingNames = await Directory(
        File(filePath).parent.path,
      ).list().map((entry) => entry.path).toList();
      expect(siblingNames, [filePath]);
    },
  );

  test('clear removes the live record and is idempotent', () async {
    await store.save(PersistedCashierSession(activeTransactionId: 'txn-1'));

    await store.clear();
    await store.clear();

    expect(await File(filePath).exists(), isFalse);
    expect(await store.load(), isNull);
  });

  test(
    'corrupt JSON and partial records fail closed without deletion',
    () async {
      await File(filePath).parent.create(recursive: true);
      await File(filePath).writeAsString('{not-json');

      await expectLater(
        store.load(),
        throwsA(
          isA<CashierSessionStoreFailure>().having(
            (failure) => failure.kind,
            'kind',
            CashierSessionStoreFailureKind.corruptData,
          ),
        ),
      );
      expect(await File(filePath).exists(), isTrue);

      await File(filePath).writeAsString(
        jsonEncode({'schema_version': 1, 'active_transaction_id': 'txn-1'}),
      );
      await expectLater(
        store.load(),
        throwsA(isA<CashierSessionStoreFailure>()),
      );
      expect(await File(filePath).exists(), isTrue);
    },
  );

  test('XDG state home wins over HOME', () {
    expect(
      resolveCashierSessionFilePath({
        'XDG_STATE_HOME': '/xdg/state',
        'HOME': '/home/register',
      }),
      '/xdg/state/grocery-pos/pos-terminal/cashier-session-v1.json',
    );
  });

  test('HOME fallback uses the standard local state directory', () {
    expect(
      resolveCashierSessionFilePath({'HOME': '/home/register'}),
      '/home/register/.local/state/grocery-pos/pos-terminal/'
      'cashier-session-v1.json',
    );
  });

  test('empty XDG state home falls back to HOME', () {
    expect(
      resolveCashierSessionFilePath({
        'XDG_STATE_HOME': '',
        'HOME': '/home/register',
      }),
      '/home/register/.local/state/grocery-pos/pos-terminal/'
      'cashier-session-v1.json',
    );
  });

  test('missing state-home configuration fails clearly', () {
    expect(
      () => resolveCashierSessionFilePath(const {}),
      throwsA(
        isA<CashierSessionStoreFailure>().having(
          (failure) => failure.kind,
          'kind',
          CashierSessionStoreFailureKind.storageUnavailable,
        ),
      ),
    );
  });
}
