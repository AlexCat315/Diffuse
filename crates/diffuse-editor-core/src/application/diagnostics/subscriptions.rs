//! `Editor/Sources/EditorCore/Application/Diagnostics/Subscriptions.swift`.
//!
//! The console capture half. `EditorSubscriptions` itself joins the event
//! bridge and renderer preparation in a later batch.

use std::sync::{Arc, Mutex, MutexGuard};

use cove_logging::{LogObservation, LogQuery, LogRecord, LogSystem, LogValue};

#[derive(Default)]
struct CaptureState {
    pending: Vec<LogRecord>,
    wake: Option<Arc<dyn Fn() + Send + Sync>>,
}

/// The writer only queues values. The editor's tick applies them to observable
/// state.
pub struct EditorLogCapture {
    state: Arc<Mutex<CaptureState>>,
    observation: Mutex<Option<LogObservation>>,
}

impl EditorLogCapture {
    pub fn new() -> Self {
        let state = Arc::new(Mutex::new(CaptureState::default()));
        let handler_state = state.clone();
        let observation = LogSystem::observe(
            LogQuery::default(),
            false,
            Arc::new(move |record: &LogRecord| {
                if record.metadata.get("editor_console")
                    == Some(&LogValue::String("direct".to_string()))
                {
                    return;
                }
                let notify = {
                    let mut state = lock(&handler_state);
                    let was_empty = state.pending.is_empty();
                    if state.pending.len() == 200 {
                        state.pending.remove(0);
                    }
                    state.pending.push(record.clone());
                    if was_empty { state.wake.clone() } else { None }
                };
                if let Some(notify) = notify {
                    notify();
                }
            }),
        );
        EditorLogCapture {
            state,
            observation: Mutex::new(Some(observation)),
        }
    }

    pub fn set_wake(&self, wake: Option<Arc<dyn Fn() + Send + Sync>>) {
        let notify = {
            let mut state = lock(&self.state);
            state.wake = wake;
            if state.pending.is_empty() {
                None
            } else {
                state.wake.clone()
            }
        };
        if let Some(notify) = notify {
            notify();
        }
    }

    pub fn take(&self) -> Vec<LogRecord> {
        let mut state = lock(&self.state);
        let records = state.pending.clone();
        state.pending.clear();
        records
    }

    pub fn stop(&self) {
        if let Some(observation) = self
            .observation
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
        {
            observation.cancel();
        }
        let mut state = lock(&self.state);
        state.wake = None;
        state.pending.clear();
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Default for EditorLogCapture {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for EditorLogCapture {
    fn drop(&mut self) {
        self.stop();
    }
}
