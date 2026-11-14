//! `Editor/Sources/EditorCore/Scene/History/EditorSceneEditHistory.swift`.
//!
//! Owns snapshot history and grouping; the adapter owns scene replacement and
//! revision notifications. A history entry is created only for a changed revision.

use std::collections::BTreeSet;
use std::rc::Rc;

use diffuse_intent::transactions::mutation_components::SceneComponentKey;
use diffuse_scene::scene_runtime::SceneRuntime;

type EditAction = Rc<dyn Fn() -> bool>;
type EditRefresh = Rc<dyn Fn()>;

enum Entry {
    Scene(SceneRuntime),
    Asset {
        undo: EditAction,
        redo: EditAction,
        refresh: EditRefresh,
    },
}

pub struct EditorSceneEditHistory {
    limit: usize,
    current_scene: Option<SceneRuntime>,
    undo_scenes: Vec<Entry>,
    redo_scenes: Vec<Entry>,
    group_depth: usize,
    group_start_scene: Option<SceneRuntime>,
    is_interactive_group_active: bool,
    interactive_component_keys: Option<BTreeSet<SceneComponentKey>>,
    has_interactive_revision: bool,
}

impl EditorSceneEditHistory {
    /// Swift's `init(limit: Int = 100)`.
    pub fn new() -> Self {
        Self::with_limit(100)
    }

    pub fn with_limit(limit: usize) -> Self {
        EditorSceneEditHistory {
            limit,
            current_scene: None,
            undo_scenes: Vec::new(),
            redo_scenes: Vec::new(),
            group_depth: 0,
            group_start_scene: None,
            is_interactive_group_active: false,
            interactive_component_keys: None,
            has_interactive_revision: false,
        }
    }

    pub fn can_undo(&self) -> bool {
        !self.undo_scenes.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_scenes.is_empty()
    }

    /// A file relocation changes identities in every snapshot. Undoing a
    /// transform must not bring back a resource path that no longer exists.
    pub fn remap_scenes(&mut self, update: impl Fn(&mut SceneRuntime)) {
        if let Some(current) = self.current_scene.as_mut() {
            update(current);
        }
        for entry in &mut self.undo_scenes {
            if let Entry::Scene(scene) = entry {
                update(scene);
            }
        }
        for entry in &mut self.redo_scenes {
            if let Entry::Scene(scene) = entry {
                update(scene);
            }
        }
        if let Some(start) = self.group_start_scene.as_mut() {
            update(start);
        }
    }

    pub fn record_revision_change(
        &mut self,
        scene: SceneRuntime,
        record_history: bool,
        component_keys: Option<BTreeSet<SceneComponentKey>>,
    ) {
        if record_history && let Some(previous) = self.current_scene.clone() {
            if self.group_depth == 0 {
                self.record(&previous, &scene);
            } else if self.is_interactive_group_active && self.group_depth == 1 {
                if self.has_interactive_revision
                    && self.interactive_component_keys != component_keys
                    && let Some(start) = self.group_start_scene.clone()
                {
                    self.record(&start, &previous);
                    self.group_start_scene = Some(previous);
                }
                self.interactive_component_keys = component_keys;
                self.has_interactive_revision = true;
            }
        }
        self.current_scene = Some(scene);
    }

    pub fn begin_group(&mut self, scene: &SceneRuntime) {
        if self.group_depth == 0 {
            self.group_start_scene =
                Some(self.current_scene.clone().unwrap_or_else(|| scene.clone()));
        }
        self.group_depth += 1;
    }

    pub fn end_group(&mut self, scene: &SceneRuntime) {
        if self.group_depth == 0 {
            return;
        }
        self.group_depth -= 1;
        if self.group_depth == 0 {
            if let Some(previous) = self.group_start_scene.take() {
                self.record(&previous, scene);
            }
            self.current_scene = Some(scene.clone());
        }
    }

    pub fn begin_interactive_group(&mut self, scene: &SceneRuntime) {
        if self.is_interactive_group_active {
            return;
        }
        self.interactive_component_keys = None;
        self.has_interactive_revision = false;
        self.is_interactive_group_active = true;
        self.begin_group(scene);
    }

