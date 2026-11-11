//! Translation of Editor/Sources/EditorUI/Shell/CanvasChrome.swift.
//!
//! Paints chrome that hosts its own `.surface` background (the immersive title
//! bar) on the window canvas, so only panes read as raised blocks.

use std::rc::Rc;

use cove_ui_compose::theme::{Theme, ThemeReader, ThemeViewExt};
use cove_ui_compose::{AnyView, Scope, View};

pub struct EditorCanvasChrome<Content: View + Clone + 'static> {
    pub content: Rc<dyn Fn() -> Content>,
}

impl<Content: View + Clone + 'static> EditorCanvasChrome<Content> {
    pub fn new(content: impl Fn() -> Content + 'static) -> Self {
        EditorCanvasChrome {
            content: Rc::new(content),
        }
    }
}

impl<Content: View + Clone + 'static> View for EditorCanvasChrome<Content> {
    fn body(&self, _scope: &Scope) -> AnyView {
        let content = self.content.clone();
        AnyView::new(ThemeReader::new(move |theme: &Theme| {
            let mut canvas = theme.clone();
            canvas.colors.surface = theme.colors.background;
            (content)().theme(canvas)
        }))
    }
}
