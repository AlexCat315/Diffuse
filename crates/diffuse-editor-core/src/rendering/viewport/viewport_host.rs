//! Translation of Editor/Sources/EditorCore/Rendering/Viewport/ViewportHost.swift.
//!
//! Displays a renderer-produced framebuffer inside CoveUI layout and forwards
//! viewport-local input to the owner.

use std::rc::Rc;
use std::sync::Arc;

use cove_graphics::ui::texture_image;
use cove_platform::{InputEvent, KeyEvent};
use cove_ui_compose::core_exports::cove_imaging::TextureImage;
use cove_ui_compose::scene_core::{
    Color, DrawList, FocusChainHolder, InputHandlerRoute, InteractionRegistryHolder, Node, Point,
    PointerCaptureHolder, TextInputAttachmentKey, TextInputFocusChangeHandler,
};
use cove_ui_compose::scene_core::{EventPhase, EventResult, PointerPhase};
use cove_ui_compose::theme::theme_for_node;
use cove_ui_compose::{AnyView, PrimitiveView, View, impl_primitive_view};
use diffuse_render::RenderDrawableSize;
use diffuse_render::surface::viewport_image::ViewportImage;
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;

const IMAGE_ATTACHMENT: &str = "__viewport_image";
const INITIAL_FOCUS_ATTACHMENT: &str = "__viewport_initial_focus";
const DRAWABLE_SIZE_ATTACHMENT: &str = "__viewport_host_drawable_size";
const SCREEN_FRAME_ATTACHMENT: &str = "__viewport_host_screen_frame";

/// Screen-space rect of the viewport surface, in window/event coordinates.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ViewportScreenFrame {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl ViewportScreenFrame {
    pub fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        ViewportScreenFrame {
            x,
            y,
            width,
            height,
        }
    }

    pub fn contains(&self, px: f32, py: f32) -> bool {
        px >= self.x && py >= self.y && px < self.x + self.width && py < self.y + self.height
    }
}

pub type ScreenFrameCallback = Rc<dyn Fn(ViewportScreenFrame)>;
pub type InputEventCallback = Rc<dyn Fn(InputEvent)>;
pub type KeyConsumptionCallback = Rc<dyn Fn(&KeyEvent) -> bool>;
pub type DrawOverlayCallback = Rc<dyn Fn(&mut DrawList, ViewportScreenFrame)>;

pub struct ViewportHost {
    pub surface: ViewportSurfaceState,
    pub automatically_focus: bool,
    pub content_aspect_ratio: Option<f32>,
    pub key_consumption: Option<KeyConsumptionCallback>,
    pub on_focus_changed: Option<Rc<dyn Fn(bool)>>,
    pub on_input_event: Option<InputEventCallback>,
    pub on_drawable_size_change: Option<Rc<dyn Fn(RenderDrawableSize)>>,
    pub on_screen_frame_change: Option<ScreenFrameCallback>,
    pub on_draw_overlay: Option<DrawOverlayCallback>,
    pub overlay: AnyView,
}

impl ViewportHost {
    /// A viewport with an overlay view drawn above it.
    pub fn new(surface: ViewportSurfaceState, overlay: impl View + 'static) -> Self {
        ViewportHost {
            surface,
            automatically_focus: false,
            content_aspect_ratio: None,
            key_consumption: None,
            on_focus_changed: None,
            on_input_event: None,
            on_drawable_size_change: None,
            on_screen_frame_change: None,
            on_draw_overlay: None,
            overlay: AnyView::new(overlay),
        }
    }

    /// A viewport without overlay content.
    pub fn without_overlay(surface: ViewportSurfaceState) -> Self {
        Self::new(surface, cove_ui_compose::EmptyView)
    }

    pub fn key_consumption(mut self, callback: KeyConsumptionCallback) -> Self {
        self.key_consumption = Some(callback);
        self
    }

    pub fn automatically_focus(mut self, value: bool) -> Self {
        self.automatically_focus = value;
        self
    }

