//! Translation of Editor/Sources/EditorCore/Rendering/HUD/ViewGraph.swift.
//!
//! Adapts the engine's script canvas to the UI's offscreen view renderer.

use std::sync::Arc;

use cove_ui_compose::modifiers::layout::{AbsolutePositionModifier, FlexExt};
use cove_ui_compose::rendering::OffscreenView;
use cove_ui_compose::scene_core::{Align, FlexDirection, GeometryAntialiasing, Justify, Wrap};
use cove_ui_compose::{AnyView, BoxView, EmptyView, TupleView, View, ViewExt};
use diffuse_kernel::in_game_canvas::InGameCanvas;

use crate::rendering::hud::script_canvas::{ScriptCanvasModel, ScriptCanvasView};
use crate::rendering::hud::snapshots::InGameDrawListSource;

pub struct InGameViewGraphBridge {
    view: OffscreenView,
    source: Arc<InGameDrawListSource>,
    script_canvas: std::rc::Rc<ScriptCanvasModel>,
    did_install_root: bool,
}

impl InGameViewGraphBridge {
    pub fn new(source: Arc<InGameDrawListSource>) -> Self {
        InGameViewGraphBridge {
            view: OffscreenView::new(GeometryAntialiasing::Multisample),
            source,
            script_canvas: std::rc::Rc::new(ScriptCanvasModel::new()),
            did_install_root: false,
        }
    }

    pub fn set_root_view(&mut self, root: impl View + 'static) {
        if self.did_install_root {
            return;
        }
        let canvas_view = AnyView::new(
            AnyView::new(ScriptCanvasView::new(self.script_canvas.clone())).modifier(
                AbsolutePositionModifier::new(Some(0.0), Some(0.0), Some(0.0), Some(0.0)),
            ),
        );
        self.view.set_root_view(
            BoxView::new(
                FlexDirection::Column,
                Align::Stretch,
                Justify::FlexStart,
                Wrap::NoWrap,
                0.0,
                AnyView::new(TupleView::new(vec![AnyView::new(root), canvas_view])),
            )
            .flex(1.0),
        );
        self.did_install_root = true;
    }

    pub fn tick(&mut self, width: u32, height: u32, content_scale: f32, canvas: InGameCanvas) {
        self.script_canvas.update(canvas);
        if !self.did_install_root {
            self.set_root_view(EmptyView);
        }
        if let Some(snapshot) = self.view.render(width, height, content_scale) {
            self.source.publish(snapshot);
        }
    }
}
