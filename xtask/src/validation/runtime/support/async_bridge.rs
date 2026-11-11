//! Runs a closure to completion for the synchronous `RuntimeValidation` entry
//! points.
//!
//! Swift needed `AsyncBridge.wait` because its DevTools clients live in
//! `URLSessionWebSocketTask` awaits: the CLI entry point is synchronous, so the
//! body was hopped onto the concurrency pool while the caller blocked on a
//! semaphore. The Rust port has no async runtime (MIGRATION.md §5.5), so the
//! body runs on a scoped worker thread and the caller joins it. The observable
//! contract is unchanged: the calling thread blocks, the body runs elsewhere,
//! and a panic surfaces as a `ToolError` instead of poisoning the process.

use crate::support::terminal::ToolError;
use std::panic::{self, AssertUnwindSafe};

pub struct AsyncBridge;

impl AsyncBridge {
    /// Runs `body` on a scoped thread and returns its value, joining before
    /// returning so the caller observes every side effect.
    pub fn wait<T, F>(body: F) -> Result<T, ToolError>
    where
        T: Send,
        F: FnOnce() -> T + Send,
    {
        let outcome = panic::catch_unwind(AssertUnwindSafe(|| {
            std::thread::scope(|scope| scope.spawn(body).join())
        }));
        match outcome {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(_)) => Err(ToolError::message("Async validation did not complete")),
            Err(_) => Err(ToolError::message("Async validation did not complete")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::AsyncBridge;

    // The Swift case runs on the main actor and asserts the body's value
    // survives the hop: `MainActor.assumeIsolated { AsyncBridge.wait { await
    // Self.valueAfterSuspension() } } == 42`.
    #[test]
    fn synchronous_entry_observes_work_finished_elsewhere() {
        let thread = std::thread::current().id();
        let result = AsyncBridge::wait(move || {
            std::thread::yield_now();
            (42, std::thread::current().id() != thread)
        })
        .expect("bridge completes");
        assert_eq!(result.0, 42);
        assert!(result.1, "the body must run off the calling thread");
    }

    #[test]
    fn panicking_body_becomes_a_tool_error() {
        let error = AsyncBridge::wait(|| panic!("boom")).expect_err("panic is reported");
        assert!(error.to_string().contains("did not complete"));
    }
}
