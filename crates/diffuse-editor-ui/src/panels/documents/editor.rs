//! Open document tabs and editing from Documents/Editor.swift.

use std::rc::Rc;
use std::sync::{Arc, Mutex};

use cove_ui_compose::modifiers::layout::{FlexExt, PaddingExt};
use cove_ui_compose::primitives::controls::Button;
use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use cove_ui_compose::primitives::text::text_field::TextField;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{Align, Binding, FlexDirection, Justify, State, Wrap};
use cove_ui_compose::theme::styles::buttons::{ButtonStyleViewExt, ghost};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{AnyView, BoxView, Row, Scope, Spacer, TupleView, VerticalAlignment, View, ViewExt};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::workstation::documents::{EditorDocumentSnapshot, EditorDocumentWorkspace};

use crate::localization::localized;

pub struct DocumentEditorPanel {
    application: Rc<EditorApplication>,
    snapshot: State<EditorDocumentSnapshot>,
    token: u64,
}

impl DocumentEditorPanel {
    pub fn new(application: Rc<EditorApplication>) -> Self {
        let documents = &application.workstation.documents;
        let snapshot = State::new(documents.snapshot());
        let observed = snapshot.clone();
        let weak = Arc::downgrade(documents);
        let updates = Mutex::new(());
        let refresh = Arc::new(move || {
            let _update = updates.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(documents) = weak.upgrade() {
                observed.set(documents.snapshot());
            }
        });
        let token = documents.register_observer(refresh.clone());
        refresh();
        Self { application, snapshot, token }
    }
}

impl Drop for DocumentEditorPanel {
    fn drop(&mut self) {
        self.application.workstation.documents.unregister_observer(self.token);
    }
}

impl View for DocumentEditorPanel {
    fn body(&self, _scope: &Scope) -> AnyView {
        let snapshot = self.snapshot.get();
        let documents = &self.application.workstation.documents;
        let mut views = Vec::new();
        if let Some(error) = &snapshot.error {
            views.push(AnyView::new(Text::new(error.clone()).semantic_foreground(SemanticColorRef::error()).padding(6.0)));
        }
        let Some(selected) = snapshot.selected() else {
            views.push(AnyView::new(Text::new(localized("No file open")).padding(12.0)));
            return document_column(views);
        };
        let mut tabs = snapshot.documents.iter().map(|document| {
            let model = documents.clone();
            let path = document.path.clone();
            let title = std::path::Path::new(&path).file_name().and_then(|value| value.to_str()).unwrap_or(&path);
            let title = if document.is_dirty() { format!("{title} •") } else { title.to_owned() };
            AnyView::new(Button::title(title, move || model.open(&path))
                .selected(document.path == selected.path).button_style(ghost()).id(document.path.clone()))
        }).collect::<Vec<_>>();
        tabs.push(AnyView::new(Spacer::default()));
        tabs.push(AnyView::new(Button::title(localized("Save"), {
            let application = self.application.clone();
            let path = selected.path.clone();
            move || { application.save_document_formatting(&path); }
        }).button_style(ghost())));
        views.push(AnyView::new(Row::new(VerticalAlignment::Center, 4.0, AnyView::new(TupleView::new(tabs))).padding(4.0)));
        let buffer = document_binding(documents, &selected.path);
        views.push(AnyView::new(
            TextField::new("", buffer)
                .multiline()
                .semantic_font(SemanticFontRef::mono())
                .flex(1.0)
                .id(selected.path.clone()),
        ));
        document_column(views)
    }
}

fn document_binding(model: &Arc<EditorDocumentWorkspace>, path: &str) -> Binding<TextBuffer> {
    Binding::new(
        {
            let model = model.clone();
            let path = path.to_owned();
            move || model.documents().into_iter().find(|document| document.path == path)
                .map(|document| TextBuffer::from(document.text)).unwrap_or_default()
        },
        {
            let model = model.clone();
            let path = path.to_owned();
            move |buffer: TextBuffer| model.edit(&path, &buffer.string_value())
        },
    )
}

fn document_column(views: Vec<AnyView>) -> AnyView {
    AnyView::new(BoxView::new(FlexDirection::Column, Align::Stretch, Justify::FlexStart, Wrap::NoWrap, 0.0, AnyView::new(TupleView::new(views))))
}
