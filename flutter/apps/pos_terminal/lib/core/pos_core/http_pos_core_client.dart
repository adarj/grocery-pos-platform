import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models/command_result.dart';
import 'models/canonical_receipt.dart';
import 'models/json_fields.dart';
import 'models/pos_core_failure.dart';
import 'models/pos_core_health.dart';
import 'models/transaction_command.dart';
import 'models/transaction_snapshot.dart';
import 'pos_core_client.dart';

final class HttpPosCoreClient implements PosCoreClient {
  HttpPosCoreClient({
    required this.baseUri,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 3),
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  final Uri baseUri;
  final Duration timeout;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  @override
  Future<PosCoreHealth> fetchHealth() async {
    final response = await _get(baseUri.resolve('/health'));
    final body = _decodeObject(response);

    if (response.statusCode != 200) {
      throw _serverFailureFrom(body, response.statusCode);
    }

    return PosCoreHealth.fromJson(body);
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

  void close() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }

  Future<http.Response> _get(Uri uri) async {
    try {
      return await _httpClient.get(uri).timeout(timeout);
    } on Exception {
      throw const PosCoreTransportFailure('Unable to reach POS Core.');
    }
  }

  Future<http.Response> _postCommand(TransactionCommand command) async {
    try {
      return await _httpClient
          .post(
            baseUri.resolve('/transaction-commands'),
            headers: const {'Content-Type': 'application/json'},
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
    final retrySameCommandId =
        preserveRetrySameCommandId && error.containsKey('retry_same_command_id')
        ? requireJsonBool(error, 'retry_same_command_id', context)
        : false;

    return PosCoreServerFailure(
      code: requireJsonString(error, 'code', context, nonEmpty: true),
      message: requireJsonString(error, 'message', context, nonEmpty: true),
      reason: reason,
      statusCode: statusCode,
      retrySameCommandId: retrySameCommandId,
    );
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