    pub fn content_aspect_ratio(mut self, value: f32) -> Self {
        self.content_aspect_ratio = Some(value);
        self
    }

    pub fn on_focus_changed(mut self, callback: Rc<dyn Fn(bool)>) -> Self {
        self.on_focus_changed = Some(callback);
        self
    }

    pub fn on_input_event(mut self, callback: InputEventCallback) -> Self {
        self.on_input_event = Some(callback);
        self
    }

    pub fn on_drawable_size_change(mut self, callback: Rc<dyn Fn(RenderDrawableSize)>) -> Self {
        self.on_drawable_size_change = Some(callback);
        self
    }

    pub fn on_screen_frame_change(mut self, callback: ScreenFrameCallback) -> Self {
        self.on_screen_frame_change = Some(callback);
        self
    }

    pub fn on_draw_overlay(mut self, callback: DrawOverlayCallback) -> Self {
        self.on_draw_overlay = Some(callback);
        self
    }

    /// The viewport owns raw keys (camera, game input) while focused, but
    /// Cmd/Ctrl chords stay with app-level shortcuts. Events are forwarded to
    /// `on_input_event` either way so pressed-key bookkeeping stays complete.
    fn consumes_key(event: &KeyEvent) -> bool {
        !event.modifiers.has_gui() && !event.modifiers.has_ctrl()
    }
}

impl PrimitiveView for ViewportHost {
    fn make_node(&self) -> Node {
        let node = Node::new();
        node.set_is_hit_testable(true);
        node.set_is_focusable(true);
        node.set_automatically_focus_on_pointer_down(false);
        node.set_clips_to_bounds(true);
        node
    }

    fn update_node(&self, node: &Node) {
        let snap = self;

        if let Some(cached) = node.attachment::<ImageCache>(IMAGE_ATTACHMENT) {
            let same_output = match snap.surface.image.as_ref() {
                Some(current) => Arc::ptr_eq(current, &cached.output),
                None => false,
            };
            if !same_output || !snap.surface.is_valid() {
                node.remove_attachment(IMAGE_ATTACHMENT);
            }
        }

        let focus_snap = Snapshot::new(snap);
        let focus_change: TextInputFocusChangeHandler = Rc::new(move |focused| {
            if let Some(handler) = &focus_snap.on_focus_changed {
                handler(focused);
            }
        });
        node.set_attachment(TextInputAttachmentKey::FOCUS_CHANGE_HANDLER, focus_change);

        // A standalone game owns the initial keyboard target. Embedded editor
        // viewports retain click-to-focus and never take another control's focus.
        if snap.automatically_focus
            && node.attachment::<bool>(INITIAL_FOCUS_ATTACHMENT).is_none()
            && let Some(focus) = FocusChainHolder::current()
            && focus.focused().is_none()
        {
            focus.focus(Some(node), false);
            if focus.focused().as_ref() == Some(node) {
                node.set_attachment(INITIAL_FOCUS_ATTACHMENT, true);
            }
        }

        let background_target = if snap.surface.is_valid() {
            theme_for_node(node).colors.surface_sunken
        } else {
            theme_for_node(node).colors.surface_variant
        };
        let background_owner = node.clone();
        node.animatable_set_optional(
            "backgroundColor",
            node.background_color(),
            Some(background_target),
            move |value| background_owner.set_background_color(value),
        );

        register_input_handlers(node, snap);
        register_draw(node, snap);
    }

    fn children(&self, _node: &Node) -> Vec<AnyView> {
        vec![self.overlay.clone()]
    }

    fn make_layout_node(&self) -> Option<cove_ui_compose::LayoutNode> {
        let layout = cove_ui_compose::LayoutNode::new();
        layout.set_flex_direction(cove_ui_compose::scene_core::FlexDirection::Column);
        layout.set_align_items(cove_ui_compose::scene_core::Align::Stretch);
        layout.set_flex_grow(1.0);
        Some(layout)
    }
}
impl_primitive_view!(ViewportHost);

