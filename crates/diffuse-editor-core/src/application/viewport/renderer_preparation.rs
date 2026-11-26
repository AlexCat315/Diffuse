//! `Editor/Sources/EditorCore/Application/Viewport/RendererPreparation.swift`.
//!
//! The generation/sequence gate around renderer preparation. Swift keeps a
//! `Task` handle and cancels it cooperatively; Rust's preparation work runs on
//! a worker thread that polls the per-generation cancellation token.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;

#[derive(Default)]
struct State {
    generation: u64,
    sequence: u64,
    task: Option<JoinHandle<()>>,
    cancellation: Arc<AtomicBool>,
}

pub struct EditorRendererPreparation {
    state: Mutex<State>,
}

impl Default for EditorRendererPreparation {
    fn default() -> Self {
        Self::new()
    }
}

impl EditorRendererPreparation {
    pub fn new() -> Self {
        EditorRendererPreparation {
            state: Mutex::new(State {
                generation: 0,
                sequence: 0,
                task: None,
                cancellation: Arc::new(AtomicBool::new(true)),
            }),
        }
    }

    /// Starts a new generation, invalidating every earlier report.
    pub fn begin(&self) -> u64 {
        let mut state = self.lock();
        state.generation = state.generation.wrapping_add(1);
        state.sequence = 0;
        state.cancellation.store(true, Ordering::Release);
        state.cancellation = Arc::new(AtomicBool::new(false));
        if let Some(task) = state.task.take() {
            drop(task);
        }
        state.generation
    }

    /// Stores the worker for the current generation; a stale worker is
    /// cancelled instead.
    pub fn attach(&self, task: JoinHandle<()>, generation: u64) {
        let mut state = self.lock();
        if state.generation == generation {
            if let Some(previous) = state.task.replace(task) {
                drop(previous);
            }
        } else {
            state.cancellation.store(true, Ordering::Release);
            drop(task);
        }
    }

    pub fn is_current(&self, generation: u64) -> bool {
        self.lock().generation == generation
    }

    /// Accepts a progress report only when it is newer than the last accepted
    /// one for this generation.
    pub fn accept(&self, sequence: u64, generation: u64) -> bool {
        let mut state = self.lock();
        if state.generation != generation || sequence <= state.sequence {
            return false;
        }
        state.sequence = sequence;
        true
    }

    pub fn finish(&self, generation: u64) {
        let mut state = self.lock();
        if state.generation == generation {
            state.task = None;
        }
    }

    /// Cancels the active worker. Returns whether one was attached.
    pub fn cancel(&self) -> bool {
        let mut state = self.lock();
        state.generation = state.generation.wrapping_add(1);
        state.cancellation.store(true, Ordering::Release);
        state.cancellation = Arc::new(AtomicBool::new(true));
        state.task.take().is_some()
    }

