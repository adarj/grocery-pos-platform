import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/authentication_client.dart';
import 'package:pos_terminal/core/pos_core/models/authentication.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/features/authentication/authentication_controller.dart';

const testToken =
    'gpos_s1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const testSession = AuthenticatedOperatorSession(
  operatorId: 'operator-1',
  displayName: 'Operator One',
  role: 'cashier',
  idleTimeoutSeconds: 300,
  absoluteExpiresAtEpochMs: 9999999999999,
);

final class FakeAuthClient implements PosAuthenticationClient {
  Object? loginFailure;
  Object? logoutFailure;
  Object? changePinFailure;
  int changePinCalls = 0;
  String? submittedCurrentPin;
  String? submittedNewPin;
  final Completer<void>? logoutCompleter;
  int loginCalls = 0;
  int logoutCalls = 0;
  String? logoutToken;

  FakeAuthClient({this.loginFailure, this.logoutFailure, this.logoutCompleter});

  @override
  Future<AuthenticationLogin> login(String operatorId, String pin) async {
    loginCalls += 1;
    final failure = loginFailure;
    if (failure != null) throw failure;
    return const AuthenticationLogin(
      accessToken: testToken,
      session: testSession,
    );
  }

  @override
  Future<AuthenticatedOperatorSession> fetchAuthenticatedSession() async =>
      testSession;

  @override
  Future<void> logout(String accessToken) async {
    logoutCalls += 1;
    logoutToken = accessToken;
    await logoutCompleter?.future;
    final failure = logoutFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<int> changePin(String currentPin, String newPin) async {
    changePinCalls += 1;
    submittedCurrentPin = currentPin;
    submittedNewPin = newPin;
    final failure = changePinFailure;
    if (failure != null) throw failure;
    return 2;
  }
}

final class FakeScheduler implements AuthenticationInactivityScheduler {
  Duration? duration;
  void Function()? callback;
  int schedules = 0;
  int cancels = 0;

  @override
  void schedule(Duration duration, void Function() callback) {
    this.duration = duration;
    this.callback = callback;
    schedules += 1;
  }

  @override
  void cancel() {
    callback = null;
    cancels += 1;
  }