/// The parts of a `ViewportHost` its closures need. Cloning the whole view into
/// each handler would also clone the overlay view tree, which handlers never
/// touch.
#[derive(Clone)]
struct Snapshot {
    surface: ViewportSurfaceState,
    content_aspect_ratio: Option<f32>,
    key_consumption: Option<KeyConsumptionCallback>,
    on_focus_changed: Option<Rc<dyn Fn(bool)>>,
    on_input_event: Option<InputEventCallback>,
    on_drawable_size_change: Option<Rc<dyn Fn(RenderDrawableSize)>>,
    on_screen_frame_change: Option<ScreenFrameCallback>,
    on_draw_overlay: Option<DrawOverlayCallback>,
}

impl Snapshot {
    fn new(host: &ViewportHost) -> Self {
        Snapshot {
            surface: host.surface.clone(),
            content_aspect_ratio: host.content_aspect_ratio,
            key_consumption: host.key_consumption.clone(),
            on_focus_changed: host.on_focus_changed.clone(),
            on_input_event: host.on_input_event.clone(),
            on_drawable_size_change: host.on_drawable_size_change.clone(),
            on_screen_frame_change: host.on_screen_frame_change.clone(),
            on_draw_overlay: host.on_draw_overlay.clone(),
        }
    }

    fn image_frame(&self, node: &Node) -> ViewportScreenFrame {
        let bounds = node.absolute_frame();
        ViewportPresentationGeometry::fit(
            ViewportScreenFrame::new(bounds.x, bounds.y, bounds.width, bounds.height),
            self.content_aspect_ratio,
        )
    }
}

