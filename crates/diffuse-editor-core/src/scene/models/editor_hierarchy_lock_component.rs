//! `Editor/Sources/EditorCore/Scene/Models/EditorHierarchyLockComponent.swift`.

use diffuse_scene::entity_id::RuntimeComponent;

/// Editor-only component so hierarchy locks participate in SceneRuntime
/// snapshots, undo/redo and dirty revision tracking without leaking into game
/// manifests as a runtime feature.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct EditorHierarchyLockComponent;

impl RuntimeComponent for EditorHierarchyLockComponent {}
