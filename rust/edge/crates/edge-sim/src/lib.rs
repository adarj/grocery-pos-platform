#![forbid(unsafe_code)]

//! Repository qualification infrastructure only. There is no production
//! activation path. A future daemon must enforce explicit simulation launch
//! permission. Scripts follow the real adapter contract; no Core/cache/queue
//! authority lives here. Stall means bounded Pending polls, never thread blocking.
//! Binding and event qualification composes fresh scripted adapters through
//! Core's real installation/lifecycle APIs; there is no simulator binding registry
//! or event publication shortcut.

use std::cell::RefCell;
use std::collections::VecDeque;
use std::fmt;
use std::rc::Rc;
use std::sync::Arc;

use edge_adapter_api::{
    AdapterErrorCode, AdapterOperation, AdapterPoll, AdapterPollContext, DeviceAdapter,
};

pub const MAX_SCRIPT_STEPS: usize = 64;
pub const MAX_ADAPTER_SCRIPTS: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Step {
    MarkPossible,
    MarkConfirmed,
    Pending,
    CompleteSuccess,
    CompleteRejected(AdapterErrorCode),
    CompleteFailed(AdapterErrorCode),
    BindingLost(AdapterErrorCode),
    Panic,
    StallForever,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScriptError {
    Empty,
    TooManySteps,
    TooManyScripts,
}

pub struct Script(VecDeque<Step>);

impl Script {
    pub fn new(steps: impl IntoIterator<Item = Step>) -> Result<Self, ScriptError> {
        let mut bounded = VecDeque::new();
        for step in steps {
            if bounded.len() == MAX_SCRIPT_STEPS {
                return Err(ScriptError::TooManySteps);
            }
            bounded.push_back(step);
        }
        if bounded.is_empty() {
            return Err(ScriptError::Empty);
        }
        Ok(Self(bounded))
    }
}

impl fmt::Debug for Script {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Script")
            .field("remaining_steps", &self.0.len())
            .finish()
    }
}

/// Bounded diagnostic state, never an unbounded trace or payload dump.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SimMetrics {
    pub begins: usize,
    pub polls: usize,
    pub operation_drops: usize,
    pub possible_marks: usize,
    pub confirmation_marks: usize,
    pub last_recorded_command: Option<String>,
}

#[derive(Clone, Default)]
pub struct SimProbe(Rc<RefCell<SimMetrics>>);

impl SimProbe {
    pub fn metrics(&self) -> SimMetrics {
        self.0.borrow().clone()
    }
}

pub struct ScriptedAdapter {
    scripts: VecDeque<Script>,
    probe: SimProbe,
}

impl ScriptedAdapter {
    pub fn new(scripts: impl IntoIterator<Item = Script>) -> Result<(Self, SimProbe), ScriptError> {
        let mut bounded = VecDeque::new();
        for script in scripts {
            if bounded.len() == MAX_ADAPTER_SCRIPTS {
                return Err(ScriptError::TooManyScripts);
            }
            bounded.push_back(script);
        }
        let probe = SimProbe::default();
        Ok((
            Self {
                scripts: bounded,
                probe: probe.clone(),
            },
            probe,
        ))
    }
}

impl fmt::Debug for ScriptedAdapter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ScriptedAdapter")
            .field("remaining_scripts", &self.scripts.len())
            .finish_non_exhaustive()
    }
}

impl<P> DeviceAdapter<P> for ScriptedAdapter {
    type Operation = ScriptedOperation<P>;

    fn begin(&mut self, payload: Arc<P>) -> Result<Self::Operation, AdapterErrorCode> {
        let mut metrics = self.probe.0.borrow_mut();
        metrics.begins = metrics.begins.saturating_add(1);
        let script = self
            .scripts
            .pop_front()
            .ok_or(AdapterErrorCode::new("sim.scenario_exhausted"))?;
        Ok(ScriptedOperation {
            script,
            _payload: payload,
            probe: self.probe.clone(),
        })
    }
}

pub struct ScriptedOperation<P> {
    script: Script,
    _payload: Arc<P>,
    probe: SimProbe,
}

impl<P> fmt::Debug for ScriptedOperation<P> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ScriptedOperation")
            .field("script", &self.script)
            .field("payload", &"<redacted>")
            .finish()
    }
}

impl<P> AdapterOperation for ScriptedOperation<P> {
    fn poll(&mut self, context: &mut AdapterPollContext<'_>) -> AdapterPoll {
        {
            let mut metrics = self.probe.0.borrow_mut();
            metrics.polls = metrics.polls.saturating_add(1);
            metrics.last_recorded_command = Some(context.record.command_id.as_str().to_owned());
        }
        // Exactly one step per poll, so even StallForever returns immediately.
        let step = self
            .script
            .0
            .front()
            .copied()
            .unwrap_or(Step::CompleteFailed(AdapterErrorCode::new(
                "sim.incomplete_script",
            )));
        if step != Step::StallForever {
            self.script.0.pop_front();
        }
        match step {
            Step::MarkPossible => {
                context.effects.mark_possible();
                let mut metrics = self.probe.0.borrow_mut();
                metrics.possible_marks = metrics.possible_marks.saturating_add(1);
                AdapterPoll::Pending
            }
            Step::MarkConfirmed => {
                let result = context.effects.mark_confirmed();
                if result.is_ok() {
                    let mut metrics = self.probe.0.borrow_mut();
                    metrics.confirmation_marks = metrics.confirmation_marks.saturating_add(1);
                }
                AdapterPoll::Pending
            }
            Step::Pending | Step::StallForever => AdapterPoll::Pending,
            Step::CompleteSuccess => AdapterPoll::Succeeded,
            Step::CompleteRejected(code) => AdapterPoll::RejectedBeforeEffect(code),
            Step::CompleteFailed(code) => AdapterPoll::KnownFailure(code),
            Step::BindingLost(code) => AdapterPoll::BindingLost(code),
            Step::Panic => std::panic::panic_any("SYNTHETIC_PANIC_PRIVATE_SENTINEL"),
        }
    }
}

impl<P> Drop for ScriptedOperation<P> {
    fn drop(&mut self) {
        let mut metrics = self.probe.0.borrow_mut();
        metrics.operation_drops = metrics.operation_drops.saturating_add(1);
        // No worker, callback, or I/O survives this operation.
    }
}
