//! Ported from `Editor/Tests/EditorCoreTests/Rendering/NativeViewportIntegrationTests.swift`.

use std::collections::HashSet;
use std::sync::Arc;

use cove_graphics::rhi::{
    CommandBuffer, Device, DeviceConfig, QueueClass, RenderColorTarget, RhiResult,
    TextureDescriptor, TextureFormat, TextureResource, TextureSubresource, TextureUploadRegion,
    TextureUsage,
};
use cove_graphics::ui::texture_image;
use cove_ui_compose::PrimitiveView;
use cove_ui_compose::scene_core::{DrawList, DrawListSnapshot, Point, Rect, TextureId};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_render::RenderDrawableSize;
use diffuse_render::RenderSettings;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::surface::viewport_image::ViewportImage;
use diffuse_render::surface::viewport_surface::{ViewportSamplingRegion, ViewportSurfaceState};
use diffuse_render_validation::GridImage;
use diffuse_render_validation::PostProbeScene;
use diffuse_render_validation::probes::mesh_probe_scene::MeshProbeScene;

use crate::rendering::viewport::viewport_host::ViewportHost;
use crate::tests::editor_core::rendering::native_viewport_test_context::{
    NativeViewportTestContext, ViewportTestOutput,
};

fn gpu_resources_available() -> bool {
    std::env::var_os("COVE_RESOURCE_PATH").is_some()
}

fn scene_renderer(device: &Arc<Device>) -> RhiResult<NativeRenderer> {
    NativeRenderer::new(
        device,
        None,
        AssetRegistry::shared(),
        None,
        &RenderSettings::default(),
        &[],
    )
}

fn snapshot_of(list: &DrawList, logical_size: [f32; 2]) -> DrawListSnapshot {
    DrawListSnapshot {
        vertices: list.vertices().to_vec(),
        indices: list.indices().to_vec(),
        batches: list.batches().to_vec(),
        logical_size,
        atlas_updates: Vec::new(),
        resources: list.resources.clone(),
    }
}

fn add_image_quad(list: &mut DrawList, rect: Rect, texture_id: TextureId) {
    let _ = list.add_image_quad(
        rect,
        texture_id,
        cove_ui_compose::scene_core::Color::WHITE,
        Point::new(0.0, 0.0),
        Point::new(1.0, 1.0),
    );
}

/// Scene and post-processing passes stay visible through viewport resize.
#[test]
fn scene_and_post_viewport_remain_visible_after_resize() {
    if !gpu_resources_available() {
        return;
    }
    let mut context = NativeViewportTestContext::new().expect("test context");
    let mut scene = scene_renderer(&context.device).expect("scene renderer");
    for post in [false, true] {
        for size in [
            RenderDrawableSize::new(192, 128),
            RenderDrawableSize::new(64, 32),
            RenderDrawableSize::new(256, 96),
        ] {
            let mut packet = if post {
                PostProbeScene::packet(size, 0)
            } else {
                MeshProbeScene::packet(size, 0)
            };
            packet.render_settings.post_processing.taa = false;
            packet.render_settings.post_processing.ssr = false;
            scene.render_checked(&packet).expect("scene frame");
            let surface = scene.current_viewport_surface_state();
            assert!(surface.is_valid());
            assert_eq!(surface.region.size, size);
            let list = context.draw_list(&surface);
            assert_eq!(list.resources.len(), 1);
            for output in ViewportTestOutput::CASES {
                let pixels = context.native_image(&list, output).expect("native image");
                assert_eq!(pixels.len(), context.size.0 * context.size.1 * 4);
                let distinct = pixels
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|pixel| pixel[0])
                    .collect::<HashSet<_>>();
                assert!(distinct.len() > 8);
            }
        }
    }
}

