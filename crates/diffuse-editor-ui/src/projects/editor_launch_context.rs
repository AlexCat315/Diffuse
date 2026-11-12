//! `Editor/Sources/EditorUI/Projects/EditorLaunchContext.swift`.
//!
//! The window's live launch context. Commands and menus reach it without a view
//! to pass it through, exactly as Swift's `nonisolated(unsafe) static weak
//! var current`. The context type itself — project list, loaded bundles and the
//! window shell — follows in a later batch.

use std::sync::atomic::{AtomicBool, Ordering};

static CURRENT_PRESENT: AtomicBool = AtomicBool::new(false);

/// Whether a launch context is alive. Swift's `EditorLaunchContext.current != nil`.
pub fn has_current() -> bool {
    CURRENT_PRESENT.load(Ordering::Acquire)
}

/// Keeps the process-wide slot in step with the live context's lifetime.
pub fn set_current_present(present: bool) {
    CURRENT_PRESENT.store(present, Ordering::Release);
}
