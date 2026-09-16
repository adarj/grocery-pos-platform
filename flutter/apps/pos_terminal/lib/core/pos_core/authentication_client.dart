import 'models/authentication.dart';

abstract interface class PosAuthenticationClient {
  Future<AuthenticationLogin> login(String operatorId, String pin);

  Future<AuthenticatedOperatorSession> fetchAuthenticatedSession();

  Future<void> logout(String accessToken);
}

final class MemoryAuthenticationSession {
  String? _accessToken;
  AuthenticatedOperatorSession? _session;
  final List<void Function()> _listeners = [];

  String? get accessToken => _accessToken;
  AuthenticatedOperatorSession? get session => _session;
  bool get authenticated => _accessToken != null && _session != null;

  void establish(AuthenticationLogin login) {
    _accessToken = login.accessToken;
    _session = login.session;
    _notifyListeners();
  }

  void updateSession(AuthenticatedOperatorSession session) {
    if (_accessToken == null) return;
    _session = session;
    _notifyListeners();
  }

  void clear() {
    final changed = _accessToken != null || _session != null;
    _accessToken = null;
    _session = null;
    if (changed) _notifyListeners();
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notifyListeners() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
