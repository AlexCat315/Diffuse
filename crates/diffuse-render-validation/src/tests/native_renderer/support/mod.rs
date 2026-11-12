pub mod device;

use std::sync::{Mutex, MutexGuard};

/// Swift's XCTest runs these GPU suites serially; the renderer, the pipeline
/// caches and the mesh wireframe/picking registries are process-global, so the
/// Rust tests take the same lock before touching a device.
static SERIAL: Mutex<()> = Mutex::new(());

pub fn lock_serial() -> MutexGuard<'static, ()> {
    SERIAL
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}
