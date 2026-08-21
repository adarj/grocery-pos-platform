import 'dart:convert';
import 'dart:io';

import 'cashier_session_store.dart';

const _relativeCashierSessionPath =
    'grocery-pos/pos-terminal/cashier-session-v1.json';

String resolveCashierSessionFilePath(Map<String, String> environment) {
  final xdgStateHome = environment['XDG_STATE_HOME'];
  if (xdgStateHome != null && xdgStateHome.isNotEmpty) {
    return _joinPath(xdgStateHome, _relativeCashierSessionPath);
  }

  final home = environment['HOME'];
  if (home != null && home.isNotEmpty) {
    return _joinPath(home, '.local/state/$_relativeCashierSessionPath');
  }

  throw const CashierSessionStoreFailure.storageUnavailable();
}

String _joinPath(String root, String relative) {
  final normalizedRoot = root.endsWith('/')
      ? root.substring(0, root.length - 1)
      : root;
  return '$normalizedRoot/$relative';
}

final class FileCashierSessionStore implements CashierSessionStore {
  FileCashierSessionStore({required String filePath})
    : _filePath = filePath,
      _configurationFailure = null;

  FileCashierSessionStore._unavailable(this._configurationFailure)
    : _filePath = null;

  factory FileCashierSessionStore.fromEnvironment({
    Map<String, String>? environment,
  }) {
    try {
      return FileCashierSessionStore(
        filePath: resolveCashierSessionFilePath(
          environment ?? Platform.environment,
        ),
      );
    } on CashierSessionStoreFailure catch (failure) {
      return FileCashierSessionStore._unavailable(failure);
    }
  }

  final String? _filePath;
  final CashierSessionStoreFailure? _configurationFailure;
  int _temporaryFileSequence = 0;

  File get _file {
    final failure = _configurationFailure;
    if (failure != null) {
      throw failure;
    }
    return File(_filePath!);
  }

  @override
  Future<PersistedCashierSession?> load() async {
    final file = _file;
    try {
      return decodePersistedCashierSession(await file.readAsString());
    } on CashierSessionStoreFailure {
      rethrow;
    } on FormatException {
      throw const CashierSessionStoreFailure.corruptData();
    } on PathNotFoundException {
      return null;
    } on FileSystemException {
      throw const CashierSessionStoreFailure.storageUnavailable();
    }
  }

  @override
  Future<void> save(PersistedCashierSession session) async {
    final file = _file;
    final temporaryFile = File(
      '${file.path}.tmp.$pid.${_temporaryFileSequence++}',
    );
    RandomAccessFile? output;
    try {
      await file.parent.create(recursive: true);
      output = await temporaryFile.open(mode: FileMode.write);
      await output.writeString(jsonEncode(session.toJson()));
      await output.flush();
      await output.close();
      output = null;
      await temporaryFile.rename(file.path);
    } on FileSystemException {
      if (output != null) {
        await _closeIgnoringFailure(output);
      }
      await _deleteIgnoringFailure(temporaryFile);
      throw const CashierSessionStoreFailure.storageUnavailable();
    }
  }

  @override
  Future<void> clear() async {
    final file = _file;
    try {
      await file.delete();
    } on PathNotFoundException {
      return;
    } on FileSystemException {
      throw const CashierSessionStoreFailure.storageUnavailable();
    }
  }
}

Future<void> _closeIgnoringFailure(RandomAccessFile file) async {
  try {
    await file.close();
  } on FileSystemException {
    // The primary storage failure remains the useful error.
  }
}

Future<void> _deleteIgnoringFailure(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } on FileSystemException {
    // A stale same-directory temporary file is safe to ignore.
  }
}