/// Old and new images keep distinct bindings through snapshots and submission.
#[test]
fn old_and_new_images_keep_distinct_bindings() {
    if !gpu_resources_available() {
        return;
    }
    let mut context = NativeViewportTestContext::new().expect("test context");
    let old = context
        .solid_surface([1.0, 0.0, 0.0, 1.0], None)
        .expect("old surface");
    let new = context
        .solid_surface([0.0, 1.0, 0.0, 1.0], None)
        .expect("new surface");
    let old_lease = Arc::downgrade(old.image.as_ref().expect("old image"));
    let new_lease = Arc::downgrade(new.image.as_ref().expect("new image"));
    let old_image = texture_image(
        old.image.as_ref().expect("old image").resource.clone(),
        Vec::new(),
    )
    .expect("old texture image");
    let new_image = texture_image(
        new.image.as_ref().expect("new image").resource.clone(),
        Vec::new(),
    )
    .expect("new texture image");
    let old_id = old_image.texture_id;
    let new_id = new_image.texture_id;
    assert_ne!(old_id, new_id, "producer-local surface IDs can coincide");

    let mut list = DrawList::default();
    list.resources.retain(old_image.clone());
    list.resources.retain(new_image.clone());
    add_image_quad(&mut list, Rect::new(0.0, 0.0, 96.0, 128.0), old_id);
    add_image_quad(&mut list, Rect::new(96.0, 0.0, 96.0, 128.0), new_id);
    let mut snapshot = snapshot_of(&list, [192.0, 128.0]);
    drop(old);
    drop(new);
    drop(old_image);
    drop(new_image);
    list.reset();

    // The owned GPU images retain the texture resources independently of
    // the scene publication objects.
    assert!(old_lease.upgrade().is_none());
    assert!(new_lease.upgrade().is_none());
    assert_eq!(snapshot.resources.len(), 2);

    let mut restored = DrawList::default();
    restored
        .load(
            std::mem::take(&mut snapshot.vertices),
            std::mem::take(&mut snapshot.indices),
            std::mem::take(&mut snapshot.batches),
            snapshot.resources.clone(),
        )
        .expect("restore snapshot");
    snapshot.resources.reset();

    let output = context
        .texture(TextureFormat::Bgra8Unorm, 1)
        .expect("output texture");
    context.device.begin_frame().expect("begin frame");
    let mut commands = CommandBuffer::new();
    let recorded = context.native_ui.record(
        &restored,
        &mut commands,
        RenderColorTarget::new(output.texture()),
        cove_graphics::ui::NativeUIViewport::new([context.size.0, context.size.1], [192.0, 128.0]),
        None,
    );
    let Ok(mut frame) = recorded else {
        context.device.end_frame();
        panic!("native recording failed");
    };
    // The two quad bindings remain distinct inside the recording. Cove's
    // texture store is private; the batches are the observable identity set.
    let bound: HashSet<TextureId> = restored
        .batches()
        .iter()
        .map(|batch| batch.texture_id)
        .collect();
    assert_eq!(bound.len(), 2);
    restored.reset();
    assert!(old_lease.upgrade().is_none());
    assert!(new_lease.upgrade().is_none());

    // The recording token owns borrowed textures until submission, even when
    // every source lease and registry binding is released.
    let submitted = context
        .device
        .submit(&commands, QueueClass::Graphics, &[], &[], None);
    frame.did_submit();
    context.device.end_frame();
    submitted.expect("submit");

    let pixels = GridImage::readback(
        &context.device,
        output.texture(),
        RenderDrawableSize::new(384, 256),
    )
    .expect("readback");
    assert_eq!(&pixels[0..4], [0, 0, 255, 255]);
    assert_eq!(&pixels[(383 * 4)..(384 * 4)], [0, 255, 0, 255]);
}

/// Linear upscaling never samples the high-contrast padding texels.
#[test]
fn linear_upscaling_never_samples_padding() {
    if !gpu_resources_available() {
        return;
    }
    let mut context = NativeViewportTestContext::new().expect("test context");
    let capacity = RenderDrawableSize::new(8, 8);
    for size in [
        RenderDrawableSize::new(3, 2),
        RenderDrawableSize::new(1, 3),
        RenderDrawableSize::new(3, 1),
        RenderDrawableSize::new(1, 1),
    ] {
        let mut pixels = Vec::with_capacity(8 * 8 * 4);
        for y in 0..8 {
            for x in 0..8 {
                let inside = x < size.width && y < size.height;
                pixels.extend_from_slice(if inside {
                    &[0, 255, 0, 255]
                } else {
                    &[255, 0, 255, 255]
                });
            }
        }
        let native = TextureResource::new(
            context.device.clone(),
            TextureDescriptor::new(
                8,
                8,
                TextureFormat::Bgra8Unorm,
                TextureUsage::SAMPLED | TextureUsage::TRANSFER_DESTINATION,
            ),
        )
        .expect("native texture");
        context
            .device
            .upload_texture_data(
                native.texture(),
                &pixels,
                TextureUploadRegion::new(8, 8),
                32,
                TextureSubresource::default(),
            )
            .expect("upload");
        let region = ViewportSamplingRegion::new(size, capacity);
        let surface = ViewportSurfaceState::with_region(
            1,
            Some(Arc::new(ViewportImage::new(Arc::new(native), Vec::new()))),
            region,
        );
        let host = ViewportHost::without_overlay(surface);
        let node = host.make_node();
        node.set_frame(Rect::new(0.13, 0.27, 191.4, 127.3));
        host.update_node(&node);
        let mut list = DrawList::default();
        if let Some(draw) = node.draw() {
            draw(&mut list, Point::new(0.0, 0.0));
        }
        assert_eq!(list.batches().len(), 1);
        for output in ViewportTestOutput::CASES {
            let actual = context.native_image(&list, output).expect("native image");
            let green = [0u8, 255, 0, 255]
                .iter()
                .copied()
                .cycle()
                .take((context.size.0 - 4) * 4)
                .collect::<Vec<_>>();
            for y in 2..(context.size.1 - 2) {
                let begin = (y * context.size.0 + 2) * 4;
                let end = (y * context.size.0 + context.size.0 - 2) * 4;
                assert_eq!(
                    &actual[begin..end],
                    green.as_slice(),
                    "{size:?}, {output:?} must exclude every padding texel"
                );
            }
        }
    }
}

/// The bridge rejects textures owned by a different device.
#[test]
fn bridge_rejects_mismatched_devices() {
    if !gpu_resources_available() {
        return;
    }
    let mut context = NativeViewportTestContext::new().expect("test context");
    let foreign = Arc::new(Device::make(DeviceConfig::default()).expect("foreign device"));
    let other = context
        .solid_surface([1.0, 0.0, 0.0, 1.0], Some(&foreign))
        .expect("foreign surface");
    let list = context.draw_list(&other);
    assert!(
        context
            .native_image(&list, ViewportTestOutput::CASES[0])
            .is_err()
    );
}
