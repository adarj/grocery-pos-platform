import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models/command_result.dart';
import 'authentication_client.dart';
import 'models/authentication.dart';
import 'models/canonical_receipt.dart';
import 'models/json_fields.dart';
import 'models/pos_core_failure.dart';
import 'models/pos_core_health.dart';
import 'models/pos_core_readiness.dart';
import 'models/register_operations.dart';
import 'models/transaction_command.dart';
import 'models/transaction_snapshot.dart';
import 'pos_core_client.dart';

final class HttpPosCoreClient
    implements PosCoreClient, PosAuthenticationClient {
  HttpPosCoreClient({
    required this.baseUri,
    http.Client? httpClient,
    MemoryAuthenticationSession? authenticationSession,
    this.timeout = const Duration(seconds: 3),
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       authenticationSession =
           authenticationSession ?? MemoryAuthenticationSession();

  final Uri baseUri;
  final Duration timeout;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final MemoryAuthenticationSession authenticationSession;

  @override
  Future<PosCoreHealth> fetchHealth() async {
    final response = await _get(
      baseUri.resolve('/health'),
      authenticated: false,
    );
    final body = _decodeObject(response);

    if (response.statusCode != 200) {
      throw _serverFailureFrom(body, response.statusCode);
    }

    return PosCoreHealth.fromJson(body);
  }

  @override
  Future<PosCoreReadiness> fetchReadiness() async {
    final response = await _get(
      baseUri.resolve('/ready'),
      authenticated: false,
    );
    final body = _decodeObject(response);

    if (response.statusCode == 200 || response.statusCode == 503) {
      final readiness = PosCoreReadiness.fromJson(body);
      if ((response.statusCode == 200) != readiness.ready) {
        throw const PosCoreInvalidResponseFailure(
          'POS Core readiness HTTP status and state disagree.',
        );
      }
      return readiness;
    }

    if (body.containsKey('error')) {
      throw _serverFailureFrom(body, response.statusCode);
    }
    throw const PosCoreInvalidResponseFailure(
      'POS Core readiness response has an unsupported HTTP status.',
    );
  }

  @override
  Future<PosCommandResult> executeCommand(TransactionCommand command) async {
    final response = await _postCommand(command);
    try {
      final body = _decodeObject(response);
      final ok = requireJsonBool(body, 'ok', 'transaction command response');

      if (body.containsKey('command_result')) {
        final result = PosCommandResult.fromJson(
          expectJsonObject(
            body['command_result'],
            'transaction command response command_result',
          ),
        );
        if (result.commandId != command.commandId ||
            result.transactionId != command.transactionId) {
          throw const PosCoreInvalidResponseFailure(
            'Transaction command result identity does not match the request.',
          );
        }
        _validateCommandResultEnvelope(response.statusCode, ok, result);
        return result;
      }

      if (body.containsKey('error')) {
        if (ok) {
          throw const PosCoreInvalidResponseFailure(
            'A transaction command error response cannot have ok=true.',
          );
        }
        throw _serverFailureFrom(
          body,
          response.statusCode,
          preserveRetrySameCommandId: true,
        );
      }

      throw const PosCoreInvalidResponseFailure(
        'Transaction command response has neither command_result nor error.',
      );
    } on PosCoreInvalidResponseFailure catch (failure) {
      throw PosCoreInvalidResponseFailure(
        failure.message,
        retrySameCommandId: true,
      );
    }
  }

  @override
  Future<TransactionSnapshot> fetchTransaction(String transactionId) async {
    if (transactionId.isEmpty) {
      throw ArgumentError.value(
        transactionId,
        'transactionId',
        'must not be empty',
      );
    }

    final encodedId = Uri.encodeComponent(transactionId);
    final response = await _get(baseUri.resolve('/transactions/$encodedId'));
    final body = _decodeObject(response);
    final ok = requireJsonBool(body, 'ok', 'transaction query response');

    if (response.statusCode == 200 && body.containsKey('transaction')) {
      if (!ok) {
        throw const PosCoreInvalidResponseFailure(
          'A successful transaction query response must have ok=true.',
        );
      }
      final snapshot = TransactionSnapshot.fromJson(
        expectJsonObject(
          body['transaction'],
          'transaction query response transaction',
        ),
      );
      if (snapshot.transactionId != transactionId) {
        throw const PosCoreInvalidResponseFailure(
          'Transaction response identity does not match the request.',
        );
      }
      return snapshot;
    }

    if (body.containsKey('error')) {
      if (ok) {
        throw const PosCoreInvalidResponseFailure(
          'A transaction query error response cannot have ok=true.',
        );
      }
      throw _serverFailureFrom(body, response.statusCode);
    }

    throw const PosCoreInvalidResponseFailure(
      'Transaction query response has neither transaction nor error.',
    );
  }

  @override
  Future<CanonicalReceipt> fetchReceipt(String transactionId) async {
    if (transactionId.isEmpty) {
      throw ArgumentError.value(
        transactionId,
        'transactionId',
        'must not be empty',
      );
    }

    final encodedId = Uri.encodeComponent(transactionId);
    final response = await _get(baseUri.resolve('/receipts/$encodedId'));
    final body = _decodeObject(response);
    final ok = requireJsonBool(body, 'ok', 'receipt query response');

    if (response.statusCode == 200 && body.containsKey('receipt')) {
      if (!ok) {
        throw const PosCoreInvalidResponseFailure(
          'A successful receipt query response must have ok=true.',
        );
      }
      final receipt = CanonicalReceipt.fromJson(
        expectJsonObject(body['receipt'], 'receipt query response receipt'),
      );
      if (receipt.transactionId != transactionId) {
        throw const PosCoreInvalidResponseFailure(
          'Receipt response identity does not match the request.',
        );
      }
      return receipt;
    }

    if (body.containsKey('error')) {
      if (ok) {
        throw const PosCoreInvalidResponseFailure(
          'A receipt query error response cannot have ok=true.',
        );
      }
      throw _serverFailureFrom(body, response.statusCode);
    }

    throw const PosCoreInvalidResponseFailure(
      'Receipt query response has neither receipt nor error.',
    );
  }

  @override
  Future<RegisterContext> fetchRegisterContext() async {
    final body = await _successfulQueryObject(
      await _get(baseUri.resolve('/register-context')),
      'register context response',
    );
    return RegisterContext.fromJson(
      expectJsonObject(
        requireJsonField(body, 'register_context', 'register context response'),
        'register context response register_context',
      ),
    );
  }

  @override
  Future<List<CashierIdentity>> fetchActiveCashiers() async {
    final body = await _successfulQueryObject(
      await _get(baseUri.resolve('/cashiers')),
      'cashier list response',
    );
    return List.unmodifiable(
      requireJsonList(body, 'cashiers', 'cashier list response').map(
        (value) => CashierIdentity.fromJson(
          expectJsonObject(value, 'cashier list entry'),
        ),
      ),
    );
  }

  @override
  Future<ShiftOperationResult> openShift(int openingCashMinorUnits) async {
    if (openingCashMinorUnits < 0) {
      throw ArgumentError.value(
        openingCashMinorUnits,
        'openingCashMinorUnits',
        'must be nonnegative',
      );
    }
    return _operationalShiftWrite('/shifts/open', <String, Object?>{
      'opening_cash_minor_units': openingCashMinorUnits,
    });
  }

  @override
  Future<ShiftOperationResult> closeShift(
    String shiftId,
    int countedCashMinorUnits,
  ) async {
    if (shiftId.isEmpty) {
      throw ArgumentError.value(shiftId, 'shiftId', 'must not be empty');
    }
    if (countedCashMinorUnits < 0) {
      throw ArgumentError.value(
        countedCashMinorUnits,
        'countedCashMinorUnits',
        'must be nonnegative',
      );
    }
    return _operationalShiftWrite(
      '/shifts/${Uri.encodeComponent(shiftId)}/close',
      <String, Object?>{'counted_cash_minor_units': countedCashMinorUnits},
    );
  }

  @override
  Future<ShiftCashSummary> fetchShiftCashSummary(String shiftId) async {
    if (shiftId.isEmpty) {
      throw ArgumentError.value(shiftId, 'shiftId', 'must not be empty');
    }
    final body = await _successfulQueryObject(
      await _get(
        baseUri.resolve('/shifts/${Uri.encodeComponent(shiftId)}/cash-summary'),
      ),
      'shift cash summary response',
    );
    final summary = ShiftCashSummary.fromJson(
      expectJsonObject(
        requireJsonField(body, 'cash_summary', 'shift cash summary response'),
        'shift cash summary response cash_summary',
      ),
    );
    if (summary.shiftId != shiftId) {
      throw const PosCoreInvalidResponseFailure(
        'Shift cash summary identity does not match the request.',
      );
    }
    return summary;
  }

  @override
  Future<AuthenticationLogin> login(String operatorId, String pin) async {
    final response = await _postJson(
      baseUri.resolve('/auth/login'),
      <String, Object?>{'operator_id': operatorId, 'pin': pin},
      authenticated: false,
    );
    final body = _decodeObject(response);
    if (response.statusCode == 200 &&
        requireJsonBool(body, 'ok', 'login response')) {
      final token = requireJsonString(
        body,
        'access_token',
        'login response',
        nonEmpty: true,
      );
      if (requireJsonString(body, 'token_type', 'login response') != 'Bearer') {
        throw const PosCoreInvalidResponseFailure(
          'POS Core login token type is unsupported.',
        );
      }
      final session = AuthenticatedOperatorSession.fromJson(
        expectJsonObject(body['session'], 'login response session'),
      );
      return AuthenticationLogin(accessToken: token, session: session);
    }
    if (body.containsKey('error')) {
      throw _serverFailureFrom(body, response.statusCode);
    }
    throw const PosCoreInvalidResponseFailure(
      'POS Core login response is inconsistent.',
    );
  }

  @override
  Future<AuthenticatedOperatorSession> fetchAuthenticatedSession() async {
    final body = await _successfulQueryObject(
      await _get(baseUri.resolve('/auth/session')),
      'authenticated session response',
    );
    final session = AuthenticatedOperatorSession.fromJson(
      expectJsonObject(
        body['session'],
        'authenticated session response session',
      ),
    );
    authenticationSession.updateSession(session);
    return session;
  }

  @override
  Future<void> logout(String accessToken) async {
    final response = await _postJson(
      baseUri.resolve('/auth/logout'),
      const <String, Object?>{},
      tokenOverride: accessToken,
      includeBody: false,
    );
    final body = _decodeObject(response);
    if (response.statusCode == 200 &&
        requireJsonBool(body, 'ok', 'logout response')) {
      return;
    }
    if (body.containsKey('error')) {
      throw _serverFailureFrom(body, response.statusCode);
    }
    throw const PosCoreInvalidResponseFailure(
      'POS Core logout response is inconsistent.',
    );
  }

  void close() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }

  Future<http.Response> _get(Uri uri, {bool authenticated = true}) async {
    try {
      return await _httpClient
          .get(uri, headers: _requestHeaders(authenticated: authenticated))
          .timeout(timeout);
    } on Exception {
      throw const PosCoreTransportFailure('Unable to reach POS Core.');
    }
  }

  Future<http.Response> _postReadRecoverable(
    Uri uri,
    Map<String, Object?> body,
  ) async {
    try {
      return await _postJson(uri, body);
    } on Exception {
      throw const PosCoreTransportFailure('Unable to reach POS Core.');
    }
  }

  Future<Map<String, Object?>> _successfulQueryObject(
    http.Response response,
    String context,
  ) async {
    final body = _decodeObject(response);
    final ok = requireJsonBool(body, 'ok', context);
    if (response.statusCode == 200 && ok) {
      return body;
    }
    if (body.containsKey('error') && !ok) {
      throw _serverFailureFrom(body, response.statusCode);
    }
    throw PosCoreInvalidResponseFailure('$context is inconsistent.');
  }

  Future<ShiftOperationResult> _operationalShiftWrite(
    String path,
    Map<String, Object?> requestBody,
  ) async {
    final body = await _successfulQueryObject(
      await _postReadRecoverable(baseUri.resolve(path), requestBody),
      'shift operation response',
    );
    return ShiftOperationResult.fromJson(body);
  }

  Future<http.Response> _postCommand(TransactionCommand command) async {
    try {
      return await _httpClient
          .post(
            baseUri.resolve('/transaction-commands'),
            headers: _requestHeaders(json: true),
            body: jsonEncode(command.toJson()),
          )
          .timeout(timeout);
    } on Exception {
      throw const PosCoreTransportFailure(
        'The transaction command outcome could not be confirmed. '
        'Retry using the same command ID.',
        retrySameCommandId: true,
      );
    }
  }

  Future<http.Response> _postJson(
    Uri uri,
    Map<String, Object?> body, {
    bool authenticated = true,
    String? tokenOverride,
    bool includeBody = true,
  }) async {
    try {
      return await _httpClient
          .post(
            uri,
            headers: _requestHeaders(
              json: includeBody,
              authenticated: authenticated,
              tokenOverride: tokenOverride,
            ),
            body: includeBody ? jsonEncode(body) : null,
          )
          .timeout(timeout);
    } on Exception {
      throw const PosCoreTransportFailure('Unable to reach POS Core.');
    }
  }

  Map<String, String> _requestHeaders({
    bool json = false,
    bool authenticated = true,
    String? tokenOverride,
  }) {
    final headers = <String, String>{
      if (json) 'Content-Type': 'application/json',
    };
    final token =
        tokenOverride ??
        (authenticated ? authenticationSession.accessToken : null);
    if (token != null) headers['Authorization'] = 'Bearer $token';
    return headers;
  }

  Map<String, Object?> _decodeObject(http.Response response) {
    try {
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: false),
      );
      return expectJsonObject(decoded, 'POS Core response');
    } on PosCoreInvalidResponseFailure {
      rethrow;
    } on FormatException {
      throw const PosCoreInvalidResponseFailure(
        'POS Core returned malformed JSON.',
      );
    }
  }

  PosCoreServerFailure _serverFailureFrom(
    Map<String, Object?> body,
    int statusCode, {
    bool preserveRetrySameCommandId = false,
  }) {
    final error = expectJsonObject(
      requireJsonField(body, 'error', 'POS Core error response'),
      'POS Core error response error',
    );
    const context = 'POS Core error';
    final reason = error.containsKey('reason')
        ? requireJsonString(error, 'reason', context, nonEmpty: true)
        : null;
    final authenticationRejectedBeforeCommand =
        preserveRetrySameCommandId &&
        statusCode == 401 &&
        error['code'] == 'authentication_required';
    final retrySameCommandId = authenticationRejectedBeforeCommand
        ? true
        : preserveRetrySameCommandId &&
              error.containsKey('retry_same_command_id')
        ? requireJsonBool(error, 'retry_same_command_id', context)
        : false;

    final failure = PosCoreServerFailure(
      code: requireJsonString(error, 'code', context, nonEmpty: true),
      message: requireJsonString(error, 'message', context, nonEmpty: true),
      reason: reason,
      statusCode: statusCode,
      retrySameCommandId: retrySameCommandId,
    );
    if (statusCode == 401 && failure.code == 'authentication_required') {
      authenticationSession.clear();
    }
    return failure;
  }

  void _validateCommandResultEnvelope(
    int statusCode,
    bool ok,
    PosCommandResult result,
  ) {
    final expectedStatus = switch (result.outcomeKind) {
      PosCommandOutcomeKind.accepted => 200,
      PosCommandOutcomeKind.notFound => 404,
      PosCommandOutcomeKind.domainRejected ||
      PosCommandOutcomeKind.alreadyExists ||
      PosCommandOutcomeKind.versionConflict => 409,
    };
    if (statusCode != expectedStatus || ok != result.accepted) {
      throw const PosCoreInvalidResponseFailure(
        'Transaction command HTTP status, ok flag, and outcome disagree.',
      );
    }
  }
}
