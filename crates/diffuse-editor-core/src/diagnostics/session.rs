//! `Editor/Sources/EditorCore/Diagnostics/Session.swift` (session storage half;
//! the `EditorApplication` extensions land with the application methods).

use std::sync::{Arc, Mutex, MutexGuard};

use cove_devtools::inspection::UIDiagnostics;

pub struct EditorDiagnosticSession {
    ui: Mutex<Option<Arc<UIDiagnostics>>>,
}

impl Default for EditorDiagnosticSession {
    fn default() -> Self {
        Self::new()
    }
}

impl EditorDiagnosticSession {
    pub fn new() -> Self {
        EditorDiagnosticSession {
            ui: Mutex::new(None),
        }
    }

    pub fn ui(&self) -> Option<Arc<UIDiagnostics>> {
        self.lock().clone()
    }

    pub fn set_ui(&self, diagnostics: Option<Arc<UIDiagnostics>>) {
        let previous = self.ui();
        if !same_diagnostics(previous.as_ref(), diagnostics.as_ref()) {
            if let Some(previous) = previous {
                previous.reset_captures();
            }
        }
        *self.lock() = diagnostics;
    }

    /// Releases the attached UI session and drops its captures.
    pub fn close(&self) {
        if let Some(current) = self.lock().take() {
            current.reset_captures();
        }
    }

    fn lock(&self) -> MutexGuard<'_, Option<Arc<UIDiagnostics>>> {
        self.ui
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn same_diagnostics(left: Option<&Arc<UIDiagnostics>>, right: Option<&Arc<UIDiagnostics>>) -> bool {
    match (left, right) {
        (Some(left), Some(right)) => Arc::ptr_eq(left, right),
        (None, None) => true,
        _ => false,
    }
}
