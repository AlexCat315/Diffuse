//! Ring-buffer snapshot store for undo/redo.
//!
//! Holds up to `capacity` scene copies. Two behaviours are load-bearing and are the
//! reason this is not just a `VecDeque`:
//!
//! - **Pushing clears the redo stack.** A new edit invalidates any undone future.
//! - **Both stacks are bounded independently**, dropping the *oldest* entry when full,
//!   so `undo` and `redo` can each hold `capacity` snapshots.
//!
//! `undo`/`redo` take the current scene and return the snapshot to restore; they do not
//! mutate the caller's scene, because the caller owns it.

use diffuse_scene::scene_runtime::SceneRuntime;

/// Undo/redo history of whole scene snapshots.
pub struct UndoStack {
    capacity: usize,
    undo_entries: Vec<SceneRuntime>,
    redo_entries: Vec<SceneRuntime>,
}

impl UndoStack {
    /// Swift defaulted `capacity` to 64.
    pub fn new(capacity: usize) -> Self {
        UndoStack {
            // At least one entry: a zero-capacity stack could never undo anything.
            capacity: capacity.max(1),
            undo_entries: Vec::new(),
            redo_entries: Vec::new(),
        }
    }

    #[inline]
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    #[inline]
    pub fn can_undo(&self) -> bool {
        !self.undo_entries.is_empty()
    }

    #[inline]
    pub fn can_redo(&self) -> bool {
        !self.redo_entries.is_empty()
    }

    #[inline]
    pub fn undo_depth(&self) -> usize {
        self.undo_entries.len()
    }

    #[inline]
    pub fn redo_depth(&self) -> usize {
        self.redo_entries.len()
    }

    /// Record the scene **before** an apply. Clears the redo stack.
    pub fn push(&mut self, scene: SceneRuntime) {
        if self.undo_entries.len() >= self.capacity {
            self.undo_entries.remove(0);
        }
        self.undo_entries.push(scene);
        self.redo_entries.clear();
    }

    /// Pop the previous scene, saving `current` onto the redo stack.
    ///
    /// Returns `None` when there is nothing to undo, in which case `current` is not
    /// saved — matching Swift, where the `guard` returned before touching `redo`.
    pub fn undo(&mut self, current: SceneRuntime) -> Option<SceneRuntime> {
        let snapshot = self.undo_entries.pop()?;
        if self.redo_entries.len() >= self.capacity {
            self.redo_entries.remove(0);
        }
        self.redo_entries.push(current);
        Some(snapshot)
    }

    /// Pop the most recently undone scene, saving `current` back onto the undo stack.
    pub fn redo(&mut self, current: SceneRuntime) -> Option<SceneRuntime> {
        let snapshot = self.redo_entries.pop()?;
        if self.undo_entries.len() >= self.capacity {
            self.undo_entries.remove(0);
        }
        self.undo_entries.push(current);
        Some(snapshot)
    }

    pub fn clear(&mut self) {
        self.undo_entries.clear();
        self.redo_entries.clear();
    }
}

impl Default for UndoStack {
    fn default() -> Self {
        UndoStack::new(64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::scene_bootstrap::SceneNameComponent;

    /// A scene carrying a marker so snapshots are distinguishable.
    fn scene(marker: &str) -> SceneRuntime {
        let mut runtime = SceneRuntime::new(ComponentRegistry::new());
        let entity = runtime.create_entity();
        runtime.set_component(SceneNameComponent::new(marker), entity);
        runtime
    }

    fn marker(runtime: &SceneRuntime) -> Option<String> {
        runtime
            .entities()
            .first()
            .and_then(|entity| runtime.component::<SceneNameComponent>(*entity))
            .map(|name| name.value)
    }

    #[test]
    fn a_fresh_stack_can_neither_undo_nor_redo() {
        let stack = UndoStack::new(4);
        assert!(!stack.can_undo());
        assert!(!stack.can_redo());
        assert_eq!(stack.undo_depth(), 0);
    }

    #[test]
    fn a_capacity_of_zero_becomes_one() {
        assert_eq!(UndoStack::new(0).capacity(), 1);
    }

    #[test]
    fn push_then_undo_restores_the_previous_scene() {
        let mut stack = UndoStack::new(4);
        stack.push(scene("first"));
        let restored = stack.undo(scene("second")).expect("an entry to undo");
        assert_eq!(marker(&restored), Some("first".to_string()));
        assert!(stack.can_redo());
    }

    #[test]
    fn pushing_clears_the_redo_stack() {
        let mut stack = UndoStack::new(4);
        stack.push(scene("first"));
        let _ = stack.undo(scene("second"));
        assert!(stack.can_redo());

        stack.push(scene("third"));
        assert!(
            !stack.can_redo(),
            "a new edit must invalidate the undone future"
        );
    }

    #[test]
    fn undo_on_an_empty_stack_returns_none_and_saves_nothing() {
        let mut stack = UndoStack::new(4);
        assert!(stack.undo(scene("x")).is_none());
        assert!(
            !stack.can_redo(),
            "nothing was undone, so nothing is redoable"
        );
    }

    #[test]
    fn redo_returns_the_undone_state() {
        let mut stack = UndoStack::new(4);
        stack.push(scene("first"));
        let _ = stack.undo(scene("second"));
        let restored = stack.redo(scene("first")).expect("an entry to redo");
        assert_eq!(marker(&restored), Some("second".to_string()));
        assert!(stack.can_undo());
        assert!(!stack.can_redo());
    }

    #[test]
    fn the_undo_stack_drops_the_oldest_entry_when_full() {
        let mut stack = UndoStack::new(2);
        stack.push(scene("a"));
        stack.push(scene("b"));
        stack.push(scene("c"));
        assert_eq!(stack.undo_depth(), 2, "capacity is respected");

        // Undoing twice must reach "b" then "c" — "a" was dropped.
        assert_eq!(
            marker(&stack.undo(scene("now")).unwrap()),
            Some("c".to_string())
        );
        assert_eq!(
            marker(&stack.undo(scene("c")).unwrap()),
            Some("b".to_string())
        );
        assert!(
            stack.undo(scene("b")).is_none(),
            "\"a\" must have been evicted"
        );
    }

    #[test]
    fn clear_empties_both_stacks() {
        let mut stack = UndoStack::new(4);
        stack.push(scene("a"));
        let _ = stack.undo(scene("b"));
        stack.clear();
        assert!(!stack.can_undo());
        assert!(!stack.can_redo());
    }
}
