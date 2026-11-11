//! `Editor/Sources/EditorCore/State/Workspace/EditorWorkspaceProfile.swift` — the
//! tools one kind of content offers, shared by the inspector, commands and
//! assistant. Panels are not gated: every panel stays reachable from any content.

use std::collections::BTreeSet;

use cove_agent::ui_tools::Tools as UIDiagnosticTools;

use crate::state::workspace::content::EditorContent;

/// Cafeteria of workflow capabilities a content profile can grant.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum EditorWorkflowFeature {
    Documents,
    Media,
    Scene,
    Rendering,
    Animation,
    Simulation,
    Gameplay,
    Scripting,
    GameBuild,
}

impl EditorWorkflowFeature {
    /// The Swift raw value of the feature.
    pub fn raw_value(self) -> &'static str {
        match self {
            EditorWorkflowFeature::Documents => "documents",
            EditorWorkflowFeature::Media => "media",
            EditorWorkflowFeature::Scene => "scene",
            EditorWorkflowFeature::Rendering => "rendering",
            EditorWorkflowFeature::Animation => "animation",
            EditorWorkflowFeature::Simulation => "simulation",
            EditorWorkflowFeature::Gameplay => "gameplay",
            EditorWorkflowFeature::Scripting => "scripting",
            EditorWorkflowFeature::GameBuild => "gameBuild",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorWorkspaceProfile {
    pub features: BTreeSet<EditorWorkflowFeature>,
}

impl EditorWorkspaceProfile {
    pub fn new(features: BTreeSet<EditorWorkflowFeature>) -> Self {
        EditorWorkspaceProfile { features }
    }

    /// Swift's `static let builtInPanelIDs`.
    pub fn built_in_panel_ids() -> BTreeSet<String> {
        [
            "sidebar",
            "details",
            "viewport",
            "hierarchy",
            "assets",
            "console",
            "files",
            "documents",
            "media",
            "developer-tools",
            "animation",
            "render-pipeline",
            "terminal",
            "source-control",
            "tasks",
        ]
        .into_iter()
        .map(str::to_string)
        .collect()
    }

    pub fn profile(content: EditorContent) -> Self {
        match content {
            EditorContent::Scene => Self::new(
                [
                    EditorWorkflowFeature::Scene,
                    EditorWorkflowFeature::Rendering,
                    EditorWorkflowFeature::Animation,
                    EditorWorkflowFeature::Simulation,
                    EditorWorkflowFeature::Gameplay,
                    EditorWorkflowFeature::Scripting,
                    EditorWorkflowFeature::GameBuild,
                ]
                .into_iter()
                .collect(),
            ),
            // Scripts are files, so their tools come along.
            EditorContent::Files => Self::new(
                [
                    EditorWorkflowFeature::Documents,
                    EditorWorkflowFeature::Scripting,
                ]
                .into_iter()
                .collect(),
            ),
            EditorContent::Timeline => Self::new(
                [
                    EditorWorkflowFeature::Media,
                    EditorWorkflowFeature::Documents,
                ]
                .into_iter()
                .collect(),
            ),
        }
    }

    pub fn capability_ids(&self) -> BTreeSet<String> {
        if !self.features.contains(&EditorWorkflowFeature::Scene) {
            return BTreeSet::new();
        }
        let mut ids: BTreeSet<String> = [
            "scene.get_entities",
            "scene.get_selection",
            "scene.find_entities",
            "scene.describe_components",
            "scene.spawn_entity",
            "scene.delete_entity",
            "scene.duplicate_entity",
            "scene.reparent_entity",
            "scene.set_name",
            "scene.set_transform",
            "scene.snap_to_ground",
            "scene.set_light_type",
            "scene.set_light_intensity",
            "scene.set_light_color",
            "scene.set_light_range",
            "scene.set_light_spot_angles",
            "scene.set_light_cast_shadows",
            "scene.set_camera_pose",
            "scene.set_camera_fov",
            "scene.set_camera_aspect_ratio",
            "scene.set_camera_active",
            "scene.set_mesh_color",
            "scene.set_material",
            "scene.set_mesh_visibility",
        ]
        .into_iter()
        .map(str::to_string)
        .collect();
        if self.features.contains(&EditorWorkflowFeature::Simulation) {
            ids.extend(
                [
                    "scene.set_rigid_body_motion_type",
                    "scene.set_rigid_body_mass",
                    "scene.set_rigid_body_gravity_scale",
                    "scene.set_rigid_body_allow_sleep",
                    "scene.set_collider_shape",
                    "scene.set_collider_box_extents",
                    "scene.set_collider_sphere_radius",
                    "scene.set_collider_capsule",
                    "scene.set_collider_material",
                    "scene.set_constraint_enabled",
                ]
                .into_iter()
                .map(str::to_string),
            );
        }
        if self.features.contains(&EditorWorkflowFeature::Gameplay) {
            ids.extend(
                ["scene.set_collider_trigger", "scene.set_collider_layer"]
                    .into_iter()
                    .map(str::to_string),
            );
        }
        if self.features.contains(&EditorWorkflowFeature::Scripting) {
            ids.extend(
                ["scene.set_script_property", "scene.set_script_bindings"]
                    .into_iter()
                    .map(str::to_string),
            );
        }
        if self.features.contains(&EditorWorkflowFeature::Animation) {
            ids.extend(
                ["scene.set_animation_player", "scene.set_audio_source"]
                    .into_iter()
                    .map(str::to_string),
            );
        }
        ids
    }

    pub fn project_tool_names(&self) -> BTreeSet<String> {
        let mut names: BTreeSet<String> = [
            "respond",
            "get_project_info",
            "save_scene",
            "get_console_messages",
            "vcs_status",
            "vcs_diff",
            "vcs_log",
            "vcs_commit",
        ]
        .into_iter()
        .map(str::to_string)
        .collect();
        names.extend(UIDiagnosticTools::tools().into_iter().map(|tool| tool.name));
        if self.features.contains(&EditorWorkflowFeature::Documents) {
            names.extend(
                ["list_files", "read_file", "write_file"]
                    .into_iter()
                    .map(str::to_string),
            );
        }
        if self.features.contains(&EditorWorkflowFeature::Media) {
            names.extend(
                [
                    "get_media_timeline",
                    "add_media_clip",
                    "trim_media_clip",
                    "remove_media_clip",
                    "save_media_timeline",
                    "export_media",
                ]
                .into_iter()
                .map(str::to_string),
            );
        }
        if !self.features.contains(&EditorWorkflowFeature::Scene) {
            names.remove("save_scene");
        }
        if self.features.contains(&EditorWorkflowFeature::Scripting) {
            names.extend(
                [
                    "get_scripting_api",
                    "list_scripts",
                    "read_script",
                    "write_script",
                    "compile_scripts",
                ]
                .into_iter()
                .map(str::to_string),
            );
        }
        if self.features.contains(&EditorWorkflowFeature::Gameplay) {
            names.extend(
                ["get_runtime_state", "set_playback_state"]
                    .into_iter()
                    .map(str::to_string),
            );
        }
        if self.features.contains(&EditorWorkflowFeature::GameBuild) {
            names.insert("export_project".to_string());
        }
        names
    }
}
