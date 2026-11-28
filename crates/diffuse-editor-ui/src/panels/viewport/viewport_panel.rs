//! Scene presentation and its input boundary from ViewportPanel.swift.

use std::rc::Rc;

use cove_platform::InputEvent;
use cove_ui_compose::modifiers::layout::{FlexExt, LayoutFrameExt, PaddingExt};
use cove_ui_compose::scene_core::{Align, FlexDirection, Justify, Wrap};
use cove_ui_compose::theme::{SemanticColorRef, SemanticStyleViewExt};
use cove_ui_compose::{
    AnyView, BoxView, Row, Scope, Spacer, TupleView, VerticalAlignment, View,
};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::assets::asset_catalog::EditorViewportDropTarget;
use diffuse_editor_core::rendering::viewport::viewport_host::ViewportHost;
use diffuse_editor_core::state::editor_state::PlaybackState;

use super::viewport_navigation_controls::ViewportTransformMenu;
use super::viewport_tool_menu::ViewportToolMenu;

pub struct ViewportPanel(pub Rc<EditorApplication>);

impl View for ViewportPanel {
    fn body(&self, _scope: &Scope) -> AnyView {
        let app = &self.0;
        let editable = app.store.playback_state() == PlaybackState::Stopped;
        let tools = Row::new(
            VerticalAlignment::Center,
            6.0,
            AnyView::new(TupleView::new(vec![
                AnyView::new(ViewportToolMenu::new(app.store.clone(), app.store.gizmo_mode(), editable)),
                AnyView::new(ViewportTransformMenu::new(app.store.clone(), editable)),
                AnyView::new(Spacer::default()),
            ])),
        )
        .padding_edges(6.0, 0.0)
        .frame_height(40.0);
        let surface = ViewportHost::without_overlay(app.viewport_surface())
            .on_focus_changed(Rc::new({
                let app = app.clone();
                move |focused| {
                    if !focused {
                        app.handle_viewport_input(InputEvent::WindowFocusLost);
                    }
                }
            }))
            .on_input_event(Rc::new({
                let app = app.clone();
                move |input| app.handle_viewport_input(input)
            }))
            .on_drawable_size_change(Rc::new({
                let app = app.clone();
                move |size| app.set_viewport_drawable_size(size)
            }))
            .on_screen_frame_change(Rc::new(|frame| EditorViewportDropTarget::set_frame(Some(frame))))
            .flex(1.0)
            .semantic_background(SemanticColorRef::surface_sunken());
        AnyView::new(BoxView::new(
            FlexDirection::Column, Align::Stretch, Justify::FlexStart, Wrap::NoWrap, 0.0,
            AnyView::new(TupleView::new(vec![AnyView::new(tools), AnyView::new(surface)])),
        ))
    }
}
