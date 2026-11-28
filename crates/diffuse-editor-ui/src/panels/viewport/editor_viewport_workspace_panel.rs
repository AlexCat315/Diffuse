//! `Editor/Sources/EditorUI/Panels/Viewport/EditorViewportWorkspacePanel.swift`.

use std::rc::Rc;

use cove_platform::InputEvent;
use cove_ui_compose::modifiers::layout::{FlexExt, PaddingExt};
use cove_ui_compose::primitives::controls::Checkbox;
use cove_ui_compose::primitives::controls::fields::select::{Select, SelectOption};
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{Align, Binding, FlexDirection, FocusChainHolder, Justify, Wrap};
use cove_ui_compose::theme::{SemanticColorRef, SemanticFontRef, SemanticStyleViewExt};
use cove_ui_compose::{
    AnyView, BoxView, Row, Scancode, Scope, TupleView, VerticalAlignment, View,
};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::assets::asset_catalog::EditorViewportDropTarget;
use diffuse_editor_core::rendering::viewport::viewport_host::{ViewportHost, ViewportScreenFrame};
use diffuse_editor_core::state::editor_reducer::EditorAction;
use diffuse_editor_core::state::editor_state::PlaybackState;
use diffuse_editor_core::state::workspace::editor_workbench_state::{
    EditorGamePreviewResolution, EditorViewportMode,
};
use diffuse_render::RenderDrawableSize;

use super::viewport_panel::ViewportPanel;
use crate::localization::localized;

pub struct EditorViewportWorkspacePanel(pub Rc<EditorApplication>);

impl View for EditorViewportWorkspacePanel {
    fn body(&self, _scope: &Scope) -> AnyView {
        match self.0.store.viewport_mode() {
            EditorViewportMode::Game => AnyView::new(GamePreviewPanel(self.0.clone()).flex(1.0)),
            EditorViewportMode::Scene => AnyView::new(ViewportPanel(self.0.clone()).flex(1.0)),
        }
    }
}

struct GamePreviewPanel(Rc<EditorApplication>);

impl View for GamePreviewPanel {
    fn body(&self, _scope: &Scope) -> AnyView {
        let app = &self.0;
        let playing = app.store.playback_state();
        let focused = app.store.game_preview_focused();
        let status = if playing == PlaybackState::Stopped {
            "Preview stopped"
        } else if focused {
            "Game has input focus · Esc to release"
        } else {
            "Click the game image to focus input"
        };
        let resolution = Binding::new(
            {
                let store = app.store.clone();
                move || store.game_preview_resolution()
            },
            {
                let app = app.clone();
                move |resolution| app.set_game_preview_resolution(resolution)
            },
        );
        let hud = Binding::new(
            {
                let store = app.store.clone();
                move || store.game_preview_hud_enabled()
            },
            {
                let app = app.clone();
                move |enabled| app.set_game_preview_hud_enabled(enabled)
            },
        );
        let controls = Row::new(
            VerticalAlignment::Center,
            8.0,
            AnyView::new(TupleView::new(vec![
                AnyView::new(
                    Text::new(localized(status))
                        .semantic_font(SemanticFontRef::caption())
                        .semantic_foreground(if focused {
                            SemanticColorRef::accent()
                        } else {
                            SemanticColorRef::on_surface_variant()
                        })
                        .flex(1.0),
                ),
                AnyView::new(
                    Select::new(
                        resolution,
                        EditorGamePreviewResolution::ALL.into_iter()
                            .map(|option| SelectOption::new(option, localized(option.title()), true))
                            .collect(),
                    )
                    .width(180.0),
                ),
                AnyView::new(Checkbox::from_boolean(hud)),
                AnyView::new(Text::new(localized("HUD")).semantic_font(SemanticFontRef::caption())),
            ])),
        ).padding(6.0);
        let mut view = ViewportHost::without_overlay(app.viewport_surface())
            .on_focus_changed(Rc::new({
                let app = app.clone();
                move |focused| {
                    app.store.dispatch(EditorAction::SetGamePreviewFocused(focused));
                    if !focused {
                        app.enqueue_viewport_input(InputEvent::WindowFocusLost);
                    }
                }
            }))
            .on_input_event(Rc::new({
                let app = app.clone();
                move |event| handle_game_input(&app, event)
            }))
            .on_drawable_size_change(Rc::new({
                let app = app.clone();
                move |size| app.set_viewport_drawable_size(size)
            }))
            .on_screen_frame_change(Rc::new(|frame| EditorViewportDropTarget::set_frame(Some(frame))));
        if let Some(aspect) = app.store.game_preview_resolution().aspect_ratio() {
            view = view.content_aspect_ratio(aspect);
        }
        AnyView::new(BoxView::new(
            FlexDirection::Column, Align::Stretch, Justify::FlexStart, Wrap::NoWrap, 0.0,
            AnyView::new(TupleView::new(vec![
                AnyView::new(controls),
                AnyView::new(view.flex(1.0).semantic_background(SemanticColorRef::surface_sunken())),
            ])),
        ))
    }
}

fn handle_game_input(app: &EditorApplication, event: InputEvent) {
    if let InputEvent::KeyDown(key) = &event {
        if key.scancode == Scancode::ESCAPE {
            if let Some(focus) = FocusChainHolder::current() {
                focus.clear();
            }
            app.enqueue_viewport_input(InputEvent::WindowFocusLost);
            return;
        }
        if key.modifiers.has_gui() || key.modifiers.has_ctrl() {
            return;
        }
    }
    if app.store.playback_state() != PlaybackState::Playing || !app.store.game_preview_focused() {
        return;
    }
    let resolution = app.store.game_preview_resolution().size()
        .unwrap_or_else(|| *app.viewport_drawable_size.borrow());
    let event = match EditorViewportDropTarget::frame() {
        Some(frame) => EditorGamePreviewInput::map(event, frame, Some(resolution)),
        None => event,
    };
    app.enqueue_viewport_input(event);
}

pub struct EditorGamePreviewInput;

impl EditorGamePreviewInput {
    /// Map window coordinates into the actual game image, excluding letterbox bars.
    pub fn map(
        mut event: InputEvent,
        frame: ViewportScreenFrame,
        resolution: Option<RenderDrawableSize>,
    ) -> InputEvent {
        if frame.width <= 0.0 || frame.height <= 0.0 {
            return event;
        }
        let (sx, sy) = resolution.map(|size| {
            (size.width as f32 / frame.width, size.height as f32 / frame.height)
        }).unwrap_or((1.0, 1.0));
        let x = |value| (value - frame.x) * sx;
        let y = |value| (value - frame.y) * sy;
        match &mut event {
            InputEvent::MouseButtonDown(pointer) | InputEvent::MouseButtonUp(pointer) => {
                pointer.x = x(pointer.x);
                pointer.y = y(pointer.y);
            }
            InputEvent::MouseMotion(pointer) => {
                pointer.x = x(pointer.x);
                pointer.y = y(pointer.y);
                pointer.delta_x *= sx;
                pointer.delta_y *= sy;
            }
            InputEvent::MouseWheel(wheel) => {
                wheel.mouse_x = wheel.mouse_x.map(x);
                wheel.mouse_y = wheel.mouse_y.map(y);
            }
            _ => {}
        }
        event
    }
}
