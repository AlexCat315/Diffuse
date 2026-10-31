//! Lock-guarded cell so a synchronous entry point can hand values to, and
//! collect results from, a worker thread without capturing a mutable local.
//!
//! Matches Swift's `Box<Value>` (`@unchecked Sendable` + `NSLock`); the Rust
//! `Mutex` makes the `Send`/`Sync` guarantees implicit rather than asserted.

use std::sync::Mutex;

pub struct Cell<Value> {
    value: Mutex<Option<Value>>,
}

impl<Value> Cell<Value> {
    pub const fn new() -> Self {
        Self {
            value: Mutex::new(None),
        }
    }

    pub fn set(&self, new_value: Value) {
        *self.value.lock().unwrap_or_else(|error| error.into_inner()) = Some(new_value);
    }

    pub fn get(&self) -> Option<Value>
    where
        Value: Clone,
    {
        self.value
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .clone()
    }
}

impl<Value> Default for Cell<Value> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::Cell;

    #[test]
    fn set_and_get_round_trip() {
        let cell = Cell::new();
        assert!(cell.get().is_none());
        cell.set(42);
        assert_eq!(cell.get(), Some(42));
    }
}
