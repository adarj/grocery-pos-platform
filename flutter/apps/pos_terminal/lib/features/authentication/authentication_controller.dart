import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/pos_core/authentication_client.dart';
import '../../core/pos_core/models/authentication.dart';
import '../../core/pos_core/models/pos_core_failure.dart';

const registerPresentationInactivityTimeout = Duration(minutes: 5);

enum AuthenticationStatus {
  locked,
  authenticating,
  authenticated,
  authenticationFailed,
  coreUnavailable,
}

abstract interface class AuthenticationInactivityScheduler {
  void schedule(Duration duration, void Function() callback);
  void cancel();
}

final class TimerAuthenticationInactivityScheduler
    implements AuthenticationInactivityScheduler {
  Timer? _timer;

  @override
  void schedule(Duration duration, void Function() callback) {
    _timer?.cancel();
    _timer = Timer(duration, callback);
  }

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}

final class AuthenticationController extends ChangeNotifier {
  AuthenticationController({
    required PosAuthenticationClient client,
    required MemoryAuthenticationSession sessionMemory,
    AuthenticationInactivityScheduler? inactivityScheduler,
  }) : _client = client,
       _sessionMemory = sessionMemory,
       _inactivityScheduler =
           inactivityScheduler ?? TimerAuthenticationInactivityScheduler() {
    _sessionMemory.addListener(_handleSessionMemoryChanged);
    if (_sessionMemory.authenticated) {
      _status = AuthenticationStatus.authenticated;
      _scheduleInactivityLock();
    }
  }

  final PosAuthenticationClient _client;
  final MemoryAuthenticationSession _sessionMemory;
  final AuthenticationInactivityScheduler _inactivityScheduler;

  AuthenticationStatus _status = AuthenticationStatus.locked;
  AuthenticationStatus get status => _status;
  bool get authenticated => _status == AuthenticationStatus.authenticated;
  AuthenticatedOperatorSession? get session => _sessionMemory.session;

  Future<void> login(String operatorId, String pin) async {
    if (_status == AuthenticationStatus.authenticating) return;
    _status = AuthenticationStatus.authenticating;
    notifyListeners();
    try {
      final login = await _client.login(operatorId, pin);
      _sessionMemory.establish(login);
      _status = AuthenticationStatus.authenticated;
      _scheduleInactivityLock();
    } on PosCoreServerFailure catch (failure) {
      _sessionMemory.clear();
      _status =
          failure.statusCode == 401 && failure.code == 'authentication_failed'
          ? AuthenticationStatus.authenticationFailed
          : AuthenticationStatus.coreUnavailable;
    } on PosCoreFailure {
      _sessionMemory.clear();
      _status = AuthenticationStatus.coreUnavailable;
    }
    notifyListeners();
  }

  Future<void> lock() async {
    final accessToken = _sessionMemory.accessToken;
    _inactivityScheduler.cancel();
    _status = AuthenticationStatus.locked;
    _sessionMemory.clear();
    notifyListeners();
    if (accessToken == null) return;
    try {
      await _client.logout(accessToken);
    } on Object {
      // Local presentation locks immediately. The unretained server token is
      // bounded by server expiry and process-restart invalidation.
    }
  }

  void recordUserActivity() {
    if (authenticated) _scheduleInactivityLock();
  }

  void _scheduleInactivityLock() {
    _inactivityScheduler.schedule(
      registerPresentationInactivityTimeout,
      () => unawaited(lock()),
    );
  }

  void _handleSessionMemoryChanged() {
    if (!_sessionMemory.authenticated && authenticated) {
      _inactivityScheduler.cancel();
      _status = AuthenticationStatus.locked;
      notifyListeners();
    } else if (_sessionMemory.authenticated && authenticated) {
      // A deliberate /auth/session refresh may change the current role and
      // server-computed presentation permissions without replacing the bearer
      // capability. Rebuild authenticated presentation from that safe state.
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sessionMemory.removeListener(_handleSessionMemoryChanged);
    _inactivityScheduler.cancel();
    _sessionMemory.clear();
    super.dispose();
  }
}
