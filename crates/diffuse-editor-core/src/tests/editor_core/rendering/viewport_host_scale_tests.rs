//! Ported from `Editor/Tests/EditorCoreTests/Rendering/ViewportHostScaleTests.swift`.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use cove_graphics::rhi::{
    Device, DeviceConfig, TextureDescriptor, TextureFormat, TextureResource, TextureUsage,
};
use cove_ui_compose::PrimitiveView;
use cove_ui_compose::core_exports::cove_imaging::TextureImage;
use cove_ui_compose::prelude::LayoutFrameExt;
use cove_ui_compose::rendering::OffscreenView;
use cove_ui_compose::scene_core::{
    DrawListSnapshot, FocusChain, FocusChainHolder, GeometryAntialiasing, Node,
};

use crate::rendering::viewport::viewport_host::{ViewportHost, ViewportScreenFrame};
use diffuse_render::RenderDrawableSize;
use diffuse_render::surface::viewport_image::ViewportImage;
use diffuse_render::surface::viewport_surface::{ViewportSamplingRegion, ViewportSurfaceState};

fn draw_image_values(snapshot: &DrawListSnapshot) -> (f32, f32) {
    let max_u = snapshot
        .vertices
        .iter()
        .map(|vertex| vertex.u - 10.0)
        .fold(-1.0f32, f32::max);
    let max_v = snapshot
        .vertices
        .iter()
        .map(|vertex| vertex.v)
        .fold(-1.0f32, f32::max);
    (max_u, max_v)
}

/// Standalone viewport accepts keys immediately without stealing subsequent focus.
#[test]
fn initial_keyboard_focus() {
    let previous = FocusChainHolder::current();
    let focus = Rc::new(FocusChain::new());
    FocusChainHolder::set_current(Some(focus.clone()));

    let embedded = ViewportHost::without_overlay(ViewportSurfaceState::default());
    let embedded_node = embedded.make_node();
    embedded.update_node(&embedded_node);
    assert!(focus.focused().is_none());

    let standalone =
        ViewportHost::without_overlay(ViewportSurfaceState::default()).automatically_focus(true);
    let node = standalone.make_node();
    standalone.update_node(&node);
    assert_eq!(focus.focused().as_ref(), Some(&node));
    assert!(!focus.is_focus_visible());

    let field = Node::new();
    field.set_is_focusable(true);
    focus.focus(Some(&field), true);
    standalone.update_node(&node);
    assert_eq!(focus.focused().as_ref(), Some(&field));

    focus.clear();
    standalone.update_node(&node);
    assert!(focus.focused().is_none());

    FocusChainHolder::set_current(previous);
}

/// Reports the drawable size in physical pixels honoring the content scale.
#[test]
fn reports_pixel_drawable_size() {
    let reported: Rc<RefCell<Vec<RenderDrawableSize>>> = Rc::new(RefCell::new(Vec::new()));
    let sink = reported.clone();
    let host = ViewportHost::without_overlay(ViewportSurfaceState::default())
        .on_drawable_size_change(Rc::new(move |size| sink.borrow_mut().push(size)))
        .frame_size(200.0, 120.0);

    let mut view = OffscreenView::new(GeometryAntialiasing::Multisample);
    view.set_root_view(host);
    assert!(view.render(200, 120, 2.0).is_some());

    let reported = reported.borrow();
    assert_eq!(
        reported.last().copied(),
        Some(RenderDrawableSize::new(400, 240))
    );
}

/// Composites only the used sub-region of the allocated texture.
#[test]
fn crops_to_used_region() {
    let device = Arc::new(
        Device::make(DeviceConfig::default()).expect("headless graphics device for viewport test"),
    );
    let texture = Arc::new(
        TextureResource::new(
            device,
            TextureDescriptor::new(
                512,
                256,
                TextureFormat::Bgra8Unorm,
                TextureUsage::COLOR_TARGET | TextureUsage::SAMPLED,
            )
            .with_label("viewport-host-scale-test"),
        )
        .expect("viewport test texture"),
    );

    let surface = ViewportSurfaceState::with_region(
        7,
        Some(Arc::new(ViewportImage::new(texture, Vec::new()))),
        ViewportSamplingRegion::new(
            RenderDrawableSize::new(300, 200),
            RenderDrawableSize::new(512, 256),
        ),
    );
    let frames: Rc<RefCell<Vec<ViewportScreenFrame>>> = Rc::new(RefCell::new(Vec::new()));
    let frame_sink = frames.clone();
    let host = ViewportHost::without_overlay(surface)
        .on_screen_frame_change(Rc::new(move |frame| frame_sink.borrow_mut().push(frame)))
        .frame_size(200.0, 120.0);

    let mut view = OffscreenView::new(GeometryAntialiasing::Multisample);
    view.set_root_view(host);
    let snapshot = view.render(200, 120, 1.0).expect("viewport frame");

    assert_eq!(frames.borrow().len(), 1);
    // The viewport keeps exactly one sampled texture image: its own surface.
    let mut images: Vec<Arc<TextureImage>> = Vec::new();
    snapshot
        .resources
        .for_each_retained::<TextureImage>(|image| images.push(image));
    assert_eq!(images.len(), 1);
    assert_eq!(images[0].pixel_size.width, 512);
    assert_eq!(images[0].pixel_size.height, 256);

    let (max_u, max_v) = draw_image_values(&snapshot);
    assert!((max_u - 299.5 / 512.0).abs() < 1e-5, "max u = {max_u}");
    assert!((max_v - 199.5 / 256.0).abs() < 1e-5, "max v = {max_v}");

    // The clamped image quad is the only textured batch; the themed backdrop
    // is untextured.
    assert_eq!(
        snapshot
            .batches
            .iter()
            .filter(|batch| batch.texture_id != 0)
            .count(),
        1
    );
}
