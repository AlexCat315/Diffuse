//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Shared/DeveloperStatComponents.swift.
//!
//! Shared label/value blocks for the developer panels. Swift's `.font(.bodyStrong)`
//! / `.foregroundColor(.onSurface)` become Cove's semantic typography and color
//! modifiers, so these rows follow the active theme.

use cove_ui_compose::modifiers::layout::{FlexExt, LayoutFrameExt, PaddingExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{Align, FlexDirection, Justify, Wrap};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{
    AnyView, BoxView, Column, EmptyView, HorizontalAlignment, Row, Scope, TupleView,
    VerticalAlignment, View,
};

pub struct StatGroup<Content: View + Clone + 'static> {
    pub title: String,
    pub content: Content,
}

impl<Content: View + Clone + 'static> StatGroup<Content> {
    pub fn new(title: impl Into<String>, content: Content) -> Self {
        StatGroup {
            title: title.into(),
            content,
        }
    }
}

impl<Content: View + Clone + 'static> View for StatGroup<Content> {
    fn body(&self, _scope: &Scope) -> AnyView {
        let accent_bar = AnyView::new(
            AnyView::new(BoxView::new(
                FlexDirection::Column,
                Align::Stretch,
                Justify::FlexStart,
                Wrap::NoWrap,
                0.0,
                AnyView::new(EmptyView),
            ))
            .frame(
                Some(cove_ui_compose::FrameDimension::Points(3.0)),
                Some(cove_ui_compose::FrameDimension::Points(16.0)),
                None,
                None,
                None,
                None,
            )
            .semantic_background(SemanticColorRef::accent())
            .corner_radius(2.0),
        );
        let title = AnyView::new(
            Text::new(self.title.clone())
                .line_limit(Some(1))
                .semantic_font(SemanticFontRef::body_strong())
                .semantic_foreground(SemanticColorRef::on_surface())
                .flex_with(1.0, 1.0, None),
        );
        let header = AnyView::new(
            Row::new(
                VerticalAlignment::Center,
                6.0,
                AnyView::new(TupleView::new(vec![accent_bar, title])),
            )
            .padding_edges(10.0, 7.0),
        );
        let content = AnyView::new(
            Column::new(
                HorizontalAlignment::Leading,
                0.0,
                AnyView::new(self.content.clone()),
            )
            .padding_edges(4.0, 6.0),
        );
        AnyView::new(
            Column::new(
                HorizontalAlignment::Leading,
                6.0,
                AnyView::new(TupleView::new(vec![header, content])),
            )
            .semantic_background(SemanticColorRef::surface_sunken())
            .corner_radius(6.0)
            .semantic_border(SemanticColorRef::border(), 1.0),
        )
    }
}

pub struct StatRow {
    pub label: String,
    pub value: String,
}

impl StatRow {
    pub fn new(label: impl Into<String>, value: impl Into<String>) -> Self {
        StatRow {
            label: label.into(),
            value: value.into(),
        }
    }
}

impl View for StatRow {
    fn body(&self, _scope: &Scope) -> AnyView {
        let label = AnyView::new(
            Text::new(self.label.clone())
                .line_limit(Some(1))
                .semantic_font(SemanticFontRef::caption())
                .semantic_foreground(SemanticColorRef::on_surface_muted())
                .flex_with(1.0, 1.0, Some(82.0)),
        );
        let value = AnyView::new(
            Text::new(self.value.clone())
                .line_limit(Some(1))
                .semantic_font(SemanticFontRef::mono())
                .semantic_foreground(SemanticColorRef::on_surface())
                .flex_with(1.0, 1.0, Some(70.0)),
        );
        AnyView::new(
            Row::new(
                VerticalAlignment::Center,
                8.0,
                AnyView::new(TupleView::new(vec![label, value])),
            )
            .padding_edges(8.0, 2.0),
        )
    }
}

pub struct StatWrappedValue {
    pub label: String,
    pub value: String,
}

impl StatWrappedValue {
    pub fn new(label: impl Into<String>, value: impl Into<String>) -> Self {
        StatWrappedValue {
            label: label.into(),
            value: value.into(),
        }
    }
}

impl View for StatWrappedValue {
    fn body(&self, _scope: &Scope) -> AnyView {
        let label = AnyView::new(
            Text::new(self.label.clone())
                .semantic_font(SemanticFontRef::caption())
                .semantic_foreground(SemanticColorRef::on_surface_muted())
                .padding_edges(8.0, 2.0),
        );
        let value = AnyView::new(
            Text::new(self.value.clone())
                .line_limit(Some(3))
                .semantic_font(SemanticFontRef::mono())
                .semantic_foreground(SemanticColorRef::on_surface())
                .padding_edges(8.0, 2.0),
        );
        AnyView::new(Column::new(
            HorizontalAlignment::Leading,
            0.0,
            AnyView::new(TupleView::new(vec![label, value])),
        ))
    }
}
