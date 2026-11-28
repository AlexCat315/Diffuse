//! Project file browsing from Documents/Files.swift.

use std::sync::Arc;

use cove_ui_compose::modifiers::layout::{FlexExt, PaddingExt};
use cove_ui_compose::primitives::controls::Button;
use cove_ui_compose::primitives::layout::ScrollView;
use cove_ui_compose::primitives::text::{Text, text_buffer::TextBuffer};
use cove_ui_compose::theme::styles::buttons::{ButtonStyleViewExt, ghost};
use cove_ui_compose::{AnyView, Column, EmptyView, HorizontalAlignment, Scope, TupleView, View};
use diffuse_editor_core::workstation::documents::EditorDocumentWorkspace;

use crate::localization::localized;
use crate::panels::shared::editor_panel_components::EditorPanelSearchBar;

pub struct DocumentFilesPanel(pub Arc<EditorDocumentWorkspace>);

impl View for DocumentFilesPanel {
    fn body(&self, scope: &Scope) -> AnyView {
        let filter = scope.state(TextBuffer::default);
        let files = scope.state(|| self.0.files());
        let query = filter.get().string_value().to_lowercase();
        let files_now = files.get();
        let found = files_now.iter().filter(|path| query.is_empty() || path.to_lowercase().contains(&query));
        let rows = found.map(|path| {
            let model = self.0.clone();
            let path = path.clone();
            AnyView::new(Button::title(path.clone(), move || model.open(&path)).button_style(ghost()))
        }).collect::<Vec<_>>();
        let search = EditorPanelSearchBar::with_actions(
            localized("Filter files"), cove_ui_compose::scene_core::Binding::new(
                { let filter = filter.clone(); move || filter.get() },
                move |value| filter.set(value),
            ),
            Some(files_now.len().to_string()), None, None,
            None,
            AnyView::new(Button::title(localized("Refresh"), {
                let model = self.0.clone();
                move || files.set(model.files())
            }).button_style(ghost())),
        );
        let results = if rows.is_empty() {
            AnyView::new(
                Text::new(localized(if query.is_empty() { "No text files" } else { "No matching files" }))
                    .padding(10.0),
            )
        } else {
            AnyView::new(ScrollView::vertical(
                Column::new(HorizontalAlignment::Leading, 2.0, AnyView::new(TupleView::new(rows)))
                    .padding(4.0),
            ))
        };
        AnyView::new(Column::new(HorizontalAlignment::Leading, 0.0, AnyView::new(TupleView::new(vec![
            AnyView::new(search), AnyView::new(results.flex(1.0)), AnyView::new(EmptyView),
        ]))))
    }
}
