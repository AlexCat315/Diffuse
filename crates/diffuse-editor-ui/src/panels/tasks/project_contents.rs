//! Translation of Editor/Sources/EditorUI/Panels/Tasks/ProjectContents.swift.
//!
//! The sections the task plugin described, such as products, targets and
//! dependencies.

use cove_ui_compose::modifiers::layout::{EdgeInsets, FlexExt, LayoutFrameExt, PaddingExt};
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{
    AnyView, Column, FrameDimension, HorizontalAlignment, LayoutDebugExt, Row, Scope, TupleView,
    VerticalAlignment, View,
};
use diffuse_editor_core::tasks::results::{
    TaskProjectDescription, TaskProjectItem, TaskProjectSection,
};

use crate::localization::localized;

pub struct TaskProjectContents {
    pub description: Option<TaskProjectDescription>,
}

impl TaskProjectContents {
    pub fn new(description: Option<TaskProjectDescription>) -> Self {
        TaskProjectContents { description }
    }

    fn section(section: &TaskProjectSection) -> AnyView {
        let title = AnyView::new(
            Text::new(localized(&section.title))
                .line_limit(Some(1))
                .semantic_font(SemanticFontRef::caption())
                .semantic_foreground(SemanticColorRef::on_surface_variant())
                .padding_insets(EdgeInsets::new(8.0, 10.0, 2.0, 10.0)),
        );
        let items: Vec<AnyView> = section.items.iter().map(Self::item).collect();
        AnyView::new(Column::new(
            HorizontalAlignment::Leading,
            2.0,
            AnyView::new(TupleView::new(
                std::iter::once(title).chain(items).collect(),
            )),
        ))
    }

    fn item(item: &TaskProjectItem) -> AnyView {
        let name = AnyView::new(
            Text::new(item.name.clone())
                .line_limit(Some(1))
                .semantic_font(SemanticFontRef::mono())
                .semantic_foreground(SemanticColorRef::on_surface())
                .flex_with(0.0, 1.0, None)
                .frame(None, None, Some(0.0), None, None, None),
        );
        let detail = AnyView::new(
            Text::new(item.detail.clone())
                .line_limit(Some(1))
                .semantic_font(SemanticFontRef::caption())
                .semantic_foreground(SemanticColorRef::on_surface_muted())
                .flex_with(1.0, 1.0, None)
                .frame(None, None, Some(0.0), None, None, None),
        );
        AnyView::new(
            Row::new(
                VerticalAlignment::Center,
                8.0,
                AnyView::new(TupleView::new(vec![name, detail])),
            )
            .padding_edges(14.0, 3.0)
            .frame(
                Some(FrameDimension::Percent(100.0)),
                None,
                Some(0.0),
                None,
                None,
                None,
            ),
        )
    }
}

impl View for TaskProjectContents {
    fn body(&self, _scope: &Scope) -> AnyView {
        let sections: Vec<AnyView> = self
            .description
            .as_ref()
            .map(|description| description.sections.iter().map(Self::section).collect())
            .unwrap_or_default();
        AnyView::new(
            Column::new(
                HorizontalAlignment::Leading,
                2.0,
                AnyView::new(TupleView::new(sections)),
            )
            .frame(
                Some(FrameDimension::Percent(100.0)),
                None,
                Some(0.0),
                None,
                None,
                None,
            )
            .debug_name("tasks-project"),
        )
    }
}
