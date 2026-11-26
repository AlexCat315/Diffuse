//! Project task controls, test results and status-bar feedback.

use std::rc::Rc;
use std::sync::{Arc, Mutex};

use cove_ui_compose::prelude::*;
use cove_ui_compose::primitives::media::ui_icons;
use cove_ui_compose::theme::styles::buttons::{
    ButtonStyleViewExt, PlainButtonStyle, ToggleButtonStyle,
};
use cove_ui_compose::{EmptyView, HorizontalAlignment, LayoutDebugExt, VerticalAlignment};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::tasks::results::{TaskKind, TaskRun, TaskSnapshot};
use diffuse_editor_core::tasks::runner::EditorTasks;

use super::project_contents::TaskProjectContents;
use super::test_explorer::TestExplorer;
use crate::localization::localized;
use crate::panels::shared::editor_panel_components::{
    EditorPanelEmptyState, EditorPanelIconButton, EditorPanelToolbar,
};

struct TaskObservation {
    model: Arc<EditorTasks>,
    snapshot: State<TaskSnapshot>,
    token: u64,
}

impl TaskObservation {
    fn new(model: Arc<EditorTasks>) -> Self {
        let snapshot = State::new(model.snapshot());
        let observed = snapshot.clone();
        let weak = Arc::downgrade(&model);
        let updates = Mutex::new(());
        let refresh = Arc::new(move || {
            let _update = updates
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(model) = weak.upgrade() {
                observed.set(model.snapshot());
            }
        });
        let token = model.register_observer(refresh.clone());
        refresh();
        Self {
            model,
            snapshot,
            token,
        }
    }
}

impl Drop for TaskObservation {
    fn drop(&mut self) {
        self.model.unregister_observer(self.token);
    }
}

pub struct TasksPanel {
    tasks: TaskObservation,
    run_menu_open: State<bool>,
}

impl TasksPanel {
    pub fn new(app: &EditorApplication) -> Self {
        Self {
            tasks: TaskObservation::new(app.workstation.tasks.clone()),
            run_menu_open: State::new(false),
        }
    }

    fn toolbar(&self, snapshot: &TaskSnapshot) -> AnyView {
        let busy = snapshot.run.as_ref().is_some_and(|run| run.is_running);
        let runnables = snapshot
            .description
            .as_ref()
            .map_or(&[][..], |project| project.runnables.as_slice());
        let title = snapshot
            .description
            .as_ref()
            .map(|project| project.name.as_str())
            .or(snapshot.title.as_deref())
            .unwrap_or_default();
        let build = self.tasks.model.clone();
        let test = self.tasks.model.clone();
        let stop = self.tasks.model.clone();
        let clean = self.tasks.model.clone();
        EditorPanelToolbar::new(
            TupleView::new(vec![
                Text::new(title)
                    .line_limit(Some(1))
                    .semantic_font(SemanticFontRef::label())
                    .semantic_foreground(SemanticColorRef::on_surface())
                    .flex(1.0)
                    .frame_min_width(0.0)
                    .erased(),
                EditorPanelIconButton::new(
                    ui_icons::editor::hammer(),
                    localized("Build"),
                    !busy,
                    move || build.build(),
                )
                .debug_name("tasks-build")
                .erased(),
                EditorPanelIconButton::new(
                    ui_icons::status::check_circle(),
                    localized("Run Tests"),
                    !busy,
                    move || test.test(None),
                )
                .debug_name("tasks-test")
                .erased(),
                self.run_button(runnables, !busy),
                EditorPanelIconButton::new(
                    ui_icons::editor::stop(),
                    localized("Stop"),
                    busy,
                    move || stop.stop(),
                )
                .debug_name("tasks-stop")
                .erased(),
                EditorPanelIconButton::new(
                    ui_icons::action::trash(),
                    localized("Clean"),
                    !busy,
                    move || clean.clean(),
                )
                .erased(),
            ]),
            4.0,
        )
        .erased()
    }

    fn run_button(&self, targets: &[String], enabled: bool) -> AnyView {
        if targets.len() <= 1 {
            let target = targets.first().cloned();
            let model = self.tasks.model.clone();
            return EditorPanelIconButton::new(
                ui_icons::editor::play(),
                localized("Run"),
                enabled && target.is_some(),
                move || {
                    if let Some(target) = &target {
                        model.run(target);
                    }
                },
            )
            .debug_name("tasks-run")
            .erased();
        }

        let entries = targets
            .iter()
            .enumerate()
            .map(|(index, target)| {
                let model = self.tasks.model.clone();
                let target = target.clone();
                let open = self.run_menu_open.clone();
                MenuEntry::Item(MenuItem::new(index as u64, target.clone(), move || {
                    open.set(false);
                    model.run(&target);
                }))
            })
            .collect();
        let open = self.run_menu_open.clone();
        let menu = Menu::new(entries)
            .width(220.0)
            .on_dismiss(move || open.set(false));
        let label = localized("Run");
        Popover::new(Icon::new(ui_icons::editor::play(), 11.0), menu)
            .trigger_description(PopoverTriggerDescription {
                label: label.clone(),
                help: Some(label),
                ..Default::default()
            })
            .trigger_style(ToggleButtonStyle::new(0.0, 22.0))
            .is_presented(self.run_menu_open.binding())
            .enabled(enabled)
            .width(220.0)
            .placement(PopoverPlacement::BottomTrailing)
            .surface(PopoverSurface::Content)
            .overflow(PopoverOverflow::Flip)
            .debug_name("tasks-run")
            .erased()
    }

