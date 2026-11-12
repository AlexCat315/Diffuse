//! Translation of Editor/Sources/EditorCore/Rendering/HUD/ScriptCanvas.swift.
//!
//! Observable wrapper around the game's immediate-mode `InGameCanvas` plus the
//! view that draws its commands.

use std::cell::RefCell;
use std::rc::Rc;

use cove_ui_compose::modifiers::layout::{AbsolutePositionModifier, FlexExt, LayoutFrameExt};
use cove_ui_compose::modifiers::style::AppearanceExt;
use cove_ui_compose::primitives::text::Text;
use cove_ui_compose::scene_core::{
    Align, Color, FlexDirection, Font, FontWeight, Justify, ObservableObject, ObservablePublisher,
    Wrap,
};
use cove_ui_compose::{AnyView, BoxView, EmptyView, Observed, Scope, TupleView, View, ViewExt};
use diffuse_kernel::in_game_canvas::{InGameCanvas, InGameCanvasCommand, InGameUIColor};

pub struct ScriptCanvasModel {
    canvas: RefCell<InGameCanvas>,
    publisher: ObservablePublisher,
}

impl Default for ScriptCanvasModel {
    fn default() -> Self {
        Self::new()
    }
}

impl ScriptCanvasModel {
    pub fn new() -> Self {
        ScriptCanvasModel {
            canvas: RefCell::new(InGameCanvas::new()),
            publisher: ObservablePublisher::default(),
        }
    }

    pub fn canvas(&self) -> InGameCanvas {
        self.canvas.borrow().clone()
    }

    pub fn update(&self, canvas: InGameCanvas) {
        if *self.canvas.borrow() == canvas {
            return;
        }
        *self.canvas.borrow_mut() = canvas;
        self.publisher.send();
    }
}

impl ObservableObject for ScriptCanvasModel {
    fn register_observer(&self, handler: Rc<dyn Fn()>) -> u64 {
        self.publisher.register_observer(handler)
    }

    fn unregister_observer(&self, token: u64) {
        self.publisher.unregister_observer(token);
    }
}

pub struct ScriptCanvasView {
    canvas: Observed<ScriptCanvasModel, InGameCanvas>,
}

impl ScriptCanvasView {
    pub fn new(model: Rc<ScriptCanvasModel>) -> Self {
        ScriptCanvasView {
            canvas: Observed::new(model, |model| model.canvas()),
        }
    }

    fn draw(command: InGameCanvasCommand) -> AnyView {
        match command {
            InGameCanvasCommand::Label {
                text,
                x,
                y,
                font_size,
                color,
            } => {
                if !(x.is_finite() && y.is_finite() && font_size.is_finite()) {
                    return AnyView::new(EmptyView);
                }
                AnyView::new(
                    Text::new(text)
                        .font(Font::system(font_size.max(1.0), FontWeight::Regular))
                        .foreground_color(convert(color))
                        .modifier(AbsolutePositionModifier::new(Some(x), Some(y), None, None)),
                )
            }
            InGameCanvasCommand::Rect {
                x,
                y,
                w,
                h,
                color,
                corner_radius,
            } => {
                if !valid_rect(x, y, w, h) {
                    return AnyView::new(EmptyView);
                }
                AnyView::new(
                    BoxView::new(
                        FlexDirection::Column,
                        Align::Stretch,
                        Justify::FlexStart,
                        Wrap::NoWrap,
                        0.0,
                        AnyView::new(EmptyView),
                    )
                    .frame_size(w.max(0.0), h.max(0.0))
                    .background_color(convert(color))
                    .corner_radius(if corner_radius.is_finite() {
                        corner_radius.max(0.0)
                    } else {
                        0.0
                    })
                    .modifier(AbsolutePositionModifier::new(Some(x), Some(y), None, None)),
                )
            }
            InGameCanvasCommand::ProgressBar {
                x,
                y,
                w,
                h,
                value,
                max_value,
                fill_color,
                bg_color,
                corner_radius,
            } => {
                if !valid_rect(x, y, w, h) {
                    return AnyView::new(EmptyView);
                }
                let fraction = if value.is_finite() && max_value.is_finite() && max_value > 0.0 {
                    (value / max_value).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                let corner = if corner_radius.is_finite() {
                    corner_radius.max(0.0)
                } else {
                    0.0
                };
                let fill = AnyView::new(
                    BoxView::new(
                        FlexDirection::Column,
                        Align::Stretch,
                        Justify::FlexStart,
                        Wrap::NoWrap,
                        0.0,
                        AnyView::new(EmptyView),
                    )
                    .frame_size(w * fraction, h)
                    .background_color(convert(fill_color))
                    .corner_radius(corner)
                    .modifier(AbsolutePositionModifier::new(
                        Some(0.0),
                        Some(0.0),
                        None,
                        None,
                    )),
                );
                AnyView::new(
                    BoxView::new(
                        FlexDirection::Column,
                        Align::Stretch,
                        Justify::FlexStart,
                        Wrap::NoWrap,
                        0.0,
                        fill,
                    )
                    .frame_size(w, h)
                    .background_color(convert(bg_color))
                    .corner_radius(corner)
                    .modifier(AbsolutePositionModifier::new(Some(x), Some(y), None, None)),
                )
            }
        }
    }
}

impl View for ScriptCanvasView {
    fn dynamic_properties(&self) -> Vec<cove_ui_compose::DynamicField> {
        vec![self.canvas.dynamic_field("canvas")]
    }

    fn body(&self, _scope: &Scope) -> AnyView {
        let children = self
            .canvas
            .get()
            .commands
            .into_iter()
            .map(Self::draw)
            .collect::<Vec<_>>();
        AnyView::new(
            BoxView::new(
                FlexDirection::Column,
                Align::Stretch,
                Justify::FlexStart,
                Wrap::NoWrap,
                0.0,
                AnyView::new(TupleView::new(children)),
            )
            .flex(1.0),
        )
    }
}

fn valid_rect(x: f32, y: f32, w: f32, h: f32) -> bool {
    x.is_finite() && y.is_finite() && w.is_finite() && h.is_finite() && w >= 0.0 && h >= 0.0
}

fn convert(color: InGameUIColor) -> Color {
    Color {
        r: color.r,
        g: color.g,
        b: color.b,
        a: color.a,
    }
}
