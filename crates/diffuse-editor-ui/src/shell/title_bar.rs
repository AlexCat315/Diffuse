//! Window controls, project selection and playback from TitleBar.swift.

use std::rc::Rc;

use cove_ui::hosts::desktop::window::chrome_views::ImmersiveWindowTitleBar;
use cove_ui_compose::modifiers::layout::{FlexExt, PaddingExt};
use cove_ui_compose::primitives::controls::Button;
use cove_ui_compose::primitives::controls::fields::select::{Select, SelectOption};
use cove_ui_compose::scene_core::Binding;
use cove_ui_compose::theme::styles::buttons::ButtonStyleViewExt;
use cove_ui_compose::{AnyView, DynamicField, Observed, Row, Scope, Spacer, TupleView, VerticalAlignment, View};
use diffuse_editor_core::state::editor_state::PlaybackState;
use diffuse_editor_core::state::workspace::content::EditorContent;
use diffuse_editor_core::state::workspace::editor_workbench_state::EditorViewportMode;

use super::appearance::EditorChromeButtonStyle;
use super::canvas_chrome::EditorCanvasChrome;
use crate::commands::command::EditorCommand;
use crate::commands::dispatcher::EditorCommandDispatcher;
use crate::localization::localized;
use crate::projects::editor_launch_context::{EditorLaunchBundle, EditorLaunchContext, EditorProjectEntry};

pub struct EditorTitleBar {
    context: Rc<EditorLaunchContext>,
    bundle: Rc<EditorLaunchBundle>,
    projects: Observed<EditorLaunchContext, Vec<EditorProjectEntry>>,
}

impl EditorTitleBar {
    pub fn new(context: Rc<EditorLaunchContext>, bundle: Rc<EditorLaunchBundle>) -> Self {
        let projects = Observed::new(context.clone(), EditorLaunchContext::projects);
        Self { context, bundle, projects }
    }

    fn command_button(&self, title: &str, command: EditorCommand, selected: bool) -> AnyView {
        let context = self.context.clone();
        let bundle = self.bundle.clone();
        AnyView::new(Button::title(localized(title), move || {
            EditorCommandDispatcher::handle(command.clone(), &bundle, &context)
        }).selected(selected).button_style(EditorChromeButtonStyle::new(28.0)))
    }
}

impl View for EditorTitleBar {
    fn body(&self, _scope: &Scope) -> AnyView {
        let app = &self.bundle.app;
        let content = app.store.content();
        let mode = app.store.viewport_mode();
        let state = app.store.playback_state();
        let projects = self.projects.get();
        let mut views = Vec::new();
        if !projects.is_empty() {
            let selection = Binding::new(
                { let context = self.context.clone(); move || context.active_directory().unwrap_or_default() },
                {
                    let context = self.context.clone();
                    let bundle = self.bundle.clone();
                    move |path| EditorCommandDispatcher::handle(EditorCommand::ActivateProject(path), &bundle, &context)
                },
            );
            views.push(AnyView::new(Select::new(
                selection,
                projects.into_iter().map(|project| SelectOption::new(project.directory, project.name, true)).collect(),
            ).width(174.0)));
        }
        views.push(self.command_button("Open Folder...", EditorCommand::OpenFolder, false));
        views.push(self.command_button("Scene", EditorCommand::ShowContent(EditorContent::Scene), content == EditorContent::Scene));
        views.push(self.command_button("Code", EditorCommand::ShowContent(EditorContent::Files), content == EditorContent::Files));
        if content == EditorContent::Scene {
            views.push(self.command_button("New Scene", EditorCommand::NewScene, false));
            views.push(self.command_button("Open Scene...", EditorCommand::OpenScene, false));
            views.push(self.command_button("Save Scene", EditorCommand::SaveScene, false));
        }
        views.push(AnyView::new(Spacer::new(8.0)));
        if content == EditorContent::Scene {
            let app = app.clone();
            let next = if mode == EditorViewportMode::Scene { EditorViewportMode::Game } else { EditorViewportMode::Scene };
            views.push(AnyView::new(Button::title(localized("Game"), move || app.set_viewport_mode(next))
                .selected(mode == EditorViewportMode::Game).button_style(EditorChromeButtonStyle::new(28.0))));
            views.push(self.command_button(
                if state == PlaybackState::Playing { "Pause" } else { "Play" },
                EditorCommand::TogglePlayback,
                state == PlaybackState::Playing,
            ));
            if state != PlaybackState::Stopped {
                views.push(self.command_button("Stop", EditorCommand::SetPlaybackState(PlaybackState::Stopped), false));
            }
        }
        views.push(self.command_button("Settings", EditorCommand::OpenSettings, false));
        let bar = AnyView::new(Row::new(VerticalAlignment::Center, 6.0, AnyView::new(TupleView::new(views)))
            .padding_edges(6.0, 0.0).flex(1.0));
        AnyView::new(EditorCanvasChrome::new(move || AnyView::new(ImmersiveWindowTitleBar::new(bar.clone()).height(40.0))))
    }

    fn dynamic_properties(&self) -> Vec<DynamicField> {
        vec![self.projects.dynamic_field("projects")]
    }
}
