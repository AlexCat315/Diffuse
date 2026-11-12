//! Ported from `Engine/Tests/NativeRendererTests/NativeEditorGridTests.swift`.

use std::sync::Arc;

use cove_graphics::rhi::{
    BindingLayoutDescriptor, BindingLayoutEntry, BindingSetDescriptor, BindingSetEntry,
    BindingType, BufferDescriptor, BufferUsage, CommandBuffer, DepthLoadAction, QueueClass,
    RenderColorTarget, RenderDepthTarget, RenderPassDescriptor, ShaderVisibility,
    TextureDescriptor, TextureFormat, TextureUsage,
};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_render::RenderDrawableSize;
use diffuse_render::native::passes::native_editor_grid_pass::NativeEditorGridPass;
use diffuse_render::native::passes::native_grid_renderer::NativeGridRenderer;
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection};

use crate::probes::grid_probe_scene::GridProbeScene;
use crate::reference::grid_image::GridImage;
use crate::tests::native_renderer::support::{device, lock_serial};

fn camera(eye: Float3, target: Float3) -> RenderCamera {
    RenderCamera::new(eye, target)
}

fn orthographic(eye: Float3) -> RenderCamera {
    RenderCamera {
        eye,
        target: Float3::ZERO,
        projection: RenderCameraProjection::Orthographic,
        orthographic_height: 8.0,
        ..RenderCamera::default()
    }
}

fn clear_color_target(color: cove_graphics::rhi::Texture) -> RenderColorTarget {
    RenderColorTarget::clearing(color, [0.08, 0.10, 0.14, 1.0])
}

/// Uniform buffer bindings reject sizes outside the buffer.
#[test]
fn uniform_range_validation() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
        return;
    };
    let layout = device
        .make_binding_layout(BindingLayoutDescriptor::new(vec![BindingLayoutEntry::new(
            0,
            BindingType::UniformBuffer,
            ShaderVisibility::FRAGMENT,
        )]))
        .expect("layout");
    let buffer = device
        .make_buffer(BufferDescriptor::new(512, BufferUsage::UNIFORM))
        .expect("buffer");
    for size in [Some(0_usize), Some(513), Some(usize::MAX)] {
        let result = device.make_binding_set(
            layout,
            BindingSetDescriptor::new(vec![BindingSetEntry::new(
                0,
                cove_graphics::rhi::BindingResource::UniformBuffer {
                    buffer,
                    offset: 0,
                    size,
                },
            )]),
        );
        assert!(result.is_err(), "size {size:?} must be rejected");
    }
    device
        .make_binding_set(
            layout,
            BindingSetDescriptor::new(vec![BindingSetEntry::new(
                0,
                cove_graphics::rhi::BindingResource::UniformBuffer {
                    buffer,
                    offset: 0,
                    size: Some(192),
                },
            )]),
        )
        .expect("valid size");

    device.destroy_buffer(buffer);
    let _ = layout;
}

/// The grid pass loads depth and color from the surrounding render pass.
#[test]
fn grid_loads_depth_and_color() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let grid = NativeEditorGridPass::new(&device).expect("grid pass");
    let size = RenderDrawableSize::new(128, 128);
    let color = device
        .make_texture(
            TextureDescriptor::new(
                size.width as usize,
                size.height as usize,
                TextureFormat::Bgra8Unorm,
                TextureUsage::COLOR_TARGET | TextureUsage::TRANSFER_SOURCE,
            )
            .with_label("grid-color"),
        )
        .expect("color texture");
    let depth = device
        .make_texture(
            TextureDescriptor::new(
                size.width as usize,
                size.height as usize,
                TextureFormat::Depth32Float,
                TextureUsage::DEPTH_STENCIL_TARGET,
            )
            .with_label("grid-depth"),
        )
        .expect("depth texture");
    let packet = GridProbeScene::packet(size, 0, None);

    let mut images: Vec<Vec<u8>> = Vec::new();
    for clear in [0.0_f64, 1.0_f64] {
        device.begin_frame().expect("frame");
        let mut commands = CommandBuffer::new();
        commands.render_pass(
            RenderPassDescriptor::new(vec![clear_color_target(color)]).with_depth(
                RenderDepthTarget::new(depth).with_load_action(DepthLoadAction::Clear(clear)),
            ),
            |_| {},
        );
        grid.encode(
            &packet,
            RenderColorTarget {
                load_action: cove_graphics::rhi::ColorLoadAction::Load,
                ..RenderColorTarget::new(color)
            },
            RenderDepthTarget::new(depth).with_load_action(DepthLoadAction::Load),
            &mut commands,
        )
        .expect("grid encode");
        device
            .submit(&commands, QueueClass::Graphics, &[], &[], None)
            .expect("submit");
        device.end_frame();
        images.push(GridImage::readback(&device, color, size).expect("readback"));
    }

    let pixel = [36_u8, 26, 20, 255];
    let expected: Vec<u8> = pixel.iter().copied().cycle().take(128 * 128 * 4).collect();
    assert_eq!(images[0], expected, "depth zero preserves the clear color");
    assert!(
        GridImage::difference(&images[0], &images[1])
            .expect("difference")
            .pixels_over_three
            > 300
    );

    device.destroy_texture(color);
    device.destroy_texture(depth);
    grid.destroy();
}

