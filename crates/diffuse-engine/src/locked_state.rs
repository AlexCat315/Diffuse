//! Translation of Engine/Sources/EngineCore/LockedState.swift.
//!
//! A value behind one short critical section. Every reader and writer goes
//! through `with_lock`, so no caller can observe a half-updated value.

use std::sync::{Mutex, MutexGuard};

pub struct LockedState<Value> {
    value: Mutex<Value>,
}

impl<Value> LockedState<Value> {
    pub fn new(value: Value) -> Self {
        LockedState {
            value: Mutex::new(value),
        }
    }

    pub fn with_lock<Result>(&self, body: impl FnOnce(&mut Value) -> Result) -> Result {
        let mut guard: MutexGuard<'_, Value> = self
            .value
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        body(&mut guard)
    }
}