/// The view object itself is not `'static`-shareable through `Rc` handlers here:
/// each registration clones only `Snapshot`.
fn register_input_handlers(node: &Node, host: &ViewportHost) {
    let Some(registry) = InteractionRegistryHolder::current() else {
        return;
    };
    let route = InputHandlerRoute::viewport();

    let pointer_snap = Snapshot::new(host);
    let pointer_node = node.downgrade();
    registry.set_pointer(
        node,
        route.clone(),
        Rc::new(move |event, phase, event_phase| {
            // Passive overlay content can be the hit target. Let its
            // unhandled input bubble to the viewport; interactive chrome
            // consumes its own events before they reach this ancestor.
            if event_phase == EventPhase::Capture {
                return EventResult::Ignored;
            }
            let Some(node) = Node::upgrade(&pointer_node) else {
                return EventResult::Ignored;
            };
            match phase {
                PointerPhase::Down => {
                    if !pointer_snap.image_frame(&node).contains(event.x, event.y) {
                        if let Some(focus) = FocusChainHolder::current()
                            && focus.focused().as_ref() == Some(&node)
                        {
                            focus.clear();
                        }
                        return EventResult::Ignored;
                    }
                    if let Some(focus) = FocusChainHolder::current() {
                        focus.focus(Some(&node), true);
                    }
                    if let Some(capture) = PointerCaptureHolder::current() {
                        capture.acquire(&node, false);
                    }
                    if let Some(handler) = &pointer_snap.on_input_event {
                        handler(InputEvent::MouseButtonDown(event.clone()));
                    }
                }
                PointerPhase::Up => {
                    let captured = PointerCaptureHolder::current()
                        .and_then(|capture| capture.target())
                        .as_ref()
                        == Some(&node);
                    if !captured && !pointer_snap.image_frame(&node).contains(event.x, event.y) {
                        return EventResult::Ignored;
                    }
                    if let Some(handler) = &pointer_snap.on_input_event {
                        handler(InputEvent::MouseButtonUp(event.clone()));
                    }
                    if let Some(capture) = PointerCaptureHolder::current()
                        && capture.target().as_ref() == Some(&node)
                    {
                        capture.release();
                    }
                }
            }
            EventResult::Handled
        }),
    );

    let motion_snap = Snapshot::new(host);
    let motion_node = node.downgrade();
    registry.set_motion(
        node,
        route.clone(),
        Rc::new(move |event, phase| {
            if phase == EventPhase::Capture {
                return EventResult::Ignored;
            }
            let Some(node) = Node::upgrade(&motion_node) else {
                return EventResult::Ignored;
            };
            let captured = PointerCaptureHolder::current()
                .and_then(|capture| capture.target())
                .as_ref()
                == Some(&node);
            if !captured && !motion_snap.image_frame(&node).contains(event.x, event.y) {
                return EventResult::Ignored;
            }
            if let Some(handler) = &motion_snap.on_input_event {
                handler(InputEvent::MouseMotion(event.clone()));
            }
            EventResult::Handled
        }),
    );

    let wheel_snap = Snapshot::new(host);
    let wheel_node = node.downgrade();
    registry.set_wheel(
        node,
        route.clone(),
        Rc::new(move |event, phase| {
            if phase == EventPhase::Capture {
                return EventResult::Ignored;
            }
            let Some(node) = Node::upgrade(&wheel_node) else {
                return EventResult::Ignored;
            };
            if !event.input.is_continuation()
                && let (Some(x), Some(y)) = (event.mouse_x, event.mouse_y)
                && !wheel_snap.image_frame(&node).contains(x, y)
            {
                return EventResult::Ignored;
            }
            if let Some(handler) = &wheel_snap.on_input_event {
                handler(InputEvent::MouseWheel(event.clone()));
            }
            EventResult::Handled
        }),
    );

    let key_down_snap = Snapshot::new(host);
    registry.set_key(
        node,
        route.clone(),
        Rc::new(move |event, _| {
            if let Some(handler) = &key_down_snap.on_input_event {
                handler(InputEvent::KeyDown(event.clone()));
            }
            if ViewportHost::consumes_key(event)
                || key_down_snap
                    .key_consumption
                    .as_ref()
                    .is_some_and(|consume| consume(event))
            {
                EventResult::Handled
            } else {
                EventResult::Ignored
            }
        }),
    );

    let key_up_snap = Snapshot::new(host);
    registry.set_key_up(
        node,
        route.clone(),
        Rc::new(move |event, _| {
            if let Some(handler) = &key_up_snap.on_input_event {
                handler(InputEvent::KeyUp(event.clone()));
            }
            if ViewportHost::consumes_key(event)
                || key_up_snap
                    .key_consumption
                    .as_ref()
                    .is_some_and(|consume| consume(event))
            {
                EventResult::Handled
            } else {
                EventResult::Ignored
            }
        }),
    );

    let text_snap = Snapshot::new(host);
    registry.set_text(
        node,
        route.clone(),
        Rc::new(move |text, _| {
            if let Some(handler) = &text_snap.on_input_event {
                handler(InputEvent::TextInput(text.to_string()));
            }
            EventResult::Handled
        }),
    );

    let editing_snap = Snapshot::new(host);
    registry.set_editing(
        node,
        route,
        Rc::new(move |event, _| {
            if let Some(handler) = &editing_snap.on_input_event {
                handler(InputEvent::TextEditing(event.clone()));
            }
            EventResult::Handled
        }),
    );
}

