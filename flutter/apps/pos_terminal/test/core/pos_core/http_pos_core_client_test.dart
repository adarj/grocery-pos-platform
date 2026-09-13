import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pos_terminal/core/pos_core/http_pos_core_client.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/canonical_receipt.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_readiness.dart';
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
      'tax_minor_units': 0,
      'total_minor_units': 0,
      'tendered_cash_minor_units': null,
      'change_due_minor_units': null,
    },
  };

  Map<String, Object?> receiptEnvelope() => {
    'ok': true,
    'receipt': {
      'schema_version': 1,
      'transaction_id': 'txn/opaque value?',
      'transaction_version': 4,
      'line_items': <Object?>[],
      'subtotal_minor_units': 199,
      'tax_minor_units': 777,
      'total_minor_units': 1234,
      'tendered_cash_minor_units': 2000,
      'change_due_minor_units': 999,
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

  test('fetchReadiness parses ready production state', () async {
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(), 'http://127.0.0.1:7340/ready');
        return http.Response(
          jsonBody({
            'ok': true,
            'service': 'grocery-pos-core',
            'status': 'ready',
            'database_schema_version': 6,
          }),
          200,
        );
      }),
    );

    final readiness = await client.fetchReadiness();
    expect(readiness.ready, isTrue);
    expect(readiness.databaseSchemaVersion, 6);
    expect(readiness.reason, isNull);
  });

  test('fetchReadiness models 503 as structured not-ready state', () async {
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient(
        (_) async => http.Response(
          jsonBody({
            'ok': false,
            'service': 'grocery-pos-core',
            'status': 'not_ready',
            'reason': 'database_unavailable',
          }),
          503,
        ),
      ),
    );

    final readiness = await client.fetchReadiness();
    expect(readiness.ready, isFalse);
    expect(readiness.databaseSchemaVersion, isNull);
    expect(readiness.reason, PosCoreReadinessReason.databaseUnavailable);
  });

  test('fetchReadiness rejects status and payload disagreement', () async {
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient(
        (_) async => http.Response(
          jsonBody({
            'ok': true,
            'service': 'grocery-pos-core',
            'status': 'ready',
            'database_schema_version': 6,
          }),
          503,
        ),
      ),
    );

    await expectLater(
      client.fetchReadiness(),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
  });

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

  test('fetchReceipt encodes exact ID and parses canonical receipt', () async {
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'http://127.0.0.1:7340/receipts/txn%2Fopaque%20value%3F',
        );
        return http.Response(jsonBody(receiptEnvelope()), 200);
      }),
    );

    final CanonicalReceipt receipt = await client.fetchReceipt(
      'txn/opaque value?',
    );
    expect(receipt.transactionId, 'txn/opaque value?');
    expect(receipt.transactionVersion, 4);
    expect(receipt.subtotalMinorUnits, 199);
    expect(receipt.taxMinorUnits, 777);
    expect(receipt.totalMinorUnits, 1234);
  });

  test('receipt query failures retain query-only retry semantics', () async {
    for (final testCase in [
      (404, 'transaction_not_found'),
      (409, 'receipt_not_available'),
    ]) {
      final client = HttpPosCoreClient(
        baseUri: baseUri,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonBody({
              'ok': false,
              'error': {
                'code': testCase.$2,
                if (testCase.$1 == 409) 'reason': 'transaction_not_completed',
                'message': 'Safe receipt query failure.',
                'retry_same_command_id': true,
              },
            }),
            testCase.$1,
          ),
        ),
      );

      await expectLater(
        client.fetchReceipt('txn-receipt'),
        throwsA(
          isA<PosCoreServerFailure>()
              .having((failure) => failure.code, 'code', testCase.$2)
              .having(
                (failure) => failure.retrySameCommandId,
                'retrySameCommandId',
                isFalse,
              ),
        ),
      );
    }
  });

  test('receipt transport failure has no command retry identity', () async {
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient(
        (_) async => throw http.ClientException('receipt connection lost'),
      ),
    );

    await expectLater(
      client.fetchReceipt('txn-receipt'),
      throwsA(
        isA<PosCoreTransportFailure>().having(
          (failure) => failure.retrySameCommandId,
          'retrySameCommandId',
          isFalse,
        ),
      ),
    );
  });

  test('receipt response for another ID fails closed', () async {
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient(
        (_) async => http.Response(jsonBody(receiptEnvelope()), 200),
      ),
    );

    await expectLater(
      client.fetchReceipt('txn-requested'),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
  });

  test('malformed receipt response fails closed', () async {
    final invalid = receiptEnvelope();
    final receipt = Map<String, Object?>.from(
      invalid['receipt']! as Map<String, Object?>,
    )..remove('total_minor_units');
    invalid['receipt'] = receipt;
    final client = HttpPosCoreClient(
      baseUri: baseUri,
      httpClient: MockClient(
        (_) async => http.Response(jsonBody(invalid), 200),
      ),
    );

    await expectLater(
      client.fetchReceipt('txn/opaque value?'),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
  });

  Map<String, Object?> shiftJson({int? closedAt}) => {
    'shift_id': 'shift/opaque',
    'register_id': 'register-one',
    'register_display_name': 'Front Register',
    'cashier_id': 'cashier-one',
    'cashier_display_name': 'Alice',
    'opened_at_epoch_ms': 1000,
    'closed_at_epoch_ms': closedAt,
    'active_transaction_id': null,
  };

  Map<String, Object?> cashSummaryJson({
    String status = 'open',
    int? counted,
    int? overShort,
  }) => {
    'shift_id': 'shift/opaque',
    'status': status,
    'opening_cash_minor_units': 10000,
    'completed_cash_sale_count': 1,
    'cash_sales_minor_units': 219,
    'expected_cash_minor_units': 10219,
    'counted_cash_minor_units': counted,
    'over_short_minor_units': overShort,
  };

  test(
    'register context and active cashier queries use typed GET routes',
    () async {
      var requestNumber = 0;
      final client = HttpPosCoreClient(
        baseUri: baseUri,
        httpClient: MockClient((request) async {
          requestNumber += 1;
          expect(request.method, 'GET');
          if (requestNumber == 1) {
            expect(request.url.path, '/register-context');
            return http.Response(
              jsonBody({
                'ok': true,
                'register_context': {
                  'configured': true,
                  'register': {
                    'register_id': 'register-one',
                    'display_name': 'Front Register',
                  },
                  'active_shift': null,
                },
              }),
              200,
            );
          }
          expect(request.url.path, '/cashiers');
          return http.Response(
            jsonBody({
              'ok': true,
              'cashiers': [
                {'cashier_id': 'cashier-one', 'display_name': 'Alice'},
              ],
            }),
            200,
          );
        }),
      );
      final context = await client.fetchRegisterContext();
      final cashiers = await client.fetchActiveCashiers();
      expect(context.register!.displayName, 'Front Register');
      expect(cashiers.single.cashierId, 'cashier-one');
    },
  );

  test(
    'open close and cash-summary use exact operational money payloads',
    () async {
      var requestNumber = 0;
      final client = HttpPosCoreClient(
        baseUri: baseUri,
        httpClient: MockClient((request) async {
          requestNumber += 1;
          if (requestNumber == 1) {
            expect(request.method, 'POST');
            expect(request.headers['content-type'], 'application/json');
            expect(request.url.path, '/shifts/open');
            expect(jsonDecode(request.body), {
              'cashier_id': 'cashier-one',
              'opening_cash_minor_units': 10000,
            });
            return http.Response(
              jsonBody({
                'ok': true,
                'shift': shiftJson(),
                'cash_summary': cashSummaryJson(),
              }),
              200,
            );
          }
          if (requestNumber == 2) {
            expect(request.method, 'POST');
            expect(request.headers['content-type'], 'application/json');
            expect(request.url.path, '/shifts/shift%2Fopaque/close');
            expect(jsonDecode(request.body), {
              'counted_cash_minor_units': 10194,
            });
            return http.Response(
              jsonBody({
                'ok': true,
                'shift': shiftJson(closedAt: 2000),
                'cash_summary': cashSummaryJson(
                  status: 'closed',
                  counted: 10194,
                  overShort: -25,
                ),
              }),
              200,
            );
          }
          expect(request.method, 'GET');
          expect(request.url.path, '/shifts/shift%2Fopaque/cash-summary');
          return http.Response(
            jsonBody({
              'ok': true,
              'cash_summary': cashSummaryJson(
                status: 'closed',
                counted: 10194,
                overShort: -25,
              ),
            }),
            200,
          );
        }),
      );
      final opened = await client.openShift('cashier-one', 10000);
      final closed = await client.closeShift(opened.shift.shiftId, 10194);
      final fetched = await client.fetchShiftCashSummary(opened.shift.shiftId);
      expect(opened.shift.closedAtEpochMs, isNull);
      expect(opened.cashSummary.openingCashMinorUnits, 10000);
      expect(closed.shift.closedAtEpochMs, 2000);
      expect(closed.cashSummary.overShortMinorUnits, -25);
      expect(fetched.overShortMinorUnits, -25);
    },
  );

  test(
    'operational write transport failure has no command retry identity',
    () async {
      final client = HttpPosCoreClient(
        baseUri: baseUri,
        httpClient: MockClient(
          (_) async => throw http.ClientException('connection lost'),
        ),
      );
      await expectLater(
        client.openShift('cashier-one', 0),
        throwsA(
          isA<PosCoreTransportFailure>().having(
            (failure) => failure.retrySameCommandId,
            'retrySameCommandId',
            isFalse,
          ),
        ),
      );
    },
  );
}
