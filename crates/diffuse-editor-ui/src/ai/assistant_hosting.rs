//! `Editor/Sources/EditorUI/ai/AssistantHosting.swift`.
//!
//! What the agent UI needs from whatever owns a conversation.

use std::rc::Rc;

use diffuse_editor_core::state::editor_store::EditorStore;
use diffuse_editor_core::workstation::documents::EditorDocumentWorkspace;

use crate::ai::surface::{EditorAssistantSurface, EditorStudioView};

/// One segment of the window's view switch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorStudioViewSegment {
    pub view: EditorStudioView,
    pub title: String,
    pub icon: Option<String>,
}

impl EditorStudioViewSegment {
    pub fn new(view: EditorStudioView, title: impl Into<String>, icon: Option<String>) -> Self {
        EditorStudioViewSegment {
            view,
            title: title.into(),
            icon,
        }
    }
}

/// What the agent UI needs from whatever owns a conversation.
///
/// Two things own one: a project's `EditorApplication`, and the standalone host
/// the window uses when no project is open. Neither is the agent itself — the
/// agent comes from the plugin catalog — so the UI must not reach for
/// `EditorApplication` directly.
pub trait AssistantHosting {
    fn store(&self) -> &EditorStore;
    /// The view state (workbench / agent, canvas, draft) for this conversation.
    fn assistant_surface(&self) -> Rc<EditorAssistantSurface>;
    /// The top-level views this window can show: the workbench, plus every view
    /// an enabled package declared a panel for. Nothing here asks "is plugin X
    /// enabled" — a package contributes a view or it does not.
    fn studio_views(&self) -> Vec<EditorStudioView>;
    fn studio_view_segments(&self) -> Vec<EditorStudioViewSegment>;
    /// Whether any enabled package contributes an agent to talk to. This is a
    /// capability question, separate from whether a view exists.
    fn is_agent_enabled(&self) -> bool;
    fn is_ai_available(&self) -> bool;
    /// Scene edits are only allowed while authoring; a host without a scene is
    /// always authoring.
    fn is_scene_authoring_enabled(&self) -> bool;
    /// `None` when the host has no project: there is no document workspace then.
    fn documents(&self) -> Option<&EditorDocumentWorkspace>;

    fn submit_natural_language_intent(&self, text: &str) -> bool;
    fn cancel_agent_task(&self);
    fn open_assistant_settings(&self);

    fn has_studio_view(&self, view: &EditorStudioView) -> bool {
        self.studio_views().contains(view)
    }
}