    pub fn title(run: &TaskRun) -> String {
        let name = match run.kind {
            TaskKind::Build => localized("Build"),
            TaskKind::Test => localized("Test"),
            TaskKind::Run => format!(
                "{} {}",
                localized("Run"),
                run.subject.as_deref().unwrap_or_default()
            ),
            TaskKind::Resolve => localized("Resolve Dependencies"),
            TaskKind::Clean => localized("Clean"),
        };
        if run.is_running {
            return format!("{name}…");
        }
        let key = if run.failure.as_deref() == Some("Stopped") {
            "%@ stopped"
        } else if run.succeeded() {
            "%@ succeeded"
        } else {
            "%@ failed"
        };
        localized(key).replace("%@", &name)
    }
}

impl View for TasksPanel {
    fn body(&self, _scope: &Scope) -> AnyView {
        let snapshot = self.tasks.snapshot.get();
        let content = if snapshot.is_available() {
            let toolbar = self.toolbar(&snapshot);
            let description = snapshot.description.clone();
            let tests = TestExplorer {
                model: self.tasks.model.clone(),
                snapshot,
            };
            let list = Column::new(
                HorizontalAlignment::Leading,
                0.0,
                TupleView::new(vec![
                    tests.erased(),
                    TaskProjectContents::new(description).erased(),
                ])
                .erased(),
            )
            .padding_edges(0.0, 4.0)
            .frame(
                Some(FrameDimension::Percent(100.0)),
                None,
                Some(0.0),
                None,
                None,
                None,
            );
            vec![
                toolbar,
                ScrollView::new(ScrollAxis::Vertical, list)
                    .scrollbar_gutter(ScrollbarGutter::Stable)
                    .flex(1.0)
                    .frame(None, None, Some(0.0), Some(0.0), None, None)
                    .debug_name("tasks-content")
                    .erased(),
            ]
        } else {
            vec![TaskEmptyState::new(localized("No tasks for this project")).erased()]
        };
        Column::new(
            HorizontalAlignment::Leading,
            0.0,
            TupleView::new(content).erased(),
        )
        .frame(None, None, Some(0.0), Some(0.0), None, None)
        .debug_name("tasks")
        .erased()
    }
}

pub struct TaskStatus {
    tasks: TaskObservation,
    on_open: Rc<dyn Fn()>,
}

impl TaskStatus {
    pub fn new(app: &EditorApplication, on_open: impl Fn() + 'static) -> Self {
        Self {
            tasks: TaskObservation::new(app.workstation.tasks.clone()),
            on_open: Rc::new(on_open),
        }
    }
}

impl View for TaskStatus {
    fn body(&self, _scope: &Scope) -> AnyView {
        let Some(run) = self.tasks.snapshot.get().run else {
            return EmptyView.erased();
        };
        let status = if run.is_running {
            Spinner::new().size(9.0).erased()
        } else if run.succeeded() {
            Icon::with_semantic(
                ui_icons::status::check_circle(),
                10.0,
                SemanticColorRef::success(),
            )
            .erased()
        } else {
            Icon::with_semantic(
                ui_icons::status::x_circle(),
                10.0,
                SemanticColorRef::error(),
            )
            .erased()
        };
        let title = Text::new(TasksPanel::title(&run))
            .line_limit(Some(1))
            .semantic_font(SemanticFontRef::caption())
            .semantic_foreground(SemanticColorRef::on_surface_variant())
            .erased();
        let on_open = self.on_open.clone();
        Button::new(
            Row::new(
                VerticalAlignment::Center,
                4.0,
                TupleView::new(vec![status, title]).erased(),
            ),
            move || on_open(),
        )
        .button_style(PlainButtonStyle)
        .debug_name("editor-status-tasks")
        .erased()
    }
}

pub struct TaskEmptyState(String);

impl TaskEmptyState {
    pub fn new(title: String) -> Self {
        Self(title)
    }
}

impl View for TaskEmptyState {
    fn body(&self, _scope: &Scope) -> AnyView {
        ZStack::new(EditorPanelEmptyState::new(self.0.clone(), None))
            .flex(1.0)
            .frame(
                Some(FrameDimension::Percent(100.0)),
                None,
                Some(0.0),
                Some(0.0),
                None,
                None,
            )
            .erased()
    }
}
