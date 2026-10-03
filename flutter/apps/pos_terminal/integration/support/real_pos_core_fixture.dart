import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pos_terminal/core/pos_core/http_pos_core_client.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';

import 'core_responsiveness.dart';

final class RealPosCoreFixture {
  RealPosCoreFixture._({
    required this.repositoryRoot,
    required this.temporaryDirectory,
  });

  // Racket startup and CLI activation include migration validation. Keep their
  // bounds generous enough for a loaded development/CI host while polling and
  // teardown remain independently bounded.
  static const _startupTimeout = Duration(seconds: 30);
  static const _readinessAttemptTimeout = Duration(milliseconds: 400);
  static const _readinessPollInterval = Duration(milliseconds: 50);
  static const _shutdownTimeout = Duration(seconds: 5);
  static const _referenceDataActivationTimeout = Duration(seconds: 30);
  // Observe a live process within the normal client request budget. This is
  // distinct from CLI startup/migration time and never extends business GETs.
  static const _postActivationTimeout = Duration(seconds: 3);

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
  bool _operationalConfigurationPrepared = false;
  bool _operatorCredentialPrepared = false;
  String _lastExternalMutation = 'No external mutation completed.';

  String get databasePath => _join(temporaryDirectory.path, 'pos.db');

  String get recoveryFilePath =>
      _join(temporaryDirectory.path, 'flutter/cashier-session-v1.json');

  String get posBackendDirectoryPath =>
      _join(repositoryRoot.path, 'pos-backend-racket');

  Uri get baseUri {
    final value = _baseUri;
    if (value == null) {
      throw StateError('POS Core fixture is not running.');
    }
    return value;
  }

  bool get isRunning => _process != null && _observedExitCode == null;

  Future<void> prepareReferenceData() async {
    if (_disposed) {
      throw StateError('A disposed POS Core fixture cannot be prepared.');
    }
    if (_process != null) {
      throw StateError(
        'Reference data must be prepared before POS Core starts.',
      );
    }
    await _prepareReferenceDataIfNeeded();
  }

  int get processId {
    final process = _process;
    if (process == null || _observedExitCode != null) {
      throw StateError('POS Core fixture is not running.');
    }
    return process.pid;
  }

  Future<void> start() async {
    if (_disposed) {
      throw StateError('A disposed POS Core fixture cannot be restarted.');
    }
    if (_process != null) {
      throw StateError('POS Core fixture is already started.');
    }

    await _prepareReferenceDataIfNeeded();

    final port = await _allocateLoopbackPort();
    final backendDirectory = posBackendDirectoryPath;
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

  /// Kills only the child POS Core process and waits for the operating system
  /// to reap it. This is a process-crash test seam, not a power-loss model.
  Future<void> killAbruptly() async {
    final process = _process;
    final exitCodeFuture = _exitCodeFuture;
    if (process == null ||
        exitCodeFuture == null ||
        _observedExitCode != null) {
      throw StateError('POS Core fixture is not running.');
    }
    if (!process.kill(ProcessSignal.sigkill)) {
      throw StateError('Could not send SIGKILL to the POS Core fixture.');
    }
    await exitCodeFuture.timeout(_shutdownTimeout);
    await _releaseProcessHandles();
  }

  Future<void> activateCatalogSnapshot(String catalogPath) async {
    if (_disposed) {
      throw StateError(
        'A disposed POS Core fixture cannot activate a catalog.',
      );
    }
    await _runCatalogActivation(catalogPath);
    _lastExternalMutation = 'Catalog activation exit code: 0';
    await _waitAfterExternalMutation('catalog activation');
  }

  Future<void> activateOperationalConfigurationSnapshot(
    String configurationPath,
  ) async {
    if (_disposed) {
      throw StateError(
        'A disposed POS Core fixture cannot activate register configuration.',
      );
    }
    await _runOperationalConfigurationActivation(configurationPath);
    _lastExternalMutation = 'Register configuration activation exit code: 0';
    await _waitAfterExternalMutation('register configuration activation');
  }

  Future<void> enrollIntegrationOperator({
    required String operatorId,
    required String pin,
    required String role,
  }) async {
    if (_disposed) {
      throw StateError('A disposed POS Core fixture cannot enroll operators.');
    }
    await _runOperatorCredentialEnrollment(
      pin: pin,
      operators: <(String, String)>[(operatorId, role)],
    );
  }

  Future<void> enrollIntegrationOperators({
    required List<(String, String)> operators,
    required String pin,
  }) async {
    if (_disposed) {
      throw StateError('A disposed POS Core fixture cannot enroll operators.');
    }
    await _runOperatorCredentialEnrollment(pin: pin, operators: operators);
  }

  Future<void> resetIntegrationOperatorPin({
    required String operatorId,
    required String newPin,
  }) async {
    if (_disposed) {
      throw StateError('A disposed POS Core fixture cannot reset operators.');
    }
    final process = await Process.start(
      'racket',
      [
        'tests/support/reset-integration-operator.rkt',
        databasePath,
        operatorId,
      ],
      workingDirectory: posBackendDirectoryPath,
      environment: Platform.environment,
    );
    process.stdin.writeln(newPin);
    await process.stdin.close();
    final stdoutTail = _OutputTail();
    final stderrTail = _OutputTail();
    final stdoutFuture = process.stdout
        .transform(utf8.decoder)
        .forEach(stdoutTail.add);
    final stderrFuture = process.stderr
        .transform(utf8.decoder)
        .forEach(stderrTail.add);
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(
        _referenceDataActivationTimeout,
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(_shutdownTimeout);
      await Future.wait([stdoutFuture, stderrFuture]);
      throw TimeoutException(
        diagnostics(
          'Timed out resetting isolated operator PIN.\n'
          'CLI stdout tail:\n${stdoutTail.value}\n'
          'CLI stderr tail:\n${stderrTail.value}',
        ),
        _referenceDataActivationTimeout,
      );
    }
    await Future.wait([stdoutFuture, stderrFuture]);
    final output = stdoutTail.value;
    final errorOutput = stderrTail.value;
    if (exitCode != 0) {
      throw StateError(
        diagnostics(
          'Isolated operator reset failed with exit code $exitCode.\n'
          'stdout:\n$output\nstderr:\n$errorOutput',
        ),
      );
    }
    _lastExternalMutation = 'Operator reset exit code: 0';
    await _waitAfterExternalMutation('operator reset');
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

    await _releaseProcessHandles();
  }

  Future<void> _releaseProcessHandles() async {
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
      'POS Core fixture PID: ${_process?.pid ?? 'not running'}',
      'SQLite path: $databasePath',
      'Process exit code: ${_observedExitCode ?? 'not observed'}',
      _lastExternalMutation,
      'stdout tail:\n${_stdoutTail.value}',
      'stderr tail:\n${_stderrTail.value}',
    ];
    return sections.join('\n');
  }

