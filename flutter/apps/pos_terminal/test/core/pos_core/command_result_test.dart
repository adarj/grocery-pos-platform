import 'package:flutter_test/flutter_test.dart';
import 'package:pos_terminal/core/pos_core/models/command_result.dart';
import 'package:pos_terminal/core/pos_core/models/pos_core_failure.dart';

void main() {
  const base = {
    'command_id': 'cmd-001',
    'transaction_id': 'txn-001',
    'outcome_code': 'accepted',
    'outcome_stream_version': 7,
  };

  test('all documented durable outcome kinds parse explicitly', () {
    const cases = {
      'accepted': PosCommandOutcomeKind.accepted,
      'domain_rejected': PosCommandOutcomeKind.domainRejected,
      'not_found': PosCommandOutcomeKind.notFound,
      'already_exists': PosCommandOutcomeKind.alreadyExists,
      'version_conflict': PosCommandOutcomeKind.versionConflict,
    };

    for (final entry in cases.entries) {
      final result = PosCommandResult.fromJson({
        ...base,
        'outcome_kind': entry.key,
      });

      expect(result.commandId, 'cmd-001');
      expect(result.transactionId, 'txn-001');
      expect(result.outcomeKind, entry.value);
      expect(result.outcomeCode, 'accepted');
      expect(result.outcomeStreamVersion, 7);
    }
  });

  test('unknown outcome kind fails closed', () {
    expect(
      () => PosCommandResult.fromJson({
        ...base,
        'outcome_kind': 'future_outcome',
      }),
      throwsA(isA<PosCoreInvalidResponseFailure>()),
    );
  });

  test('missing and wrongly typed result fields fail closed', () {
    final valid = {...base, 'outcome_kind': 'accepted'};

    for (final invalid in [
      {...valid}..remove('command_id'),
      {...valid, 'transaction_id': 1},
      {...valid, 'outcome_code': false},
      {...valid, 'outcome_stream_version': 7.0},
      {...valid, 'outcome_stream_version': -1},
    ]) {
      expect(
        () => PosCommandResult.fromJson(invalid),
        throwsA(isA<PosCoreInvalidResponseFailure>()),
      );
    }
  });
}
