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

enum PinChangeOutcome {
  changed,
  policyRejected,
  credentialRejected,
  unavailable,
  uncertain,
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
  String? _lockMessage;
  AuthenticationStatus get status => _status;
  String? get lockMessage => _lockMessage;
  bool get authenticated => _status == AuthenticationStatus.authenticated;
  AuthenticatedOperatorSession? get session => _sessionMemory.session;

  Future<void> login(String operatorId, String pin) async {
    if (_status == AuthenticationStatus.authenticating) return;
    _status = AuthenticationStatus.authenticating;
    _lockMessage = null;
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
    _lockMessage = null;
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

  Future<PinChangeOutcome> changePin(String currentPin, String newPin) async {
    if (!authenticated) return PinChangeOutcome.uncertain;
    try {
      await _client.changePin(currentPin, newPin);
      // The server invalidates the bearer before returning success. This is
      // a local presentation reset, not an ordinary logout attempt.
      _lockMessage = 'PIN changed. Sign in again with your new PIN.';
      _lockLocally();
      return PinChangeOutcome.changed;
    } on PosCoreServerFailure catch (failure) {
      if (failure.statusCode == 400 &&
          failure.code == 'pin_policy_rejected') {
        return PinChangeOutcome.policyRejected;
      }
      if (failure.statusCode == 403 &&
          failure.code == 'credential_change_failed') {
        return PinChangeOutcome.credentialRejected;
      }
      if (failure.statusCode == 503 &&
          failure.code == 'credential_change_unavailable') {
        return PinChangeOutcome.unavailable;
      }
      _lockLocally();
      return PinChangeOutcome.uncertain;
    } on PosCoreFailure {
      // A lost response may hide a committed change. Never resend blindly.
      _lockMessage = 'PIN change outcome is uncertain. Sign in again.';
      _lockLocally();
      return PinChangeOutcome.uncertain;
    }
  }

  void _lockLocally() {
    _inactivityScheduler.cancel();
    _status = AuthenticationStatus.locked;
    _sessionMemory.clear();
    notifyListeners();
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
