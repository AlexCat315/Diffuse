//! Minimal lock-guarded cell so synchronous wrappers can receive a value from a
//! concurrent completion handler without capturing a mutable local.

use std::sync::Mutex;

/// Swift's `UncheckedBox<Value>`: a `Mutex`-guarded `Option<Value>`.
///
/// The Rust equivalent does not need `@unchecked Sendable`; `Mutex<T>` is
/// `Send + Sync` whenever `T` is `Send`, and the value is only observed after
/// the producer signals completion.
pub struct UncheckedBox<T> {
    value: Mutex<Option<T>>,
}

impl<T> UncheckedBox<T> {
    pub const fn new() -> Self {
        Self {
            value: Mutex::new(None),
        }
    }

    pub fn set(&self, new_value: T) {
        *self.value.lock().unwrap_or_else(|error| error.into_inner()) = Some(new_value);
    }

    pub fn get(&self) -> Option<T>
    where
        T: Clone,
    {
        self.value
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .clone()
    }

    /// Takes the value, leaving the cell empty.
    pub fn take(&self) -> Option<T> {
        self.value
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take()
    }

    pub fn is_empty(&self) -> bool {
        self.value
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .is_none()
    }
}

impl<T> Default for UncheckedBox<T> {
    fn default() -> Self {
        Self::new()
    }
}