  Future<T> observeOperation<T>(
    String operation,
    Future<T> Function() observe,
  ) => observeCoreOperation(
    operation: operation,
    observe: observe,
    diagnostics: diagnostics,
  );

  Future<void> _waitAfterExternalMutation(String operation) async {
    // Pre-start preparation has no live process to synchronize with. A process
    // that exited after start still has handles and must fail the barrier.
    if (_process == null) {
      return;
    }
    HttpPosCoreClient? probeClient;
    try {
      await waitUntilCoreResponsiveAfterExternalMutation(
        operation: 'After $operation (CLI exit code 0)',
        observe: (timeout) async {
          final client = HttpPosCoreClient(baseUri: baseUri, timeout: timeout);
          probeClient = client;
          try {
            // /ready opens the authoritative DB with production connection
            // policy and reads schema history. /health does no database work.
            return await client.fetchReadiness();
          } finally {
            client.close();
          }
        },
        processExitCode: _exitCodeFuture!,
        observedExitCode: () => _observedExitCode,
        diagnostics: diagnostics,
        timeout: _postActivationTimeout,
        attemptTimeout: _readinessAttemptTimeout,
        pollInterval: _readinessPollInterval,
      );
    } finally {
      // Also cancel a pending request when process exit wins the observation.
      probeClient?.close();
    }
  }

