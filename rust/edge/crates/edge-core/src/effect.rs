use edge_adapter_api::{AdapterPoll, EffectContractViolation, EffectProgress};
use edge_protocol::{EffectEvidence, TerminalOutcome};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum Progress {
    #[default]
    None,
    Possible,
    Confirmed,
}

/// Owned only by the executor. Even an ignored invalid-confirmation error is
/// sticky, preventing a misbehaving adapter from turning it into success.
#[derive(Default)]
pub(crate) struct EffectTracker {
    progress: Progress,
    violated: bool,
}

impl EffectProgress for EffectTracker {
    fn mark_possible(&mut self) {
        if self.progress == Progress::None {
            self.progress = Progress::Possible;
        }
    }

    fn mark_confirmed(&mut self) -> Result<(), EffectContractViolation> {
        if self.violated {
            return Err(EffectContractViolation);
        }
        if self.progress == Progress::None {
            // A false claim of confirmation makes non-effect untrustworthy.
            // Core conservatively raises uncertainty, never direct confirmation.
            self.violated = true;
            self.progress = Progress::Possible;
            return Err(EffectContractViolation);
        }
        self.progress = Progress::Confirmed;
        Ok(())
    }
}

/// Validated generic result pairs. There is no arbitrary outcome/evidence setter.
#[derive(Clone, Copy)]
pub(crate) enum Completion {
    Rejected,
    FailedNone,
    FailedPossible,
    Unknown,
    Succeeded,
}

impl Completion {
    pub(crate) fn public_pair(self) -> (TerminalOutcome, EffectEvidence) {
        match self {
            Self::Rejected => (TerminalOutcome::Rejected, EffectEvidence::None),
            Self::FailedNone => (TerminalOutcome::Failed, EffectEvidence::None),
            Self::FailedPossible => (TerminalOutcome::Failed, EffectEvidence::Possible),
            Self::Unknown => (TerminalOutcome::Unknown, EffectEvidence::Possible),
            Self::Succeeded => (TerminalOutcome::Succeeded, EffectEvidence::Confirmed),
        }
    }
}

impl EffectTracker {
    pub(crate) fn contract_failure(&mut self) -> Completion {
        // A claimed success without progress undermines the adapter's promise
        // that None proves non-effect. Raise uncertainty, never confirmation.
        if self.progress == Progress::None {
            self.progress = Progress::Possible;
        }
        self.violated = true;
        self.interrupted()
    }

    pub(crate) fn violated(&self) -> bool {
        self.violated
    }

    pub(crate) fn interrupted(&self) -> Completion {
        match self.progress {
            Progress::None => Completion::FailedNone,
            Progress::Possible => Completion::Unknown,
            Progress::Confirmed => Completion::Succeeded,
        }
    }

    /// None means an inconsistent fact/evidence pair; caller fences the binding.
    pub(crate) fn complete(&self, fact: AdapterPoll) -> Option<Completion> {
        if self.violated {
            return None;
        }
        if self.progress == Progress::Confirmed {
            // Confirmation dominates even a contradictory later failure fact.
            return matches!(fact, AdapterPoll::Succeeded).then_some(Completion::Succeeded);
        }
        match (fact, self.progress) {
            (AdapterPoll::RejectedBeforeEffect(_), Progress::None) => Some(Completion::Rejected),
            (AdapterPoll::KnownFailure(_), Progress::None) => Some(Completion::FailedNone),
            (AdapterPoll::KnownFailure(_), Progress::Possible) => Some(Completion::FailedPossible),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_is_monotonic_and_invalid_confirmation_is_sticky() {
        let mut tracker = EffectTracker::default();
        assert_eq!(tracker.mark_confirmed(), Err(EffectContractViolation));
        tracker.mark_possible();
        assert_eq!(tracker.mark_confirmed(), Err(EffectContractViolation));
        assert!(tracker.violated());
        assert_eq!(
            tracker.interrupted().public_pair(),
            (TerminalOutcome::Unknown, EffectEvidence::Possible)
        );

        let mut tracker = EffectTracker::default();
        tracker.mark_possible();
        tracker.mark_possible();
        tracker.mark_confirmed().unwrap();
        tracker.mark_possible();
        tracker.mark_confirmed().unwrap();
        assert_eq!(
            tracker.interrupted().public_pair(),
            (TerminalOutcome::Succeeded, EffectEvidence::Confirmed)
        );
    }
}
