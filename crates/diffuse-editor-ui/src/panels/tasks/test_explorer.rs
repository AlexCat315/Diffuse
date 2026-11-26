//! Test results grouped in discovery order, with one run action per test.

use std::collections::HashMap;
use std::sync::Arc;

use cove_ui_compose::modifiers::interaction::AccessibilityExt;
use cove_ui_compose::modifiers::layout::{EdgeInsets, FlexExt, LayoutFrameExt, PaddingExt};
use cove_ui_compose::primitives::controls::{Button, ButtonIconSource};
use cove_ui_compose::primitives::feedback::Spinner;
use cove_ui_compose::primitives::media::{Icon, ui_icons};
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::theme::styles::buttons::{ButtonStyleViewExt, ToggleButtonStyle};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{
    AnyView, Column, FrameDimension, HorizontalAlignment, LayoutDebugExt, Row, Scope, TupleView,
    VerticalAlignment, View, ViewExt,
};
use diffuse_editor_core::tasks::results::{TaskSnapshot, TaskTest, TaskTestStatus};
use diffuse_editor_core::tasks::runner::EditorTasks;

use crate::localization::localized;

pub struct TestExplorer {
    pub model: Arc<EditorTasks>,
    pub snapshot: TaskSnapshot,
}

impl TestExplorer {
    fn group(&self, title: &str, tests: Vec<&TaskTest>, busy: bool) -> AnyView {
        let title = Text::new(title)
            .line_limit(Some(1))
            .semantic_font(SemanticFontRef::caption())
            .semantic_foreground(SemanticColorRef::on_surface_variant())
            .padding_insets(EdgeInsets::new(6.0, 10.0, 2.0, 10.0))
            .erased();
        let rows = std::iter::once(title)
            .chain(tests.into_iter().map(|test| self.row(test, busy)))
            .collect();
        Column::new(
            HorizontalAlignment::Leading,
            0.0,
            TupleView::new(rows).erased(),
        )
        .erased()
    }

    fn row(&self, test: &TaskTest, busy: bool) -> AnyView {
        let name = Text::new(test.name())
            .line_limit(Some(1))
            .semantic_font(SemanticFontRef::mono())
            .semantic_foreground(SemanticColorRef::on_surface())
            .flex(1.0)
            .frame_min_width(0.0)
            .erased();
        let id = test.id.clone();
        let model = self.model.clone();
        let button = Button::icon(
            ButtonIconSource::resource(ui_icons::editor::play()),
            9.0,
            move || model.test(Some(&id)),
        )
        .enabled(!busy)
        .tooltip(localized("Run Test"))
        .button_style(ToggleButtonStyle::new(0.0, 20.0))
        .erased();
        let controls = Row::new(
            VerticalAlignment::Center,
            6.0,
            TupleView::new(vec![status_icon(test.status), name, button]).erased(),
        )
        .frame(
            Some(FrameDimension::Percent(100.0)),
            None,
            Some(0.0),
            None,
            None,
            None,
        )
        .erased();
        let mut content = vec![controls];
        if let Some(message) = test
            .message
            .as_ref()
            .filter(|_| test.status == TaskTestStatus::Failed)
        {
            content.push(
                Text::new(message)
                    .line_limit(Some(3))
                    .semantic_font(SemanticFontRef::caption())
                    .semantic_foreground(SemanticColorRef::error())
                    .padding_insets(EdgeInsets::new(0.0, 17.0, 0.0, 0.0))
                    .erased(),
            );
        }
        Column::new(
            HorizontalAlignment::Leading,
            1.0,
            TupleView::new(content).erased(),
        )
        .padding_edges(14.0, 2.0)
        .frame(
            Some(FrameDimension::Percent(100.0)),
            None,
            Some(0.0),
            None,
            None,
            None,
        )
        .accessibility_label(test.id.clone())
        .erased()
    }
}

impl View for TestExplorer {
    fn body(&self, _scope: &Scope) -> AnyView {
        let busy = self.snapshot.run.as_ref().is_some_and(|run| run.is_running);
        let mut groups: Vec<(&str, Vec<&TaskTest>)> = Vec::new();
        let mut indices = HashMap::new();
        for test in &self.snapshot.tests {
            let group = test.group();
            let index = *indices.entry(group).or_insert_with(|| {
                groups.push((group, Vec::new()));
                groups.len() - 1
            });
            groups[index].1.push(test);
        }
        let content = groups
            .into_iter()
            .map(|(title, tests)| self.group(title, tests, busy))
            .collect();
        Column::new(
            HorizontalAlignment::Leading,
            0.0,
            TupleView::new(content).erased(),
        )
        .frame(
            Some(FrameDimension::Percent(100.0)),
            None,
            Some(0.0),
            None,
            None,
            None,
        )
        .debug_name("tasks-tests")
        .erased()
    }
}

fn status_icon(status: TaskTestStatus) -> AnyView {
    let (icon, color) = match status {
        TaskTestStatus::Passed => (
            ui_icons::status::check_circle(),
            SemanticColorRef::success(),
        ),
        TaskTestStatus::Failed => (ui_icons::status::x_circle(), SemanticColorRef::error()),
        TaskTestStatus::Skipped => (
            ui_icons::shape::circle_dot(),
            SemanticColorRef::on_surface_muted(),
        ),
        TaskTestStatus::NotRun => (
            ui_icons::shape::circle(),
            SemanticColorRef::on_surface_muted(),
        ),
        TaskTestStatus::Running => return Spinner::new().size(10.0).erased(),
    };
    Icon::with_semantic(icon, 11.0, color).erased()
}
