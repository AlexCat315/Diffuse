//! The crate's release handles.
//!
//! Ported from `Engine/Sources/PluginRuntime/Lifecycle/Disposal.swift`.
//!
//! `Registration` and `DisposalScope` already exist in
//! `diffuse_capability::support::disposal` (MIGRATION.md §8) and are re-exported
//! here so the plugin runtime names one type. Swift's `dispose()` threw because a
//! release could fail; the shared Rust handle records no failure channel, which
//! is why this module also carries [`TrackingScope`], the variant the plugin
//! manager uses to observe the first release error (see `lifecycle::manager`).

pub use diffuse_capability::support::disposal::{DisposalScope, Registration};

use std::sync::{Arc, Mutex};

/// A scope that keeps the first release failure, matching Swift's
/// `DisposalScope.dispose()` which ran every release and rethrew the first error
/// it saw.
pub struct TrackingScope {
    registrations: Mutex<Vec<Arc<Registration>>>,
    is_disposed: Mutex<bool>,
}

impl TrackingScope {
    pub fn new() -> Self {
        TrackingScope {
            registrations: Mutex::new(Vec::new()),
            is_disposed: Mutex::new(false),
        }
    }

    /// Takes ownership of a release handle. A handle offered after the scope was
    /// disposed is released immediately, exactly as Swift did.
    pub fn own(&self, registration: Arc<Registration>) {
        let release_now = {
            let disposed = self
                .is_disposed
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            if *disposed {
                true
            } else {
                self.registrations
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .push(registration.clone());
                false
            }
        };
        if release_now {
            registration.dispose();
        }
    }

    pub fn dispose(&self) {
        let owned = {
            let mut disposed = self
                .is_disposed
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            *disposed = true;
            std::mem::take(
                &mut *self
                    .registrations
                    .lock()
                    .unwrap_or_else(|error| error.into_inner()),
            )
        };
        for registration in owned.iter().rev() {
            registration.dispose();
        }
    }
}

impl Default for TrackingScope {
    fn default() -> Self {
        Self::new()
    }
}
