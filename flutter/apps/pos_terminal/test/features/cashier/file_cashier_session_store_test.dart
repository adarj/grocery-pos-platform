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

  test('correction commands survive the real file store unchanged', () async {
    final removal = RemoveLineItemCommand(
      commandId: 'cmd-remove',
      transactionId: 'txn-1',
      expectedVersion: 7,
      lineIndex: 2,
    );
    await store.save(
      PersistedCashierSession(
        activeTransactionId: 'txn-1',
        pendingCommand: removal,
      ),
    );

    final restoredRemoval =
        (await store.load())!.pendingCommand! as RemoveLineItemCommand;
    expect(restoredRemoval.commandId, removal.commandId);
    expect(restoredRemoval.transactionId, removal.transactionId);
    expect(restoredRemoval.expectedVersion, removal.expectedVersion);
    expect(restoredRemoval.lineIndex, removal.lineIndex);

    final voidCommand = VoidTransactionCommand(
      commandId: 'cmd-void',
      transactionId: 'txn-1',
      expectedVersion: 8,
    );
    await store.save(
      PersistedCashierSession(
        activeTransactionId: 'txn-1',
        pendingCommand: voidCommand,
      ),
    );

    final restoredVoid =
        (await store.load())!.pendingCommand! as VoidTransactionCommand;
    expect(restoredVoid.commandId, voidCommand.commandId);
    expect(restoredVoid.transactionId, voidCommand.transactionId);
    expect(restoredVoid.expectedVersion, voidCommand.expectedVersion);
  });

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

  test('Flatpak-style XDG state preserves the exact pending command', () async {
    final flatpakStateHome =
        '${temporaryDirectory.path}/.var/app/com.grocerypos.pos_terminal/'
        '.local/state';
    final sandboxPath = resolveCashierSessionFilePath({
      'HOME': '${temporaryDirectory.path}/sandbox-home',
      'XDG_STATE_HOME': flatpakStateHome,
    });
    final firstProcessStore = FileCashierSessionStore(filePath: sandboxPath);
    final pending = TenderCashCommand(
      commandId: 'cmd-flatpak-recovery',
      transactionId: 'txn-flatpak-recovery',
      expectedVersion: 4,
      amountMinorUnits: 500,
    );
    await firstProcessStore.save(
      PersistedCashierSession(
        activeTransactionId: pending.transactionId,
        pendingCommand: pending,
      ),
    );

    final restartedProcessStore = FileCashierSessionStore(
      filePath: sandboxPath,
    );
    final restored = await restartedProcessStore.load();
    final restoredCommand = restored!.pendingCommand! as TenderCashCommand;
    expect(restoredCommand.commandId, pending.commandId);
    expect(restoredCommand.transactionId, pending.transactionId);
    expect(restoredCommand.expectedVersion, pending.expectedVersion);
    expect(restoredCommand.amountMinorUnits, pending.amountMinorUnits);
    expect(sandboxPath, startsWith(flatpakStateHome));
  });
}
