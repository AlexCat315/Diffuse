//! `Registration` and `DisposalScope` — single-shot teardown handles.
//!
//! Swift implemented one-shot disposal with `Task`; MIGRATION.md §5.5 maps that to
//! threads and synchronisation primitives. Matching Swift's observable behaviour
//! needs one property beyond a plain flag: a concurrent `dispose()` must *wait*
//! for whichever caller is already running the teardown, because Swift awaited the
//! shared `Task`'s value. A `Condvar` carries that handshake.

use std::sync::{Arc, Condvar, Mutex};

/// Tracks whether a teardown is in progress or completed, and whether this caller
/// must run it.
#[derive(Default)]
struct DisposalState {
    /// `true` while a caller is inside the teardown.
    running: bool,
    /// `true` once the teardown has completed.
    done: bool,
}

impl DisposalState {
    /// Returns `true` only for the caller that must run the teardown; otherwise
    /// blocks until the running teardown completes.
    fn claim(state: &Mutex<DisposalState>, finished: &Condvar) -> bool {
        let mut guard = state.lock().unwrap_or_else(|error| error.into_inner());
        loop {
            if !guard.done && !guard.running {
                guard.running = true;
                return true;
            }
            if guard.done {
                return false;
            }
            guard = finished
                .wait(guard)
                .unwrap_or_else(|error| error.into_inner());
        }
    }

    /// Publishes completion to every waiting caller.
    fn finish(state: &Mutex<DisposalState>, finished: &Condvar) {
        let mut guard = state.lock().unwrap_or_else(|error| error.into_inner());
        guard.running = false;
        guard.done = true;
        drop(guard);
        finished.notify_all();
    }
}

/// A disposal handle for one registration. Disposing it runs the registered
/// teardown exactly once; a registration disposed early and then reached again
/// by its scope's unwind is a no-op.
pub struct Registration {
    state: Arc<Mutex<DisposalState>>,
    finished: Arc<Condvar>,
    revoke: Box<dyn Fn() + Send + Sync>,
}

impl Registration {
    pub fn new(revoke: impl Fn() + Send + Sync + 'static) -> Self {
        Registration {
            state: Arc::new(Mutex::new(DisposalState::default())),
            finished: Arc::new(Condvar::new()),
            revoke: Box::new(revoke),
        }
    }

    /// Runs teardown once. Concurrent callers wait for the same completion.
    pub fn dispose(&self) {
        if !DisposalState::claim(&self.state, &self.finished) {
            return;
        }
        // The teardown must publish completion even when it panics, so other
        // callers do not block forever.
        struct CompletionGuard<'a> {
            state: &'a Mutex<DisposalState>,
            finished: &'a Condvar,
        }

        impl Drop for CompletionGuard<'_> {
            fn drop(&mut self) {
                DisposalState::finish(self.state, self.finished);
            }
        }

        let _guard = CompletionGuard {
            state: &self.state,
            finished: &self.finished,
        };
        (self.revoke)();
    }
}

/// A LIFO scope that owns registrations and unwinds them as a group.
///
/// The scope is deliberately not a global registry: the object whose lifetime the
/// registrations follow owns one and releases it when that lifetime ends.
/// Unwinding runs each teardown exactly once, in reverse registration order; the
/// scope remains usable afterwards.
pub struct DisposalScope {
    registrations: Mutex<Vec<Arc<Registration>>>,
}

impl DisposalScope {
    #[inline]
    pub fn new() -> Self {
        DisposalScope {
            registrations: Mutex::new(Vec::new()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Arc<Registration>>> {
        self.registrations
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }

    /// Registers a teardown and returns its handle.
    pub fn track(&self, revoke: impl Fn() + Send + Sync + 'static) -> Arc<Registration> {
        let registration = Arc::new(Registration::new(revoke));
        self.track_registration(registration.clone());
        registration
    }

    /// Takes ownership of an existing handle.
    pub fn track_registration(&self, registration: Arc<Registration>) {
        self.lock().push(registration);
    }

    /// Unwinds every outstanding registration in reverse registration order.
    /// Idempotent until new registrations are tracked.
    pub fn dispose_all(&self) {
        let pending: Vec<Arc<Registration>> = {
            let mut registrations = self.lock();
            std::mem::take(&mut *registrations)
        };
        for registration in pending.iter().rev() {
            registration.dispose();
        }
    }
}

impl Default for DisposalScope {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for DisposalScope {
    fn drop(&mut self) {
        let registrations = self
            .registrations
            .get_mut()
            .unwrap_or_else(|error| error.into_inner());
        for registration in registrations.iter().rev() {
            registration.dispose();
        }
        registrations.clear();
    }
}