  void fire() {
    final pending = callback;
    callback = null;
    pending?.call();
  }
}

void main() {
  test('successful PIN change locks locally without logout or recovery mutation', () async {
    final client = FakeAuthClient();
    final memory = MemoryAuthenticationSession();
    final controller = AuthenticationController(
      client: client,
      sessionMemory: memory,
      inactivityScheduler: FakeScheduler(),
    );
    await controller.login('operator-1', '80421637');

    expect(await controller.changePin('80421637', '48295173'),
        PinChangeOutcome.changed);
    expect(client.changePinCalls, 1);
    expect(client.logoutCalls, 0);
    expect(controller.status, AuthenticationStatus.locked);
    expect(memory.accessToken, isNull);
  });

  test('definitive PIN rejection keeps session; uncertain transport locks', () async {
    final client = FakeAuthClient();
    final memory = MemoryAuthenticationSession();
    final controller = AuthenticationController(
      client: client,
      sessionMemory: memory,
      inactivityScheduler: FakeScheduler(),
    );
    await controller.login('operator-1', '80421637');
    client.changePinFailure = const PosCoreServerFailure(
      code: 'credential_change_failed',
      message: 'PIN change was not completed.',
      statusCode: 403,
    );
    expect(await controller.changePin('wrong', '48295173'),
        PinChangeOutcome.credentialRejected);
    expect(memory.accessToken, testToken);
    client.changePinFailure = const PosCoreTransportFailure('Lost response.');
    expect(await controller.changePin('80421637', '48295173'),
        PinChangeOutcome.uncertain);
    expect(memory.accessToken, isNull);
    expect(controller.status, AuthenticationStatus.locked);
  });
  test(
    'login keeps the bearer only in process memory and schedules five minutes',
    () async {
      final client = FakeAuthClient();
      final memory = MemoryAuthenticationSession();
      final scheduler = FakeScheduler();
      final controller = AuthenticationController(
        client: client,
        sessionMemory: memory,
        inactivityScheduler: scheduler,
      );

      await controller.login('operator-1', '80421637');

      expect(controller.status, AuthenticationStatus.authenticated);
      expect(controller.session, testSession);
      expect(memory.accessToken, testToken);
      expect(scheduler.duration, registerPresentationInactivityTimeout);
      expect(scheduler.schedules, 1);
    },
  );

  test(
    'manual lock clears token before best-effort logout completes',
    () async {
      final logoutCompleter = Completer<void>();
      final client = FakeAuthClient(logoutCompleter: logoutCompleter);
      final memory = MemoryAuthenticationSession()
        ..establish(
          const AuthenticationLogin(
            accessToken: testToken,
            session: testSession,
          ),
        );
      final controller = AuthenticationController(
        client: client,
        sessionMemory: memory,
        inactivityScheduler: FakeScheduler(),
      );

      final locking = controller.lock();
      expect(controller.status, AuthenticationStatus.locked);
      expect(memory.accessToken, isNull);
      expect(client.logoutCalls, 1);
      expect(client.logoutToken, testToken);
      logoutCompleter.complete();
      await locking;
    },
  );

  test('logout failure cannot unlock or restore the captured token', () async {
    final client = FakeAuthClient(
      logoutFailure: const PosCoreTransportFailure('Connection refused.'),
    );
    final memory = MemoryAuthenticationSession()
      ..establish(
        const AuthenticationLogin(accessToken: testToken, session: testSession),
      );
    final controller = AuthenticationController(
      client: client,
      sessionMemory: memory,
      inactivityScheduler: FakeScheduler(),
    );

    await controller.lock();

    expect(controller.status, AuthenticationStatus.locked);
    expect(memory.accessToken, isNull);
    expect(client.logoutCalls, 1);
    expect(client.logoutToken, testToken);
  });

  test(
    'inactivity locks and activity reschedules without wall-clock waits',
    () async {
      final scheduler = FakeScheduler();
      final memory = MemoryAuthenticationSession();
      final controller = AuthenticationController(
        client: FakeAuthClient(),
        sessionMemory: memory,
        inactivityScheduler: scheduler,
      );
      await controller.login('operator-1', '80421637');
      controller.recordUserActivity();
      expect(scheduler.schedules, 2);

      scheduler.fire();
      await Future<void>.delayed(Duration.zero);

      expect(controller.status, AuthenticationStatus.locked);
      expect(memory.authenticated, isFalse);
    },
  );

  test(
    'definitive invalidation locks while transient 503 preserves distinction',
    () async {
      final memory = MemoryAuthenticationSession();
      final controller = AuthenticationController(
        client: FakeAuthClient(),
        sessionMemory: memory,
        inactivityScheduler: FakeScheduler(),
      );
      await controller.login('operator-1', '80421637');
      memory.clear();
      expect(controller.status, AuthenticationStatus.locked);

      final unavailable = AuthenticationController(
        client: FakeAuthClient(
          loginFailure: const PosCoreServerFailure(
            code: 'authentication_unavailable',
            message: 'Temporarily unavailable.',
            statusCode: 503,
          ),
        ),
        sessionMemory: MemoryAuthenticationSession(),
        inactivityScheduler: FakeScheduler(),
      );
      await unavailable.login('operator-1', '80421637');
      expect(unavailable.status, AuthenticationStatus.coreUnavailable);
    },
  );

  test('controller reconstruction never restores bearer capability', () async {
    final firstMemory = MemoryAuthenticationSession();
    final first = AuthenticationController(
      client: FakeAuthClient(),
      sessionMemory: firstMemory,
      inactivityScheduler: FakeScheduler(),
    );
    await first.login('operator-1', '80421637');
    expect(firstMemory.accessToken, testToken);

    final reconstructedMemory = MemoryAuthenticationSession();
    final reconstructed = AuthenticationController(
      client: FakeAuthClient(),
      sessionMemory: reconstructedMemory,
      inactivityScheduler: FakeScheduler(),
    );
    expect(reconstructed.status, AuthenticationStatus.locked);
    expect(reconstructedMemory.accessToken, isNull);
  });

  test('refreshed server permissions notify authenticated presentation', () async {
    final memory = MemoryAuthenticationSession();
    final controller = AuthenticationController(
      client: FakeAuthClient(),
      sessionMemory: memory,
      inactivityScheduler: FakeScheduler(),
    );
    await controller.login('operator-1', '80421637');
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    memory.updateSession(
      const AuthenticatedOperatorSession(
        operatorId: 'operator-1',
        displayName: 'Operator One',
        role: 'supervisor',
        permissions: <OperatorPermission>{
          OperatorPermission.registerRead,
          OperatorPermission.transactionReadAny,
        },
        idleTimeoutSeconds: 300,
        absoluteExpiresAtEpochMs: 9999999999999,
      ),
    );

    expect(notifications, 1);
    expect(controller.session?.role, 'supervisor');
    expect(
      controller.session?.permits(OperatorPermission.transactionReadAny),
      isTrue,
    );
  });
}
