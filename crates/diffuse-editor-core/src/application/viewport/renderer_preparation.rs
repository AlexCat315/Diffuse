//! `Editor/Sources/EditorCore/Application/Viewport/RendererPreparation.swift`.
//!
//! The generation/sequence gate around renderer preparation. Swift keeps a
//! `Task` handle and cancels it cooperatively; Rust's preparation work runs on
//! a worker thread that polls the per-generation cancellation token.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;

#[derive(Default)]
struct State {
    generation: u64,
    sequence: u64,
    task: Option<JoinHandle<()>>,
    cancellation: Arc<AtomicBool>,
}

pub struct EditorRendererPreparation {
    state: Mutex<State>,
}

impl Default for EditorRendererPreparation {
    fn default() -> Self {
        Self::new()
    }
}

impl EditorRendererPreparation {
    pub fn new() -> Self {
        EditorRendererPreparation {
            state: Mutex::new(State {
                generation: 0,
                sequence: 0,
                task: None,
                cancellation: Arc::new(AtomicBool::new(true)),
            }),
        }
    }

    /// Starts a new generation, invalidating every earlier report.
    pub fn begin(&self) -> u64 {
        let mut state = self.lock();
        state.generation = state.generation.wrapping_add(1);
        state.sequence = 0;
        state.cancellation.store(true, Ordering::Release);
        state.cancellation = Arc::new(AtomicBool::new(false));
        if let Some(task) = state.task.take() {
            drop(task);
        }
        state.generation
    }

    /// Stores the worker for the current generation; a stale worker is
    /// cancelled instead.
    pub fn attach(&self, task: JoinHandle<()>, generation: u64) {
        let mut state = self.lock();
        if state.generation == generation {
            if let Some(previous) = state.task.replace(task) {
                drop(previous);
            }
        } else {
            state.cancellation.store(true, Ordering::Release);
            drop(task);
        }
    }

    pub fn is_current(&self, generation: u64) -> bool {
        self.lock().generation == generation
    }

    /// Accepts a progress report only when it is newer than the last accepted
    /// one for this generation.
    pub fn accept(&self, sequence: u64, generation: u64) -> bool {
        let mut state = self.lock();
        if state.generation != generation || sequence <= state.sequence {
            return false;
        }
        state.sequence = sequence;
        true
    }

    pub fn finish(&self, generation: u64) {
        let mut state = self.lock();
        if state.generation == generation {
            state.task = None;
        }
    }

    /// Cancels the active worker. Returns whether one was attached.
    pub fn cancel(&self) -> bool {
        let mut state = self.lock();
        state.generation = state.generation.wrapping_add(1);
        state.cancellation.store(true, Ordering::Release);
        state.cancellation = Arc::new(AtomicBool::new(true));
        state.task.take().is_some()
    }

    /// Cancellation token for a generation's worker. `None` once the
    /// generation was superseded.
    pub fn cancellation_token(&self, generation: u64) -> Option<Arc<AtomicBool>> {
        let state = self.lock();
        (state.generation == generation).then(|| state.cancellation.clone())
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl Drop for EditorRendererPreparation {
    fn drop(&mut self) {
        let state = self
            .state
            .get_mut()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.cancellation.store(true, Ordering::Release);
    }
}
