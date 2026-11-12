//! Translation of Editor/Sources/EditorUI/Shell/About.swift.

use cove_ui_compose::modifiers::layout::PaddingExt;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{Align, FlexDirection, Justify, Wrap};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{AnyView, BoxView, Scope, TupleView, View};

use crate::localization::localized;

pub struct EditorAboutView;

impl EditorAboutView {
    pub fn new() -> Self {
        EditorAboutView
    }

    /// Swift read `CFBundleShortVersionString`/`CFBundleVersion`; the Rust
    /// build carries the workspace version and no separate build number.
    fn version_text() -> String {
        format!("{} {}", localized("Version"), env!("CARGO_PKG_VERSION"))
    }
}

impl Default for EditorAboutView {
    fn default() -> Self {
        EditorAboutView::new()
    }
}

impl View for EditorAboutView {
    fn body(&self, _scope: &Scope) -> AnyView {
        let line = |text: String, font, color| {
            AnyView::new(
                Text::new(text)
                    .semantic_font(font)
                    .semantic_foreground(color),
            )
        };
        AnyView::new(
            BoxView::new(
                FlexDirection::Column,
                Align::Center,
                Justify::Center,
                Wrap::NoWrap,
                12.0,
                AnyView::new(TupleView::new(vec![
                    line(
                        "Diffuse".to_string(),
                        SemanticFontRef::title(),
                        SemanticColorRef::on_surface(),
                    ),
                    line(
                        Self::version_text(),
                        SemanticFontRef::body(),
                        SemanticColorRef::on_surface_variant(),
                    ),
                    line(
                        localized(
                            "An AI-assisted workstation for code, games, animation and video.",
                        ),
                        SemanticFontRef::caption(),
                        SemanticColorRef::on_surface_muted(),
                    ),
                    line(
                        "© 2026 Diffuse".to_string(),
                        SemanticFontRef::caption(),
                        SemanticColorRef::on_surface_muted(),
                    ),
                ])),
            )
            .padding(28.0)
            .semantic_background(SemanticColorRef::surface()),
        )
    }
}
