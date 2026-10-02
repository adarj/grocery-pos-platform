import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_readiness.dart';

import '../../integration/support/core_responsiveness.dart';

PosCoreReadiness _readiness({String? reason}) => PosCoreReadiness.fromJson({
  'ok': reason == null,
  'service': 'grocery-pos-core',
  'status': reason == null ? 'ready' : 'not_ready',
  if (reason == null) 'database_schema_version': 12 else 'reason': reason,
});

String _diagnostics(String heading) =>
    '$heading\nURI: http://127.0.0.1:1234\nPID: 42\n'
    'Catalog activation exit code: 0\nstdout tail: fixture output\n'
    'stderr tail: fixture error';

Future<void> _wait({
  required Future<PosCoreReadiness> Function(Duration) observe,
  Completer<int>? exit,
  int? Function()? observedExitCode,
  Duration timeout = const Duration(seconds: 2),
  Duration attemptTimeout = const Duration(milliseconds: 20),
  Duration pollInterval = Duration.zero,
  Duration Function()? elapsedTime,
}) => waitUntilCoreResponsiveAfterExternalMutation(
  operation: 'After catalog activation (CLI exit code 0)',
  observe: observe,
  processExitCode: (exit ?? Completer<int>()).future,
  observedExitCode: observedExitCode ?? () => null,
  diagnostics: _diagnostics,
  timeout: timeout,
  attemptTimeout: attemptTimeout,
  pollInterval: pollInterval,
  elapsedTime: elapsedTime,
);

