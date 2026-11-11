//! Translation of Editor/Sources/EditorCore/State/StoreScope.swift.
//!
//! Carries the store down the view tree without wrapping it in composition
//! locals: the content closure receives the store directly.

use std::rc::Rc;

use cove_ui_compose::{AnyView, Scope, View};

use crate::state::editor_store::EditorStore;

pub struct StoreScope<Content: View + Clone + 'static> {
    pub store: EditorStore,
    pub content: Rc<dyn Fn(&EditorStore) -> Content>,
}

impl<Content: View + Clone + 'static> StoreScope<Content> {
    pub fn new(store: EditorStore, content: impl Fn(&EditorStore) -> Content + 'static) -> Self {
        StoreScope {
            store,
            content: Rc::new(content),
        }
    }
}

impl<Content: View + Clone + 'static> View for StoreScope<Content> {
    fn body(&self, _scope: &Scope) -> AnyView {
        AnyView::new((self.content)(&self.store))
    }
}
