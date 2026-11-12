//! `Editor/Sources/EditorUI/Commands/Policy.swift`.
//!
//! One command policy for menus, the palette, keyboard dispatch and native menus.
//! Scene editing follows the scene; file commands follow files. Panels, playback
//! and builds stay available whatever the window centers on.

use diffuse_editor_core::state::editor_state::PlaybackState;
use diffuse_editor_core::state::workspace::content::EditorContent;
use diffuse_editor_core::state::workspace::editor_workspace_profile::EditorWorkflowFeature;

use crate::commands::command::EditorCommand;

pub struct EditorWorkspaceCommandPolicy;

impl EditorWorkspaceCommandPolicy {
    pub fn allows(command: &EditorCommand, content: EditorContent) -> bool {
        let features = content.profile().features;
        match command {
            EditorCommand::ShowSceneSettings
            | EditorCommand::NewScene
            | EditorCommand::OpenScene
            | EditorCommand::SaveScene
            | EditorCommand::DuplicateSelection
            | EditorCommand::DeleteSelection
            | EditorCommand::SelectAll
            | EditorCommand::ClearSelection
            | EditorCommand::InvertSelection
            | EditorCommand::SelectDescendants
            | EditorCommand::SpawnEntity(_)
            | EditorCommand::CreateGeometry(_)
            | EditorCommand::FrameSelection
            | EditorCommand::ToggleSelectionVisibility
            | EditorCommand::ToggleSelectionLock => {
                features.contains(&EditorWorkflowFeature::Scene)
            }
            EditorCommand::SaveDocument
            | EditorCommand::RevertDocument
            | EditorCommand::CloseDocument => features.contains(&EditorWorkflowFeature::Documents),
            _ => true,
        }
    }
}

pub struct EditorPlaybackCommandPolicy;

impl EditorPlaybackCommandPolicy {
    pub fn can_transition(from: PlaybackState, to: PlaybackState) -> bool {
        from.can_transition(to)
    }

    /// Play from stopped or paused; pause while playing.
    pub fn toggle_target(from: PlaybackState) -> PlaybackState {
        if from == PlaybackState::Playing {
            PlaybackState::Paused
        } else {
            PlaybackState::Playing
        }
    }
}

pub struct EditorSceneAuthoringPolicy;

impl EditorSceneAuthoringPolicy {
    pub fn can_edit_scene(during: PlaybackState) -> bool {
        during == PlaybackState::Stopped
    }
}