fn register_draw(node: &Node, host: &ViewportHost) {
    let snap = Snapshot::new(host);
    let identity = DrawIdentity {
        surface: snap.surface.clone(),
        aspect_ratio: snap.content_aspect_ratio,
    };
    let draw_node = node.clone();
    node.update_draw(identity, move |list, origin| {
        let node = &draw_node;
        // Report the drawable in physical pixels: the layout frame is in
        // logical points, so honor the window's content scale or the
        // scene renders at 1/scale² resolution and gets upscaled blurry.
        let scale = cove_ui_compose::scene_core::content_scale().max(1.0);
        let layout_frame = node.frame();
        let screen_frame = ViewportPresentationGeometry::fit(
            ViewportScreenFrame::new(origin.x, origin.y, layout_frame.width, layout_frame.height),
            snap.content_aspect_ratio,
        );
        let width = ((screen_frame.width * scale).round() as i64).max(1) as u32;
        let height = ((screen_frame.height * scale).round() as i64).max(1) as u32;
        let drawable_size = RenderDrawableSize::new(width, height);
        let previous = node.attachment::<RenderDrawableSize>(DRAWABLE_SIZE_ATTACHMENT);
        if previous != Some(drawable_size) {
            node.set_attachment(DRAWABLE_SIZE_ATTACHMENT, drawable_size);
            if let Some(handler) = &snap.on_drawable_size_change {
                handler(drawable_size);
            }
        }

        let previous_frame = node.attachment::<ViewportScreenFrame>(SCREEN_FRAME_ATTACHMENT);
        if previous_frame != Some(screen_frame) {
            node.set_attachment(SCREEN_FRAME_ATTACHMENT, screen_frame);
            if let Some(handler) = &snap.on_screen_frame_change {
                handler(screen_frame);
            }
        }

        if !snap.surface.is_valid() {
            return;
        }
        let Some(output) = snap.surface.image.clone() else {
            return;
        };

        let rect = cove_ui_compose::scene_core::Rect::new(
            screen_frame.x,
            screen_frame.y,
            screen_frame.width,
            screen_frame.height,
        );
        let cache = match node.attachment::<ImageCache>(IMAGE_ATTACHMENT) {
            Some(existing) if Arc::ptr_eq(&existing.output, &output) => existing,
            _ => {
                let Ok(image) = texture_image(output.resource.clone(), output.mipmaps.clone())
                else {
                    return;
                };
                let cache = ImageCache {
                    output: output.clone(),
                    image,
                };
                node.set_attachment(IMAGE_ATTACHMENT, cache.clone());
                cache
            }
        };
        let region = &snap.surface.region;
        let selected = cache.image.resolution(
            cove_ui_compose::scene_core::Size {
                width: rect.width * list.pixel_scale.max(1.0),
                height: rect.height * list.pixel_scale.max(1.0),
            },
            Some(cove_ui_compose::scene_core::Size {
                width: region.size.width as f32,
                height: region.size.height as f32,
            }),
        );
        list.resources.retain(selected.clone());
        // The engine renders into the top-left sub-region of a grow-only
        // allocated texture; crop to the used extent.
        let extent = region.uv_max();
        let uv_min = Point::new(0.0, 0.0);
        let uv_max = Point::new(extent.x, extent.y);
        let tint = node.foreground_color().unwrap_or(Color::WHITE);
        if Arc::ptr_eq(&selected, &cache.image) {
            let _ = list.add_clamped_image_quad(
                rect,
                selected.texture_id,
                Point::new(
                    1.0 / region.capacity.width as f32,
                    1.0 / region.capacity.height as f32,
                ),
                tint,
                uv_min,
                uv_max,
            );
        } else {
            let _ = list.add_image_quad(rect, selected.texture_id, tint, uv_min, uv_max);
        }

        if let Some(handler) = &snap.on_draw_overlay {
            handler(list, screen_frame);
        }
    });
}

#[derive(Clone)]
struct ImageCache {
    output: Arc<ViewportImage>,
    image: Arc<TextureImage>,
}

#[derive(PartialEq)]
struct DrawIdentity {
    surface: ViewportSurfaceState,
    aspect_ratio: Option<f32>,
}

pub struct ViewportPresentationGeometry;

impl ViewportPresentationGeometry {
    pub fn fit(frame: ViewportScreenFrame, aspect_ratio: Option<f32>) -> ViewportScreenFrame {
        let Some(aspect_ratio) = aspect_ratio else {
            return frame;
        };
        if !aspect_ratio.is_finite()
            || aspect_ratio <= 0.0
            || frame.width <= 0.0
            || frame.height <= 0.0
        {
            return frame;
        }
        let width = frame.width.min(frame.height * aspect_ratio);
        let height = width / aspect_ratio;
        ViewportScreenFrame::new(
            frame.x + (frame.width - width) / 2.0,
            frame.y + (frame.height - height) / 2.0,
            width,
            height,
        )
    }
}
