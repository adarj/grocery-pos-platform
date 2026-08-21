enum CashierLocalRecoveryFailureKind { corruptState, storageUnavailable }

final class CashierLocalRecoveryFailure {
  const CashierLocalRecoveryFailure._({
    required this.kind,
    required this.message,
    required this.blocksSession,
  });

  const CashierLocalRecoveryFailure.corruptState()
    : this._(
        kind: CashierLocalRecoveryFailureKind.corruptState,
        message:
            'Saved cashier recovery data could not be read safely. '
            'Do not start another sale until the recovery issue is resolved.',
        blocksSession: true,
      );

  const CashierLocalRecoveryFailure.storageUnavailable({
    bool commandWasNotSent = false,
    bool blocksSession = false,
  }) : this._(
         kind: CashierLocalRecoveryFailureKind.storageUnavailable,
         message: commandWasNotSent
             ? 'Local recovery storage unavailable. The command was not sent.'
             : 'Local recovery storage unavailable.',
         blocksSession: blocksSession,
       );

  final CashierLocalRecoveryFailureKind kind;
  final String message;
  final bool blocksSession;
}
