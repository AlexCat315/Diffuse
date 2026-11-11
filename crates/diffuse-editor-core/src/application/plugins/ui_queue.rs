//! Translation of Editor/Sources/EditorCore/Application/Plugins/UIQueue.swift.
//!
//! SDL's on-demand event loop must be explicitly woken for work arriving over a
//! pipe or timer. The host installs its enqueue function; until then `schedule`
//! runs the body directly (Swift's `Task { @MainActor in body() }`).

use std::sync::{Arc, Mutex};

/// Swift's `(@escaping () -> Void) -> Void` hop onto the UI thread.
pub type UIEnqueue = Arc<dyn Fn(Arc<dyn Fn() + Send + Sync>) + Send + Sync>;
pub type UIWork = Arc<dyn Fn() + Send + Sync>;

#[derive(Default)]
pub struct PluginUIQueue {
    enqueue: Mutex<Option<UIEnqueue>>,
}

impl PluginUIQueue {
    pub fn new() -> Self {
        PluginUIQueue::default()
    }

    /// Installs the host's wake-up hook. Swift's `guard let enqueue else
    /// { return }` keeps the previous hook when `None` is passed.
    pub fn install(&self, enqueue: Option<UIEnqueue>) {
        let Some(enqueue) = enqueue else {
            return;
        };
        let mut slot = self
            .enqueue
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *slot = Some(enqueue);
    }

    pub fn schedule(&self, body: UIWork) {
        let enqueue = self
            .enqueue
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        match enqueue {
            Some(enqueue) => enqueue(body),
            None => body(),
        }
    }
}
