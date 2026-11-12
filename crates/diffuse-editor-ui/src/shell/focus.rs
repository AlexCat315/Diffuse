//! `Editor/Sources/EditorUI/Shell/Focus.swift`.
//!
//! What the window is working on: the open document in text Spaces, the
//! selected entity in scene Spaces. The title bar, the ⌘K palette and the
//! Agent composer all read this one value, so their context never disagrees.

use cove_ui_compose::core_exports::cove_imaging::BundleImageResource;
use cove_ui_compose::modifiers::interaction::AccessibilityExt;
use cove_ui_compose::modifiers::layout::FlexExt;
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::prelude::{LayoutFrameExt, PaddingExt, SemanticStyleViewExt};
use cove_ui_compose::primitives::media::{Icon, ui_icon_catalog};
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef};
use cove_ui_compose::{AnyView, LayoutDebugExt, Row, Scope, VerticalAlignment, View};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::workstation::documents::EditorDocumentSnapshot;

use crate::localization::localized;
use crate::panels::documents::kind::FileIcon;

/// What the window is working on.
pub struct EditorWorkFocus {
    pub trail: Vec<String>,
    pub leaf: Option<String>,
    pub leaf_icon: Option<BundleImageResource>,
    /// Set for a document leaf: its file icon replaces `leafIcon`.
    pub leaf_path: Option<String>,
    pub is_dirty: bool,
}

impl EditorWorkFocus {
    pub fn new(app: &EditorApplication, snapshot: &EditorDocumentSnapshot) -> Self {
        let mut focus = EditorWorkFocus {
            trail: Vec::new(),
            leaf: None,
            leaf_icon: None,
            leaf_path: None,
            is_dirty: false,
        };
        if app.store.content()
            != diffuse_editor_core::state::workspace::content::EditorContent::Scene
        {
            let Some(path) = snapshot.selected_path.clone() else {
                return focus;
            };
            let parts = path.split('/').map(str::to_string).collect::<Vec<_>>();
            focus.trail = parts
                .iter()
                .take(parts.len().saturating_sub(1))
                .cloned()
                .collect();
            focus.leaf = parts.last().cloned();
            focus.leaf_path = Some(path);
            focus.is_dirty = snapshot
                .selected()
                .is_some_and(|document| document.is_dirty());
            return focus;
        }
        let entity = app.scene.entity_summary(app.store.selected_entity_id());
        focus.leaf = entity.as_ref().map(|summary| summary.name.clone());
        focus.leaf_icon = entity.map(|_| ui_icon_catalog::editor::box_());
        focus
    }
}

/// Compact chip naming the focus leaf, used beside text inputs. Callers decide
/// whether it shows: a body that appears later would be appended out of order.
pub struct EditorFocusChip {
    pub focus: EditorWorkFocus,
}

impl View for EditorFocusChip {
    fn body(&self, _scope: &Scope) -> AnyView {
        let leaf = self.focus.leaf.clone().unwrap_or_default();
        let leading = if let Some(path) = self.focus.leaf_path.as_ref() {
            Some(AnyView::new(FileIcon::new(path.clone(), 12.0)))
        } else {
            self.focus.leaf_icon.clone().map(|icon| {
                AnyView::new(Icon::with_semantic(icon, 11.0, SemanticColorRef::accent()))
            })
        };
        let label = leaf.clone();
        let text = Text::new(leaf.clone())
            .line_limit(Some(1))
            .semantic_font(SemanticFontRef::caption())
            .semantic_foreground(SemanticColorRef::on_surface_variant())
            .flex_with(0.0, 1.0, None)
            .frame(None, None, Some(0.0), None, None, None);
        let mut children = Vec::new();
        if let Some(leading) = leading {
            children.push(leading);
        }
        children.push(AnyView::new(text));
        AnyView::new(
            Row::new(
                VerticalAlignment::Center,
                5.0,
                AnyView::new(cove_ui_compose::TupleView::new(children)),
            )
            .padding_edges(6.0, 3.0)
            .semantic_background(SemanticColorRef::surface_variant())
            .corner_radius(4.0)
            .frame(None, None, None, None, Some(220.0), None)
            .accessibility(move |semantics| {
                semantics.label = format!("{} {}", localized("Context"), label)
            })
            .debug_name("editor-focus-chip"),
        )
    }
}
