import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pos_terminal/core/pos_core/http_pos_core_client.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';

final class RealPosCoreFixture {
  RealPosCoreFixture._({
    required this.repositoryRoot,
    required this.temporaryDirectory,
  });

  static const _startupTimeout = Duration(seconds: 15);
  static const _healthAttemptTimeout = Duration(milliseconds: 400);
  static const _healthPollInterval = Duration(milliseconds: 50);
  static const _shutdownTimeout = Duration(seconds: 5);
  static const _catalogActivationTimeout = Duration(seconds: 15);

  static Future<RealPosCoreFixture> create() async {
    final repositoryRoot = await _findRepositoryRoot(Directory.current);
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'grocery-pos-integration-',
    );
    return RealPosCoreFixture._(
      repositoryRoot: repositoryRoot,
      temporaryDirectory: temporaryDirectory,
    );
  }

  final Directory repositoryRoot;
  final Directory temporaryDirectory;
  final _stdoutTail = _OutputTail();
  final _stderrTail = _OutputTail();

  Process? _process;
  Future<int>? _exitCodeFuture;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  int? _observedExitCode;
  Uri? _baseUri;
  bool _disposed = false;
  bool _catalogPrepared = false;

  String get databasePath => _join(temporaryDirectory.path, 'pos.db');

  String get recoveryFilePath =>
      _join(temporaryDirectory.path, 'flutter/cashier-session-v1.json');

  Uri get baseUri {
    final value = _baseUri;
    if (value == null) {
      throw StateError('POS Core fixture is not running.');
    }
    return value;
  }

  bool get isRunning => _process != null && _observedExitCode == null;

  Future<void> start() async {
    if (_disposed) {
      throw StateError('A disposed POS Core fixture cannot be restarted.');
    }
    if (_process != null) {
      throw StateError('POS Core fixture is already started.');
    }

    await _prepareCatalogIfNeeded();

    final port = await _allocateLoopbackPort();
    final backendDirectory = _join(repositoryRoot.path, 'pos-backend-racket');
    _stdoutTail.clear();
    _stderrTail.clear();
    _observedExitCode = null;
    _baseUri = Uri(scheme: 'http', host: '127.0.0.1', port: port);

    final process = await Process.start(
      'racket',
      const ['main.rkt'],
      workingDirectory: backendDirectory,
      environment: {
        ...Platform.environment,
        'RACKET_API_HOST': '127.0.0.1',
        'RACKET_API_PORT': '$port',
        'SQLITE_DB_PATH': databasePath,
      },
    );
    _process = process;
    _exitCodeFuture = process.exitCode;
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .listen(_stdoutTail.add);
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen(_stderrTail.add);
    unawaited(
      process.exitCode.then((exitCode) {
        _observedExitCode = exitCode;
      }),
    );

    try {
      await _waitUntilReady();
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> stop() async {
    final process = _process;
    final exitCodeFuture = _exitCodeFuture;
    if (process == null || exitCodeFuture == null) {
      _baseUri = null;
      return;
    }

    if (_observedExitCode == null) {
      process.kill(ProcessSignal.sigterm);
    }
    try {
      await exitCodeFuture.timeout(_shutdownTimeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await exitCodeFuture.timeout(_shutdownTimeout);
    }

    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _process = null;
    _exitCodeFuture = null;
    _baseUri = null;
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await stop();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  }

  String diagnostics([String? heading]) {
    final sections = <String>[
      ?heading,
      'POS Core fixture URI: ${_baseUri ?? 'not running'}',
      'SQLite path: $databasePath',
      'Process exit code: ${_observedExitCode ?? 'not observed'}',
      'stdout tail:\n${_stdoutTail.value}',
      'stderr tail:\n${_stderrTail.value}',
    ];
    return sections.join('\n');
  }

  Future<void> _waitUntilReady() async {
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      timeout: _healthAttemptTimeout,
    );
    final deadline = DateTime.now().add(_startupTimeout);
    try {
      while (DateTime.now().isBefore(deadline)) {
        final exitCode = _observedExitCode;
        if (exitCode != null) {
          throw StateError(
            diagnostics('POS Core exited before becoming healthy.'),
          );
        }

        try {
          final health = await client.fetchHealth();
          if (health.ok && health.service == 'grocery-pos-core') {
            return;
          }
          throw StateError(
            diagnostics('Unexpected service answered the reserved port.'),
          );
        } on PosCoreTransportFailure {
          // The listener is not ready yet. The bounded loop tries again.
        } on PosCoreFailure catch (failure) {
          throw StateError(
            diagnostics('POS Core health response was invalid: $failure'),
          );
        }
        await Future<void>.delayed(_healthPollInterval);
      }
      throw TimeoutException(
        diagnostics('Timed out waiting for POS Core health.'),
        _startupTimeout,
      );
    } finally {
      client.close();
    }
  }

  Future<void> _prepareCatalogIfNeeded() async {
    if (_catalogPrepared) {
      return;
    }

    final backendDirectory = _join(repositoryRoot.path, 'pos-backend-racket');
    final catalogPath = _join(
      repositoryRoot.path,
      'pos-backend-racket/fixtures/development/catalog-snapshot-v1.json',
    );
    final process = await Process.start(
      'racket',
      ['scripts/catalog.rkt', 'activate', catalogPath, databasePath],
      workingDirectory: backendDirectory,
      environment: Platform.environment,
    );
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(_catalogActivationTimeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(_shutdownTimeout);
      throw TimeoutException(
        'Timed out activating the isolated development catalog.',
        _catalogActivationTimeout,
      );
    }
    final output = await stdoutFuture;
    final errorOutput = await stderrFuture;
    if (exitCode != 0) {
      throw StateError(
        'Catalog activation for POS Core fixture failed with exit code '
        '$exitCode.\nstdout:\n$output\nstderr:\n$errorOutput',
      );
    }
    _catalogPrepared = true;
  }
}

final class _OutputTail {
  static const _maximumCharacters = 16000;

  String _value = '';

  String get value => _value;

  void add(String chunk) {
    _value += chunk;
    if (_value.length > _maximumCharacters) {
      _value = _value.substring(_value.length - _maximumCharacters);
    }
  }

  void clear() {
    _value = '';
  }
}

Future<Directory> _findRepositoryRoot(Directory startingDirectory) async {
  var candidate = startingDirectory.absolute;
  while (true) {
    final hasFlake = await File(_join(candidate.path, 'flake.nix')).exists();
    final hasBackend = await File(
      _join(candidate.path, 'pos-backend-racket/main.rkt'),
    ).exists();
    if (hasFlake && hasBackend) {
      return candidate;
    }

    final parent = candidate.parent;
    if (parent.path == candidate.path) {
      throw StateError(
        'Could not find the grocery POS repository root from '
        '${startingDirectory.path}.',
      );
    }
    candidate = parent;
  }
}

Future<int> _allocateLoopbackPort() async {
  final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = reservation.port;
  await reservation.close();
  return port;
}

String _join(String root, String relative) {
  final separator = Platform.pathSeparator;
  final normalizedRoot = root.endsWith(separator)
      ? root.substring(0, root.length - 1)
      : root;
  return '$normalizedRoot$separator${relative.replaceAll('/', separator)}';
}