/// The grid covers visible planes and discards frames looking above the ground.
#[test]
fn grid_coverage_across_cameras() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let renderer = NativeGridRenderer::new(&device, None).expect("grid renderer");
    let size = RenderDrawableSize::new(192, 128);
    let mut cameras = vec![
        camera(Float3::new(7.0, 6.0, 9.0), Float3::ZERO),
        orthographic(Float3::new(0.0, 0.0, 8.0)),
        orthographic(Float3::new(8.0, 0.0, 0.0)),
        RenderCamera {
            up: Float3::new(0.0, 0.0, -1.0),
            ..orthographic(Float3::new(0.0, 8.0, 0.0))
        },
        camera(Float3::new(3.0, 1.0, 5.0), Float3::new(3.0, 4.0, 7.0)),
    ];
    cameras[4].near = 0.1;
    cameras[4].far = 100.0;
    for (index, camera) in cameras.into_iter().enumerate() {
        let mut packet = GridProbeScene::packet(size, index as i64, Some(camera));
        renderer.render_checked(&packet).expect("grid frame");
        let native = GridImage::readback(&device, renderer.color_texture().expect("color"), size)
            .expect("readback");
        assert_eq!(native.len(), size.width as usize * size.height as usize * 4);

        packet.render_settings.viewport.grid_enabled = false;
        renderer.render_checked(&packet).expect("clear frame");
        let clear = GridImage::readback(&device, renderer.color_texture().expect("color"), size)
            .expect("readback");
        if index < 4 {
            assert!(
                GridImage::difference(&native, &clear)
                    .expect("difference")
                    .pixels_over_three
                    > 300
            );
        } else {
            assert_eq!(
                native, clear,
                "looking above the ground must discard the grid"
            );
        }
        assert_eq!(renderer.current_frame_stats().draw_call_count, 0);
    }

    device.wait_until_idle().expect("idle");
}

/// Resizes and rejected frames leave the grid renderer usable.
#[test]
fn grid_renderer_resize_and_transient_frames() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let renderer = NativeGridRenderer::new(&device, None).expect("grid renderer");
    let mut packet = GridProbeScene::packet(RenderDrawableSize::new(160, 96), 0, None);
    for frame in 0..36 {
        packet.frame_index = frame;
        if frame >= 17 {
            packet.drawable_size = RenderDrawableSize::new(96, 160);
        }
        packet.render_settings.viewport.grid_spacing = if frame % 2 == 0 { 0.25 } else { 0.75 };
        renderer.render_checked(&packet).expect("frame");
    }
    let image = GridImage::readback(
        &device,
        renderer.color_texture().expect("color"),
        packet.drawable_size,
    )
    .expect("readback");
    assert!(!image.is_empty());
    let stats = renderer.current_frame_stats();
    assert_eq!(stats.frame_index, 35);
    assert_eq!(
        stats
            .pass_draw_call_counts
            .get(&diffuse_render::RenderPassKind::EditorGrid)
            .copied(),
        Some(1)
    );

    // A rejected frame leaves the frame ring usable for the next packet.
    packet.drawable_size.width = 0;
    assert!(renderer.render_checked(&packet).is_err());
    packet.drawable_size.width = 96;
    packet.frame_index = 36;
    renderer.render_checked(&packet).expect("next frame");

    device.wait_until_idle().expect("idle");
}
