//! One running plugin process and its drained output.
//!
//! Ported from `Engine/Sources/PluginRuntime/Processes/Entry.swift`.
//!
//! Swift consumed `session.events` with `for try await` inside a `Task`; without
//! an async runtime (MIGRATION.md §5.5) a dedicated reader thread drains the
//! blocking event stream and publishes into the shared update behind a `Mutex`,
//! with an `AtomicBool` cancellation token replacing `Task.cancel()`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cove_system::command::ProcessEvent;
use cove_system::session::ProcessSession;

use crate::base64_data::Data;
use crate::processes::contract::PluginProcessUpdate;
use crate::processes::memory_usage::PluginProcessMemory;
use crate::uuid::Uuid;

pub struct ProcessEntry {
    pub session: Arc<ProcessSession>,
    pub generation: Uuid,
    pub permission_id: String,
    state: Arc<Mutex<EntryState>>,
    maximum_bytes: usize,
    cancelled: Arc<AtomicBool>,
    consumer: Option<std::thread::JoinHandle<()>>,
}

struct EntryState {
    update: PluginProcessUpdate,
    last_memory_sample: Instant,
}

impl ProcessEntry {
    /// Output returned by one poll. Only editor entry points reach processes,
    /// under the larger host-entry-point limits.
    pub const CHUNK_BYTES: usize = 4 * 1_048_576;

    pub fn new(
        session: Arc<ProcessSession>,
        generation: Uuid,
        permission_id: impl Into<String>,
        maximum_bytes: usize,
    ) -> Self {
        let handle = Uuid::parse(&session.id).unwrap_or(generation.clone());
        let state = Arc::new(Mutex::new(EntryState {
            update: PluginProcessUpdate::new(handle),
            last_memory_sample: Instant::now(),
        }));
        let cancelled = Arc::new(AtomicBool::new(false));
        let worker_state = state.clone();
        let worker_cancelled = cancelled.clone();
        let worker_session = session.clone();
        let consumer = std::thread::Builder::new()
            .name("diffuse.plugin.process".into())
            .spawn(move || {
                let session = worker_session;
                let mut events = session.events();
                loop {
                    if worker_cancelled.load(Ordering::Acquire) {
                        return;
                    }
                    match events.next() {
                        Some(Ok(event)) => {
                            if receive(&worker_state, &session, &event, maximum_bytes) {
                                session.cancel();
                            }
                        }
                        Some(Err(error)) => {
                            fail(&worker_state, &error.to_string());
                            return;
                        }
                        None => return,
                    }
                }
            })
            .ok();
        ProcessEntry {
            session,
            generation,
            permission_id: permission_id.into(),
            state,
            maximum_bytes,
            cancelled,
            consumer,
        }
    }

    /// One poll's worth of output, with the buffered bytes consumed.
    pub fn poll(&self) -> PluginProcessUpdate {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state.last_memory_sample.elapsed() >= Duration::from_secs(1) {
            state.update.resident_memory_bytes = if self.session.is_running() {
                PluginProcessMemory::resident_bytes(self.session.process_identifier())
            } else {
                None
            };
            state.last_memory_sample = Instant::now();
        }
        let mut result = state.update.clone();
        let stdout_taken = result.stdout.len().min(Self::CHUNK_BYTES);
        let stderr_taken = result.stderr.len().min(Self::CHUNK_BYTES);
        result.stdout = Data::from_bytes(state.update.stdout.0[..stdout_taken].to_vec());
        result.stderr = Data::from_bytes(state.update.stderr.0[..stderr_taken].to_vec());
        state.update.stdout.0.drain(..stdout_taken);
        state.update.stderr.0.drain(..stderr_taken);
        if !state.update.stdout.is_empty() || !state.update.stderr.is_empty() {
            result.exit_status = None;
        }
        result
    }

    fn stop_reader(&mut self) {
        self.cancelled.store(true, Ordering::Release);
        if let Some(consumer) = self.consumer.take() {
            // The reader blocks on the channel; `cancel` closes it.
            self.session.cancel();
            let _ = consumer.join();
        }
    }
}

impl Drop for ProcessEntry {
    fn drop(&mut self) {
        self.stop_reader();
        self.session.cancel();
    }
}

impl std::fmt::Debug for ProcessEntry {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ProcessEntry")
            .field("permission_id", &self.permission_id)
            .field("generation", &self.generation)
            .field("maximum_bytes", &self.maximum_bytes)
            .finish_non_exhaustive()
    }
}

/// Records one event and reports whether the output bound was exceeded.
fn receive(
    state: &Arc<Mutex<EntryState>>,
    session: &Arc<ProcessSession>,
    event: &ProcessEvent,
    maximum_bytes: usize,
) -> bool {
    let _ = session;
    let mut state = state.lock().unwrap_or_else(|error| error.into_inner());
    match event {
        ProcessEvent::Stdout(bytes) => state.update.stdout.0.extend_from_slice(bytes),
        ProcessEvent::Stderr(bytes) => state.update.stderr.0.extend_from_slice(bytes),
        ProcessEvent::Exited(status) => state.update.exit_status = Some(*status),
        ProcessEvent::StdoutClosed | ProcessEvent::StderrClosed => {}
    }
    if state.update.stdout.len() + state.update.stderr.len() > maximum_bytes {
        state.update.stdout = Data::new();
        state.update.stderr = Data::new();
        state.update.failure = Some("process output limit exceeded".to_string());
        return true;
    }
    false
}

fn fail(state: &Arc<Mutex<EntryState>>, message: &str) {
    let mut state = state.lock().unwrap_or_else(|error| error.into_inner());
    if state.update.failure.is_none() {
        state.update.failure = Some(message.to_string());
    }
}
