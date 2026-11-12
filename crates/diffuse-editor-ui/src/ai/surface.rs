//! `Editor/Sources/EditorUI/ai/Surface.swift`.
//!
//! The top-level view a window can be in. The agent surface itself follows in a
//! later batch; the identity is what commands and the assistant host agree on.

use diffuse_editor_core::contributions::workbench::contributed::WorkbenchView;

/// A top-level view a window can be in.
///
/// The workbench is the editor's own. Every other view exists because an
/// enabled package declared a panel for it — the identity is the name the
/// package used, so no plugin needs its own `isXxxEnabled` flag.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EditorStudioView {
    pub id: String,
}

impl EditorStudioView {
    pub fn new(id: impl Into<String>) -> Self {
        EditorStudioView { id: id.into() }
    }

    pub fn make() -> Self {
        EditorStudioView::new("make")
    }

    /// The agent conversation, named exactly as a package names it.
    pub fn agent() -> Self {
        EditorStudioView::new(WorkbenchView::agent().raw_value)
    }
}