  Future<void> _waitUntilReady() async {
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      timeout: _readinessAttemptTimeout,
    );
    final deadline = DateTime.now().add(_startupTimeout);
    try {
      while (DateTime.now().isBefore(deadline)) {
        final exitCode = _observedExitCode;
        if (exitCode != null) {
          throw StateError(
            diagnostics('POS Core exited before becoming ready.'),
          );
        }

        try {
          final readiness = await client.fetchReadiness();
          if (readiness.service != 'grocery-pos-core') {
            throw StateError(
              diagnostics('Unexpected service answered the reserved port.'),
            );
          }
          if (readiness.ready) {
            return;
          }
        } on PosCoreTransportFailure {
          // The listener is not ready yet. The bounded loop tries again.
        } on PosCoreFailure catch (failure) {
          throw StateError(
            diagnostics('POS Core readiness response was invalid: $failure'),
          );
        }
        await Future<void>.delayed(_readinessPollInterval);
      }
      throw TimeoutException(
        diagnostics('Timed out waiting for POS Core readiness.'),
        _startupTimeout,
      );
    } finally {
      client.close();
    }
  }

  Future<void> _prepareReferenceDataIfNeeded() async {
    if (!_catalogPrepared) {
      final catalogPath = _join(
        repositoryRoot.path,
        'pos-backend-racket/fixtures/development/catalog-snapshot-v2.json',
      );
      await _runCatalogActivation(catalogPath);
      _catalogPrepared = true;
    }
    if (!_operationalConfigurationPrepared) {
      final configurationPath = _join(
        repositoryRoot.path,
        'fixtures/development/register-configuration-v1.json',
      );
      await _runOperationalConfigurationActivation(configurationPath);
      _operationalConfigurationPrepared = true;
    }
    if (!_operatorCredentialPrepared) {
      await _runOperatorCredentialEnrollment(
        pin: '80421637',
        operators: const <(String, String)>[
          ('cashier-development-01', 'manager'),
        ],
      );
      _operatorCredentialPrepared = true;
    }
  }

  Future<void> _runCatalogActivation(String catalogPath) async {
    final backendDirectory = _join(repositoryRoot.path, 'pos-backend-racket');
    final process = await Process.start(
      'racket',
      ['scripts/catalog.rkt', 'activate', catalogPath, databasePath],
      workingDirectory: backendDirectory,
      environment: Platform.environment,
    );
    final stdoutTail = _OutputTail();
    final stderrTail = _OutputTail();
    final stdoutFuture = process.stdout
        .transform(utf8.decoder)
        .forEach(stdoutTail.add);
    final stderrFuture = process.stderr
        .transform(utf8.decoder)
        .forEach(stderrTail.add);

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(
        _referenceDataActivationTimeout,
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(_shutdownTimeout);
      await Future.wait([stdoutFuture, stderrFuture]);
      throw TimeoutException(
        diagnostics(
          'Timed out activating the isolated development catalog.\n'
          'CLI stdout tail:\n${stdoutTail.value}\n'
          'CLI stderr tail:\n${stderrTail.value}',
        ),
        _referenceDataActivationTimeout,
      );
    }
    await Future.wait([stdoutFuture, stderrFuture]);
    final output = stdoutTail.value;
    final errorOutput = stderrTail.value;
    if (exitCode != 0) {
      throw StateError(
        diagnostics(
          'Catalog activation for POS Core fixture failed with exit code '
          '$exitCode.\nstdout:\n$output\nstderr:\n$errorOutput',
        ),
      );
    }
  }

  Future<void> _runOperationalConfigurationActivation(
    String configurationPath,
  ) async {
    final backendDirectory = _join(repositoryRoot.path, 'pos-backend-racket');
    final process = await Process.start(
      'racket',
      [
        'scripts/register-configuration.rkt',
        'activate',
        configurationPath,
        databasePath,
      ],
      workingDirectory: backendDirectory,
      environment: Platform.environment,
    );
    final stdoutTail = _OutputTail();
    final stderrTail = _OutputTail();
    final stdoutFuture = process.stdout
        .transform(utf8.decoder)
        .forEach(stdoutTail.add);
    final stderrFuture = process.stderr
        .transform(utf8.decoder)
        .forEach(stderrTail.add);

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(
        _referenceDataActivationTimeout,
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(_shutdownTimeout);
      await Future.wait([stdoutFuture, stderrFuture]);
      throw TimeoutException(
        diagnostics(
          'Timed out activating isolated register configuration.\n'
          'CLI stdout tail:\n${stdoutTail.value}\n'
          'CLI stderr tail:\n${stderrTail.value}',
        ),
        _referenceDataActivationTimeout,
      );
    }
    await Future.wait([stdoutFuture, stderrFuture]);
    final output = stdoutTail.value;
    final errorOutput = stderrTail.value;
    if (exitCode != 0) {
      throw StateError(
        diagnostics(
          'Register configuration activation for POS Core fixture failed with '
          'exit code $exitCode.\nstdout:\n$output\nstderr:\n$errorOutput',
        ),
      );
    }
  }

  Future<void> _runOperatorCredentialEnrollment({
    required String pin,
    required List<(String, String)> operators,
  }) async {
    final backendDirectory = _join(repositoryRoot.path, 'pos-backend-racket');
    final arguments = <String>[
      'tests/support/enroll-integration-operator.rkt',
      databasePath,
      for (final (operatorId, role) in operators) ...[operatorId, role],
    ];
    final process = await Process.start(
      'racket',
      arguments,
      workingDirectory: backendDirectory,
      environment: Platform.environment,
    );
    process.stdin.writeln(pin);
    await process.stdin.close();
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(
        _referenceDataActivationTimeout,
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(_shutdownTimeout);
      throw TimeoutException(
        'Timed out enrolling the isolated integration operator.',
        _referenceDataActivationTimeout,
      );
    }
    final output = await stdoutFuture;
    final errorOutput = await stderrFuture;
    if (exitCode != 0) {
      throw StateError(
        'Operator credential enrollment for POS Core fixture failed with '
        'exit code $exitCode.\nstdout:\n$output\nstderr:\n$errorOutput',
      );
    }
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