    /// Cancellation token for a generation's worker. `None` once the
    /// generation was superseded.
    pub fn cancellation_token(&self, generation: u64) -> Option<Arc<AtomicBool>> {
        let state = self.lock();
        (state.generation == generation).then(|| state.cancellation.clone())
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl Drop for EditorRendererPreparation {
    fn drop(&mut self) {
        let state = self
            .state
            .get_mut()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.cancellation.store(true, Ordering::Release);
    }
}

use crate::application::editor_application::{EditorApplication, SendableAppHandle};
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorConsoleSeverity;
use crate::state::workspace::editor_workbench_state::{
    EditorIssueTarget, EditorOperation, EditorOperationKind, EditorOperationStatus,
};

/// Derives the operation status for a preparation phase.
fn operation_status(phase: cove_graphics::rhi::PreparationPhase) -> EditorOperationStatus {
    match phase {
        cove_graphics::rhi::PreparationPhase::Preparing => EditorOperationStatus::Running,
        cove_graphics::rhi::PreparationPhase::Finished => EditorOperationStatus::Succeeded,
        cove_graphics::rhi::PreparationPhase::Cancelled => EditorOperationStatus::Cancelled,
        cove_graphics::rhi::PreparationPhase::Failed => EditorOperationStatus::Failed,
    }
}

impl EditorApplication {
    /// `cancelRendererPreparation()` — reports cancellation only when a
    /// preparation was actually active.
    pub fn cancel_renderer_preparation(&self) {
        if !self.subscriptions.renderer_preparation.cancel() {
            return;
        }
        let mut operation = EditorOperation::with_defaults(
            EditorOperationKind::PreparingRenderer,
            "Shader preparation cancelled".to_string(),
        );
        operation.id = "renderer-preparation".to_string();
        operation.status = EditorOperationStatus::Cancelled;
        self.store.dispatch(EditorAction::SetOperation(operation));
    }

    /// `retryRendererPreparation()`.
    pub fn retry_renderer_preparation(self: &std::rc::Rc<Self>) {
        self.prepare_renderer_at_launch();
    }

    /// `prepareRendererAtLaunch()` — builds the viewport renderer and starts the
    /// engine. Swift ran this in a `Task` because preparation blocks on driver
    /// work; with no async runtime (§5.5) the work runs on the calling thread and
    /// the generation gate still rejects stale progress and completion.
    pub fn prepare_renderer_at_launch(self: &std::rc::Rc<Self>) {
        if self.engine.render_device.is_none() {
            self.engine.start(None, true, None);
            self.store.dispatch(EditorAction::SetConnected(true));
            return;
        }
        let preparation = &self.subscriptions.renderer_preparation;
        let generation = preparation.begin();
        let settings = self.make_viewport_render_settings(
            self.store.viewport_shadows_enabled(),
            self.store.viewport_shading_mode(),
        );
        let mut operation = EditorOperation::with_defaults(
            EditorOperationKind::PreparingRenderer,
            "Preparing shaders…".to_string(),
        );
        operation.id = "renderer-preparation".to_string();
        self.store.dispatch(EditorAction::SetOperation(operation));

        let handle = SendableAppHandle(std::rc::Rc::downgrade(self));
        let progress = move |report: cove_graphics::rhi::ResourcePreparationProgress| {
            let Some(app) = handle.upgrade() else { return };
            if !app.subscriptions.renderer_preparation.accept(report.sequence, generation) {
                return;
            }
            app.show_renderer_preparation(&report);
        };
        let prepared = self.engine.prepare_renderer(None, true, &settings, progress);
        preparation.finish(generation);
        match prepared {
            Ok(renderer) => {
                if !preparation.is_current(generation) {
                    return;
                }
                self.engine.start(
                    None,
                    true,
                    renderer.map(|renderer| Box::new(renderer) as Box<_>),
                );
                // Settings may have changed during preparation; the engine host
                // still holds the latest queued settings.
                self.render_gate
                    .replace(crate::editing::viewport::editor_viewport_render_gate::EditorViewportRenderGate::new());
                self.store.dispatch(EditorAction::SetConnected(true));
                self.request_display_refresh();
                self.log_console(
                    "Editor connected to runtime",
                    EditorConsoleSeverity::Info,
                    None,
                    Option::<EditorIssueTarget>::None,
                    None,
                );
            }
            Err(error) => {
                if !preparation.is_current(generation) {
                    return;
                }
                let mut operation = EditorOperation::with_defaults(
                    EditorOperationKind::PreparingRenderer,
                    "Shader preparation failed".to_string(),
                );
                operation.id = "renderer-preparation".to_string();
                operation.status = EditorOperationStatus::Failed;
                self.store.dispatch(EditorAction::SetOperation(operation));
                self.log_console(
                    "Shader preparation failed",
                    EditorConsoleSeverity::Error,
                    Some(error.to_string()),
                    Option::<EditorIssueTarget>::None,
                    None,
                );
            }
        }
    }

    /// `showRendererPreparation(_:)` — mirrors a progress report onto the
    /// long-running operation row.
    fn show_renderer_preparation(
        &self,
        progress: &cove_graphics::rhi::ResourcePreparationProgress,
    ) {
        let mut operation = EditorOperation::with_defaults(
            EditorOperationKind::PreparingRenderer,
            progress
                .current_step
                .clone()
                .unwrap_or_else(|| "Preparing shaders…".to_string()),
        );
        operation.id = "renderer-preparation".to_string();
        operation.status = operation_status(progress.phase);
        operation.completed = progress.completed_steps as i64;
        operation.total = progress.total_steps.unwrap_or(0) as i64;
        self.store.dispatch(EditorAction::SetOperation(operation));
    }
}
