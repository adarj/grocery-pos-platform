import 'json_fields.dart';
import 'pos_core_failure.dart';

enum PosCommandOutcomeKind {
  accepted('accepted'),
  domainRejected('domain_rejected'),
  notFound('not_found'),
  alreadyExists('already_exists'),
  versionConflict('version_conflict');

  const PosCommandOutcomeKind(this.wireName);

  final String wireName;

  static PosCommandOutcomeKind fromWireName(String value) {
    return switch (value) {
      'accepted' => PosCommandOutcomeKind.accepted,
      'domain_rejected' => PosCommandOutcomeKind.domainRejected,
      'not_found' => PosCommandOutcomeKind.notFound,
      'already_exists' => PosCommandOutcomeKind.alreadyExists,
      'version_conflict' => PosCommandOutcomeKind.versionConflict,
      _ => throw PosCoreInvalidResponseFailure(
        'Unknown transaction command outcome kind.',
      ),
    };
  }
}

final class PosCommandResult {
  const PosCommandResult({
    required this.commandId,
    required this.transactionId,
    required this.outcomeKind,
    required this.outcomeCode,
    required this.outcomeStreamVersion,
  });

  final String commandId;
  final String transactionId;
  final PosCommandOutcomeKind outcomeKind;
  final String outcomeCode;
  final int outcomeStreamVersion;

  bool get accepted => outcomeKind == PosCommandOutcomeKind.accepted;

  factory PosCommandResult.fromJson(Map<String, Object?> json) {
    const context = 'transaction command result';
    return PosCommandResult(
      commandId: requireJsonString(json, 'command_id', context, nonEmpty: true),
      transactionId: requireJsonString(
        json,
        'transaction_id',
        context,
        nonEmpty: true,
      ),
      outcomeKind: PosCommandOutcomeKind.fromWireName(
        requireJsonString(json, 'outcome_kind', context, nonEmpty: true),
      ),
      outcomeCode: requireJsonString(
        json,
        'outcome_code',
        context,
        nonEmpty: true,
      ),
      outcomeStreamVersion: requireJsonNonnegativeInt(
        json,
        'outcome_stream_version',
        context,
      ),
    );
  }
}
