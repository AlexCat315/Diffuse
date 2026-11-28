//! Console records from EditorOutputPanel.swift.

use std::rc::Rc;

use cove_ui_compose::modifiers::layout::PaddingExt;
use cove_ui_compose::primitives::layout::ScrollView;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{AnyView, Column, HorizontalAlignment, Scope, TupleView, View, ViewExt};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::state::editor_state::EditorConsoleSeverity;

pub struct EditorOutputPanel(pub Rc<EditorApplication>);

impl View for EditorOutputPanel {
    fn body(&self, _scope: &Scope) -> AnyView {
        let rows = self.0.store.console_entries().into_iter().map(|entry| {
            let label = match entry.detail {
                Some(detail) => format!("{} · {detail}", entry.message),
                None => entry.message,
            };
            let tone = match entry.severity {
                EditorConsoleSeverity::Info => SemanticColorRef::on_surface_variant(),
                EditorConsoleSeverity::Warning => SemanticColorRef::warning(),
                EditorConsoleSeverity::Error => SemanticColorRef::error(),
            };
            AnyView::new(Text::new(label).semantic_font(SemanticFontRef::caption()).semantic_foreground(tone).id(entry.id))
        }).collect();
        AnyView::new(ScrollView::vertical(Column::new(
            HorizontalAlignment::Leading, 4.0, AnyView::new(TupleView::new(rows)),
        ).padding(8.0)))
    }
}
