//! Translation of
//! Editor/Sources/EditorUI/Panels/ScriptEditor/Hover/HoverOverlay.swift.
//!
//! The same coordinate tooltip used by controls and diagnostic messages owns
//! viewport fitting, clipping escape and node-lifetime cleanup.

use cove_ui_compose::modifiers::layout::{LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::SurfaceStyleExt;
use cove_ui_compose::primitives::overlays::{Tooltip, TooltipAnchor};
use cove_ui_compose::primitives::text::{MarkdownView, Text};
use cove_ui_compose::scene_core::Point;
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{AnyView, Column, EmptyView, HorizontalAlignment, Scope, TupleView, View};

use super::hover_presentation::{
    ScriptEditorHoverPresentation, ScriptHoverTextBlock, ScriptHoverTextRole,
};

pub struct ScriptHoverOverlay {
    pub presentation: ScriptEditorHoverPresentation,
}

impl ScriptHoverOverlay {
    pub fn new(presentation: ScriptEditorHoverPresentation) -> Self {
        ScriptHoverOverlay { presentation }
    }

    fn text_block(block: &ScriptHoverTextBlock) -> AnyView {
        let text = Text::new(block.text.clone());
        match block.role {
            ScriptHoverTextRole::Signature => AnyView::new(
                text.line_limit(Some(8))
                    .semantic_font(SemanticFontRef::mono())
                    .semantic_foreground(SemanticColorRef::on_surface()),
            ),
            ScriptHoverTextRole::Body => AnyView::new(
                text.line_limit(Some(12))
                    .semantic_font(SemanticFontRef::caption())
                    .semantic_foreground(SemanticColorRef::on_surface_muted()),
            ),
        }
    }
}

impl View for ScriptHoverOverlay {
    fn body(&self, _scope: &Scope) -> AnyView {
        let Some(anchor) = self.presentation.anchor else {
            return AnyView::new(EmptyView);
        };
        let text_blocks = self.presentation.text_blocks();
        if text_blocks.is_empty() {
            return AnyView::new(EmptyView);
        }
        let mut blocks: Vec<AnyView> = Vec::new();
        if let Some(markdown) = self
            .presentation
            .content
            .as_ref()
            .and_then(|content| content.markdown.as_ref())
        {
            blocks.push(AnyView::new(MarkdownView::new(markdown.clone()).frame(
                None,
                None,
                None,
                None,
                Some(440.0),
                Some(360.0),
            )));
        } else {
            blocks.extend(text_blocks.iter().map(Self::text_block));
        }
        let content = Column::new(
            HorizontalAlignment::Leading,
            6.0,
            AnyView::new(TupleView::new(blocks)),
        )
        .padding_edges(10.0, 8.0)
        .floating_surface(6.0);
        AnyView::new(
            Tooltip::anchored(
                TooltipAnchor::Point(Point::new(anchor.window_x, anchor.window_y)),
                content,
            )
            .configure(|options| {
                options.max_width = 460.0;
                options.gap = 18.0;
            }),
        )
    }
}
