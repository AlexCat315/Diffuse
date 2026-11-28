//! Scene outline selection from HierarchyPanel.swift.

use std::rc::Rc;

use cove_ui_compose::modifiers::layout::PaddingExt;
use cove_ui_compose::primitives::controls::Button;
use cove_ui_compose::primitives::layout::ScrollView;
use cove_ui_compose::theme::styles::buttons::{ButtonStyleViewExt, ghost};
use cove_ui_compose::{AnyView, Column, HorizontalAlignment, Scope, TupleView, View, ViewExt};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::scene::models::editor_scene_node::EditorSceneNode;
use diffuse_editor_core::state::editor_reducer::EditorAction;

pub struct HierarchyPanel(pub Rc<EditorApplication>);

impl View for HierarchyPanel {
    fn body(&self, _scope: &Scope) -> AnyView {
        self.0.store.scene_revision();
        let selected = self.0.store.selected_entity_ids();
        let mut rows = Vec::new();
        for root in self.0.scene.roots() {
            append_rows(&self.0, &root, &selected, 0, &mut rows);
        }
        AnyView::new(ScrollView::vertical(
            Column::new(HorizontalAlignment::Leading, 2.0, AnyView::new(TupleView::new(rows))).padding(4.0),
        ))
    }
}

fn append_rows(
    app: &Rc<EditorApplication>, node: &EditorSceneNode,
    selected: &std::collections::BTreeSet<u64>, depth: u32, rows: &mut Vec<AnyView>,
) {
    let id = node.id;
    let store = app.store.clone();
    rows.push(AnyView::new(Button::title(node.name.clone(), move || {
        store.dispatch(EditorAction::SetSelectedEntity(Some(id)));
    }).selected(selected.contains(&id)).button_style(ghost()).padding_edges(8.0 * depth as f32, 0.0).id(id)));
    for child in &node.children {
        append_rows(app, child, selected, depth + 1, rows);
    }
}
