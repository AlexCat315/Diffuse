//! `Editor/Sources/EditorCore/Scene/Adapter/History.swift`.

use std::collections::BTreeSet;
use std::rc::Rc;

use diffuse_intent::transactions::mutation_components::SceneComponentKey;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;

impl EditorSceneAdapter {
    /// Swift's `recordHistory: Bool = true, componentKeys: Set<SceneComponentKey>? = nil`.
    pub fn notify_revision_changed(
        &self,
        record_history: bool,
        component_keys: Option<BTreeSet<SceneComponentKey>>,
    ) {
        let scene = self.scene();
        self.edit_history.borrow_mut().record_revision_change(
            scene.clone(),
            record_history,
            component_keys,
        );
        self.invalidate_particle_feedback();
        self.notify_revision_handlers(scene.snapshot().revision);
    }

    /// The all-default form of [`Self::notify_revision_changed`].
    pub fn notify_revision_changed_default(&self) {
        self.notify_revision_changed(true, None);
    }

    pub fn with_edit_history_group<Result>(&self, body: impl FnOnce() -> Result) -> Result {
        {
            let scene = self.scene();
            self.edit_history.borrow_mut().begin_group(&scene);
        }
        let result = body();
        {
            let scene = self.scene();
            self.edit_history.borrow_mut().end_group(&scene);
        }
        result
    }

    /// Coalesces the live mutations produced by one pointer drag into a single
    /// undo entry. Calls are idempotent so focus loss and an eventual mouse-up
    /// can both terminate the same interaction safely.
    pub fn begin_interactive_edit_history_group(&self) {
        let scene = self.scene();
        self.edit_history
            .borrow_mut()
            .begin_interactive_group(&scene);
    }

    pub fn end_interactive_edit_history_group(&self) {
        let scene = self.scene();
        self.edit_history.borrow_mut().end_interactive_group(&scene);
    }

    /// Restores the pre-drag scene without consuming an undo entry. A late
    /// mouse-up or focus-loss event after cancellation is harmless.
    pub fn cancel_interactive_edit_history_group(&self) {
        let previous = self.edit_history.borrow_mut().cancel_interactive_group();
        if let Some(previous) = previous {
            self.restore_history_scene(previous);
        }
    }

    pub fn can_undo_edit(&self) -> bool {
        self.edit_history.borrow().can_undo()
    }

    pub fn can_redo_edit(&self) -> bool {
        self.edit_history.borrow().can_redo()
    }

    pub fn record_asset_edit(&self, undo: Rc<dyn Fn() -> bool>, redo: Rc<dyn Fn() -> bool>) {
        self.end_interactive_edit_history_group();
        self.edit_history.borrow_mut().record_asset_edit(undo, redo);
    }

    pub fn undo_edit(&self) -> bool {
        let scene = self.scene();
        let previous = self.edit_history.borrow_mut().undo(scene);
        match previous {
            Some(previous) => {
                self.restore_history_scene(previous);
                true
            }
            None => false,
        }
    }

    pub fn redo_edit(&self) -> bool {
        let scene = self.scene();
        let next = self.edit_history.borrow_mut().redo(scene);
        match next {
            Some(next) => {
                self.restore_history_scene(next);
                true
            }
            None => false,
        }
    }

    pub fn reset_edit_history(&self) {
        let scene = self.scene();
        self.edit_history.borrow_mut().reset(scene);
    }

    fn restore_history_scene(&self, restored_scene: SceneRuntime) {
        self.set_scene(restored_scene);
        self.invalidate_particle_feedback();
        self.notify_revision_handlers(self.revision());
    }
}
