import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_terminal/core/pos_core/http_pos_core_client.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_command.dart';
import 'package:pos_terminal/core/pos_core/models/transaction_snapshot.dart';

void main() {
  final baseUri = Uri.parse('http://127.0.0.1:7340');
  final startCommand = StartTransactionCommand(
    commandId: 'cmd-start',
    transactionId: 'txn-001',
    expectedVersion: 0,
  );

  String jsonBody(Object value) => jsonEncode(value);

  Map<String, Object?> commandEnvelope({
    String kind = 'accepted',
    String code = 'accepted',
    int version = 1,
  }) => {
    'ok': kind == 'accepted',
    'command_result': {
      'command_id': 'cmd-start',
      'transaction_id': 'txn-001',
      'outcome_kind': kind,
      'outcome_code': code,
      'outcome_stream_version': version,
    },
  };

  Map<String, Object?> transactionEnvelope() => {
    'ok': true,
    'transaction': {
      'transaction_id': 'txn/opaque value?',
      'version': 1,
      'status': 'open',
      'line_items': <Object?>[],
      'subtotal_minor_units': 0,
      'total_minor_units': 0,
      'tendered_cash_minor_units': null,
      'change_due_minor_units': null,
    },
  };

  test(
    'fetchHealth uses the health route and parses its strict model',
    () async {
      final client = HttpPosCoreClient(
        baseUri: baseUri,
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.toString(), 'http://127.0.0.1:7340/health');
          return http.Response(
            jsonBody({
              'ok': true,
              'service': 'grocery-pos-core',
              'version': '0.0.0-dev',
              'environment': 'dev',
            }),
            200,
          );
        }),
      );

      final health = await client.fetchHealth();
      expect(health.ok, isTrue);
      expect(health.service, 'grocery-pos-core');
    },
  );

  test('executeCommand sends one exact JSON command POST', () async {
    var requests = 0;
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient((request) async {
        requests += 1;
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'http://127.0.0.1:7340/transaction-commands',
        );
        expect(request.headers['content-type'], 'application/json');
        expect(jsonDecode(request.body), startCommand.toJson());
        return http.Response(jsonBody(commandEnvelope()), 200);
      }),
    );

    final result = await client.executeCommand(startCommand);
    expect(result.outcomeKind, PosCommandOutcomeKind.accepted);
    expect(requests, 1);
  });

  test(
    'documented 409 and 404 command outcomes remain durable results',
    () async {
      for (final testCase in [
        (409, 'domain_rejected', 'invalid_transaction_state'),
        (409, 'already_exists', 'transaction_already_exists'),
        (409, 'version_conflict', 'stale_expected_version'),
        (404, 'not_found', 'transaction_not_found'),
      ]) {
        final client = HttpPosCoreClient(
          baseUri: baseUri,
          httpClient: MockClient(
            (_) async => http.Response(
              jsonBody(commandEnvelope(kind: testCase.$2, code: testCase.$3)),
              testCase.$1,
            ),
          ),
        );

        final result = await client.executeCommand(startCommand);
        expect(result.outcomeCode, testCase.$3);
        expect(result.outcomeStreamVersion, 1);
      }
    },
  );

  test('structured command errors preserve retry metadata', () async {
    for (final code in [
      'command_id_reused',
      'command_outcome_unknown',
      'command_persistence_failed',
    ]) {
      final retrySameId = code != 'command_id_reused';
      final client = HttpPosCoreClient(
        baseUri: baseUri,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonBody({
              'ok': false,
              'error': {
                'code': code,
                'message': 'Safe server message.',
                if (retrySameId) 'retry_same_command_id': true,
              },
            }),
            code == 'command_id_reused' ? 409 : 500,
          ),
        ),
      );

      await expectLater(
        client.executeCommand(startCommand),
        throwsA(
          isA<PosCoreServerFailure>()
              .having((failure) => failure.code, 'code', code)
              .having(
                (failure) => failure.retrySameCommandId,
                'retrySameCommandId',
                retrySameId,
              ),
        ),
      );
    }
  });

  test(
    'command transport failure is uncertain and never auto-retried',
    () async {
      var requests = 0;
      final client = HttpPosCoreClient(
        baseUri: baseUri,
        httpClient: MockClient((_) async {
          requests += 1;
          throw http.ClientException('socket closed after send');
        }),
      );

      await expectLater(
        client.executeCommand(startCommand),
        throwsA(
          isA<PosCoreTransportFailure>().having(
            (failure) => failure.retrySameCommandId,
            'retrySameCommandId',
            isTrue,
          ),
        ),
      );
      expect(requests, 1);
    },
  );

  test('malformed command response becomes invalidResponse', () async {
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient((_) async => http.Response('{', 200)),
    );

    await expectLater(
      client.executeCommand(startCommand),
      throwsA(
        isA<PosCoreInvalidResponseFailure>().having(
          (failure) => failure.retrySameCommandId,
          'retrySameCommandId',
          isTrue,
        ),
      ),
    );
  });

  test('command response for another command fails as uncertain', () async {
    final commandResult = Map<String, Object?>.from(
      commandEnvelope()['command_result']! as Map<String, Object?>,
    )..['command_id'] = 'cmd-other';
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient(
        (_) async => http.Response(
          jsonBody({'ok': true, 'command_result': commandResult}),
          200,
        ),
      ),
    );

    await expectLater(
      client.executeCommand(startCommand),
      throwsA(
        isA<PosCoreInvalidResponseFailure>().having(
          (failure) => failure.retrySameCommandId,
          'retrySameCommandId',
          isTrue,
        ),
      ),
    );
  });

  test(
    'fetchTransaction encodes opaque ID and parses authoritative state',
    () async {
      final client = HttpPosCoreClient(
        baseUri: baseUri,
        httpClient: MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url.toString(),
            'http://127.0.0.1:7340/transactions/txn%2Fopaque%20value%3F',
          );
          return http.Response(jsonBody(transactionEnvelope()), 200);
        }),
      );

      final snapshot = await client.fetchTransaction('txn/opaque value?');
      expect(snapshot.status, TransactionStatus.open);
      expect(snapshot.version, 1);
    },
  );

  test(
    'transaction 404 is a server failure without mutation retry semantics',
    () async {
      final client = HttpPosCoreClient(
        baseUri: baseUri,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonBody({
              'ok': false,
              'error': {
                'code': 'transaction_not_found',
                'message': 'Transaction not found.',
                'retry_same_command_id': true,
              },
            }),
            404,
          ),
        ),
      );

      await expectLater(
        client.fetchTransaction('txn-missing'),
        throwsA(
          isA<PosCoreServerFailure>()
              .having(
                (failure) => failure.code,
                'code',
                'transaction_not_found',
              )
              .having(
                (failure) => failure.retrySameCommandId,
                'retrySameCommandId',
                isFalse,
              ),
        ),
      );
    },
  );

  test('transaction response for another ID fails closed', () async {
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient(
        (_) async => http.Response(jsonBody(transactionEnvelope()), 200),
      ),
    );

    await expectLater(
      client.fetchTransaction('txn-requested'),
      throwsA(
        isA<PosCoreInvalidResponseFailure>().having(
          (failure) => failure.retrySameCommandId,
          'retrySameCommandId',
          isFalse,
        ),
      ),
    );
  });
}