    pub fn end_interactive_group(&mut self, scene: &SceneRuntime) {
        if !self.is_interactive_group_active {
            return;
        }
        self.is_interactive_group_active = false;
        self.interactive_component_keys = None;
        self.end_group(scene);
    }

    pub fn cancel_interactive_group(&mut self) -> Option<SceneRuntime> {
        if !self.is_interactive_group_active {
            return None;
        }
        self.is_interactive_group_active = false;
        self.interactive_component_keys = None;
        if self.group_depth == 0 {
            return None;
        }
        self.group_depth -= 1;
        if self.group_depth != 0 {
            return None;
        }
        let previous = self.group_start_scene.clone();
        if let Some(previous) = &previous {
            self.current_scene = Some(previous.clone());
        }
        self.group_start_scene = None;
        previous
    }

    pub(crate) fn asset_action(&self, redo: bool) -> Option<(EditAction, EditRefresh)> {
        let entry = if redo {
            self.redo_scenes.last()
        } else {
            self.undo_scenes.last()
        }?;
        match entry {
            Entry::Scene(_) => None,
            Entry::Asset {
                undo,
                redo: redo_action,
                refresh,
            } => Some((
                (if redo { redo_action } else { undo }).clone(),
                refresh.clone(),
            )),
        }
    }

    // The adapter runs a file action before completing its history step.
    pub(crate) fn complete_undo(&mut self, scene: SceneRuntime) -> Option<SceneRuntime> {
        let entry = self.undo_scenes.last()?;
        match entry {
            Entry::Scene(previous) => {
                let previous = previous.clone();
                self.undo_scenes.pop();
                self.redo_scenes.push(Entry::Scene(scene));
                self.current_scene = Some(previous.clone());
                Some(previous)
            }
            Entry::Asset { .. } => {
                let entry = self.undo_scenes.pop()?;
                self.redo_scenes.push(entry);
                Some(self.current_scene.clone().unwrap_or(scene))
            }
        }
    }

    pub(crate) fn complete_redo(&mut self, scene: SceneRuntime) -> Option<SceneRuntime> {
        let entry = self.redo_scenes.last()?;
        match entry {
            Entry::Scene(next) => {
                let next = next.clone();
                self.redo_scenes.pop();
                self.undo_scenes.push(Entry::Scene(scene));
                self.current_scene = Some(next.clone());
                Some(next)
            }
            Entry::Asset { .. } => {
                let entry = self.redo_scenes.pop()?;
                self.undo_scenes.push(entry);
                Some(self.current_scene.clone().unwrap_or(scene))
            }
        }
    }

    /// File-backed authoring edits share chronological ordering with scene edits.
    /// A failed restore keeps the entry available instead of consuming history.
    pub fn record_asset_edit(&mut self, undo: EditAction, redo: EditAction, refresh: EditRefresh) {
        self.undo_scenes.push(Entry::Asset {
            undo,
            redo,
            refresh,
        });
        self.trim_history();
        self.redo_scenes.clear();
    }

    pub fn reset(&mut self, scene: SceneRuntime) {
        self.undo_scenes.clear();
        self.redo_scenes.clear();
        self.group_depth = 0;
        self.group_start_scene = None;
        self.is_interactive_group_active = false;
        self.interactive_component_keys = None;
        self.current_scene = Some(scene);
    }

    fn record(&mut self, previous: &SceneRuntime, scene: &SceneRuntime) {
        if previous.snapshot().revision == scene.snapshot().revision {
            return;
        }
        self.undo_scenes.push(Entry::Scene(previous.clone()));
        self.trim_history();
        self.redo_scenes.clear();
    }

    fn trim_history(&mut self) {
        if self.undo_scenes.len() > self.limit {
            let excess = self.undo_scenes.len() - self.limit;
            self.undo_scenes.drain(..excess);
        }
    }
}

impl Default for EditorSceneEditHistory {
    fn default() -> Self {
        Self::new()
    }
}
