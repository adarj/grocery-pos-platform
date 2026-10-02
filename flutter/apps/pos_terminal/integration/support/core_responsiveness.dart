import 'dart:async';

import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_readiness.dart';

/// Observes the live HTTP/database boundary after a separate CLI has committed.
/// This never repeats the mutation or a business operation.
Future<void> waitUntilCoreResponsiveAfterExternalMutation({
  required String operation,
  required Future<PosCoreReadiness> Function(Duration timeout) observe,
  required Future<int> processExitCode,
  required int? Function() observedExitCode,
  required String Function(String heading) diagnostics,
  required Duration timeout,
  required Duration attemptTimeout,
  required Duration pollInterval,
  Duration Function()? elapsedTime,
}) async {
  final elapsed = Stopwatch()..start();
  // Only helper regressions supply a clock. The real fixture uses Stopwatch.
  final readElapsed = elapsedTime ?? () => elapsed.elapsed;
  var attempts = 0;
  var lastObservation = 'No readiness response observed.';
  final processExited = processExitCode.then(_CoreExited.new);

  String context(String reason) => diagnostics(
    '$operation: $reason\n'
    'Elapsed: ${readElapsed().inMilliseconds} ms; attempts: $attempts\n'
    'Last observation: $lastObservation',
  );

  void checkProcess() {
    final code = observedExitCode();
    if (code != null) {
      throw _CoreExited(code);
    }
  }

  try {
    while (true) {
      checkProcess();
      final remaining = timeout - readElapsed();
      if (remaining <= Duration.zero) {
        break;
      }
      final bound = remaining < attemptTimeout ? remaining : attemptTimeout;
      attempts += 1;
      try {
        final observation = await Future.any<Object>([
          observe(bound).timeout(bound),
          processExited,
        ]);
        if (observation is _CoreExited) {
          throw observation;
        }
        final readiness = observation as PosCoreReadiness;
        checkProcess();
        if (readiness.service != 'grocery-pos-core') {
          throw StateError(context('Unexpected service answered the probe.'));
        }
        if (readiness.ready) {
          if (readElapsed() >= timeout) {
            lastObservation =
                'Ready response arrived after the overall deadline.';
            break;
          }
          return;
        }
        lastObservation = 'Readiness: ${readiness.reason!.wireValue}.';
        // Missing/schema-invalid/stopped databases are defects, not a transient
        // external-writer or scheduling interval.
        if (readiness.reason != PosCoreReadinessReason.databaseUnavailable) {
          throw StateError(
            context('Core reported a persistent readiness fault.'),
          );
        }
      } on PosCoreTransportFailure {
        lastObservation = 'PosCoreTransportFailure: Unable to reach POS Core.';
      } on TimeoutException {
        lastObservation = 'Readiness attempt exceeded its request deadline.';
      } on PosCoreFailure catch (failure) {
        // Failure messages can contain decoded input. Keep diagnostics typed.
        throw StateError(
          context('Invalid readiness response (${failure.runtimeType}).'),
        );
      }
      checkProcess();
      final backoffRemaining = timeout - readElapsed();
      if (backoffRemaining > Duration.zero) {
        final observation = await Future.any<Object?>([
          Future<void>.delayed(
            backoffRemaining < pollInterval ? backoffRemaining : pollInterval,
          ),
          processExited,
        ]);
        if (observation is _CoreExited) {
          throw observation;
        }
      }
    }
    checkProcess();
    throw TimeoutException(
      context('Activation succeeded, but live Core did not become responsive.'),
      timeout,
    );
  } on _CoreExited catch (exit) {
    throw StateError(context('Live POS Core exited with code ${exit.code}.'));
  } finally {
    elapsed.stop();
  }
}

/// Adds process context to one strict test operation, without retrying it or
/// reclassifying server/validation failures and business assertions.
Future<T> observeCoreOperation<T>({
  required String operation,
  required Future<T> Function() observe,
  required String Function(String heading) diagnostics,
}) async {
  final elapsed = Stopwatch()..start();
  try {
    return await observe();
  } on PosCoreTransportFailure catch (_, stackTrace) {
    Error.throwWithStackTrace(
      StateError(
        diagnostics(
          '$operation: strict Core operation failed.\n'
          'Elapsed: ${elapsed.elapsedMilliseconds} ms; attempts: 1\n'
          'Last observation: PosCoreTransportFailure: Unable to reach POS Core.',
        ),
      ),
      stackTrace,
    );
  } finally {
    elapsed.stop();
  }
}

final class _CoreExited implements Exception {
  const _CoreExited(this.code);

  final int code;
}