void main() {
  test(
    'transient transport and database unavailability then success',
    () async {
      var attempts = 0;
      await _wait(
        observe: (_) async {
          attempts += 1;
          switch (attempts) {
            case 1:
              throw const PosCoreTransportFailure('Untrusted transport detail');
            case 2:
              return _readiness(reason: 'database_unavailable');
            default:
              return _readiness();
          }
        },
      );
      expect(attempts, 3);
    },
  );

  test(
    'never responsive fails at a bounded deadline with diagnostics',
    () async {
      var elapsed = Duration.zero;
      await expectLater(
        _wait(
          observe: (_) async {
            elapsed += const Duration(milliseconds: 10);
            throw const PosCoreTransportFailure('Untrusted detail');
          },
          elapsedTime: () => elapsed,
          timeout: const Duration(milliseconds: 40),
        ),
        throwsA(
          isA<TimeoutException>().having(
            (failure) => failure.message,
            'diagnostics',
            allOf([
              contains(
                'Activation succeeded, but live Core did not become responsive',
              ),
              contains('Elapsed:'),
              contains('attempts:'),
              contains('PosCoreTransportFailure'),
              contains('URI:'),
              contains('PID:'),
              contains('Catalog activation exit code: 0'),
              contains('stdout tail:'),
              contains('stderr tail:'),
              isNot(contains('Untrusted detail')),
            ]),
          ),
        ),
      );
    },
  );

  test(
    'a hung observer is bounded by both request and overall deadlines',
    () async {
      final bounds = <Duration>[];
      var elapsed = Duration.zero;
      await expectLater(
        _wait(
          observe: (bound) {
            bounds.add(bound);
            elapsed += bound;
            return Completer<PosCoreReadiness>().future;
          },
          elapsedTime: () => elapsed,
          timeout: const Duration(milliseconds: 45),
        ).timeout(const Duration(seconds: 1)),
        throwsA(
          isA<TimeoutException>().having(
            (failure) => failure.message,
            'observation',
            contains('Readiness attempt exceeded its request deadline'),
          ),
        ),
      );
      expect(bounds, isNotEmpty);
      expect(bounds, const [
        Duration(milliseconds: 20),
        Duration(milliseconds: 20),
        Duration(milliseconds: 5),
      ]);
      expect(
        bounds,
        everyElement(lessThanOrEqualTo(const Duration(milliseconds: 20))),
      );
    },
  );

  test(
    'process exit interrupts an in-flight observation immediately',
    () async {
      final exit = Completer<int>();
      final started = Completer<void>();
      var attempts = 0;
      final waiting = _wait(
        exit: exit,
        attemptTimeout: const Duration(seconds: 2),
        observe: (_) {
          attempts += 1;
          started.complete();
          return Completer<PosCoreReadiness>().future;
        },
      );
      final assertion = expectLater(
        waiting.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<StateError>().having(
            (failure) => failure.message,
            'diagnostics',
            allOf(
              contains('exited with code 23'),
              contains('attempts: 1'),
              contains('stderr tail:'),
            ),
          ),
        ),
      );
      await started.future;
      exit.complete(23);
      await assertion;
      expect(attempts, 1);
    },
  );

  test('a late ready response cannot bypass the overall deadline', () async {
    var elapsed = Duration.zero;
    await expectLater(
      _wait(
        elapsedTime: () => elapsed,
        observe: (_) async {
          elapsed = const Duration(seconds: 2);
          return _readiness();
        },
      ),
      throwsA(
        isA<TimeoutException>().having(
          (failure) => failure.message,
          'deadline',
          contains('Ready response arrived after the overall deadline'),
        ),
      ),
    );
  });

  test('process exit interrupts polling backoff', () async {
    final exit = Completer<int>();
    var attempts = 0;
    await expectLater(
      _wait(
        exit: exit,
        pollInterval: const Duration(seconds: 2),
        observe: (_) async {
          attempts += 1;
          // The immediate failing probe settles through microtasks first;
          // this event then interrupts the two-second polling backoff.
          Timer.run(() => exit.complete(9));
          throw const PosCoreTransportFailure('Unavailable');
        },
      ).timeout(const Duration(seconds: 1)),
      throwsA(
        isA<StateError>().having(
          (failure) => failure.message,
          'exit',
          contains('exited with code 9'),
        ),
      ),
    );
    expect(attempts, 1);
  });

  test('already exited process is not probed', () async {
    await expectLater(
      _wait(
        exit: Completer<int>()..complete(7),
        observedExitCode: () => 7,
        observe: (_) async => fail('Exited process must not be probed'),
      ),
      throwsA(
        isA<StateError>().having(
          (failure) => failure.message,
          'exit',
          allOf(contains('exited with code 7'), contains('attempts: 0')),
        ),
      ),
    );
  });

  test('ready result cannot hide a concurrent observed process exit', () async {
    int? code;
    await expectLater(
      _wait(
        observedExitCode: () => code,
        observe: (_) async {
          code = 5;
          return _readiness();
        },
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('an unexpected service fails without retry', () async {
    var attempts = 0;
    await expectLater(
      _wait(
        observe: (_) async {
          attempts += 1;
          return PosCoreReadiness.fromJson({
            'ok': true,
            'service': 'unexpected-service',
            'status': 'ready',
            'database_schema_version': 12,
          });
        },
      ),
      throwsA(
        isA<StateError>().having(
          (failure) => failure.message,
          'service',
          contains('Unexpected service'),
        ),
      ),
    );
    expect(attempts, 1);
  });

  test('persistent readiness faults fail without retry', () async {
    for (final reason in [
      'database_missing',
      'database_schema_not_current',
      'runtime_stopped',
    ]) {
      var attempts = 0;
      await expectLater(
        _wait(
          observe: (_) async {
            attempts += 1;
            return _readiness(reason: reason);
          },
        ),
        throwsA(
          isA<StateError>().having(
            (failure) => failure.message,
            'fault',
            contains(reason),
          ),
        ),
      );
      expect(attempts, 1);
    }
  });

  test(
    'invalid responses fail immediately with sanitized diagnostics',
    () async {
      var attempts = 0;
      await expectLater(
        _wait(
          observe: (_) async {
            attempts += 1;
            throw const PosCoreInvalidResponseFailure(
              'Untrusted decoded input',
            );
          },
        ),
        throwsA(
          isA<StateError>().having(
            (failure) => failure.message,
            'diagnostics',
            allOf(
              contains('PosCoreInvalidResponseFailure'),
              isNot(contains('Untrusted decoded input')),
            ),
          ),
        ),
      );
      expect(attempts, 1);
    },
  );

  test('strict business observation adds context without retrying', () async {
    var attempts = 0;
    await expectLater(
      observeCoreOperation<void>(
        operation: 'Historical receipt GET after catalog barrier',
        observe: () async {
          attempts += 1;
          throw const PosCoreTransportFailure('Untrusted detail');
        },
        diagnostics: _diagnostics,
      ),
      throwsA(
        isA<StateError>().having(
          (failure) => failure.message,
          'diagnostics',
          allOf(
            contains('Historical receipt GET'),
            contains('attempts: 1'),
            contains('stderr tail:'),
          ),
        ),
      ),
    );
    expect(attempts, 1);
  });

  test(
    'business rejection and assertion failure retain their original identity',
    () async {
      for (final failure in [
        const PosCoreServerFailure(code: 'not_found', message: 'Not found'),
        StateError('Historical receipt value changed'),
      ]) {
        await expectLater(
          observeCoreOperation<void>(
            operation: 'Historical receipt GET',
            observe: () async => throw failure,
            diagnostics: _diagnostics,
          ),
          throwsA(same(failure)),
        );
      }
    },
  );
}
