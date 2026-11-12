//! Ported from `Engine/Tests/NativeRendererTests/NativeOpaqueTests.swift`.

use std::sync::Arc;

use diffuse_assets::asset_pipeline::BuiltinMesh;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::{DebugViewMode, RenderDrawableSize, RenderSettings};
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderCameraProjection, RenderInstance, RenderMaterial, RenderMeshHandle,
    RenderMeshLOD,
};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::reference::scene_capture::SceneCapture;
use crate::tests::native_renderer::support::{device, lock_serial};

fn render(
    context: &mut NativeRenderer,
    device: &Arc<cove_graphics::rhi::Device>,
    packet: &diffuse_render::RenderPacket,
) -> Vec<u8> {
    context.render_checked(packet).expect("render frame");
    GridImage::readback(
        device,
        context.color_texture().expect("color"),
        packet.drawable_size,
    )
    .expect("readback")
}

/// Frustum culling, distance LOD and instancing are reflected in the stats.
#[test]
fn visibility_and_lod() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let assets: &'static AssetRegistry = Box::leak(Box::new(AssetRegistry::new()));
    let cube = BuiltinMesh::cube(Some(Float3::splat(1.0)));
    let mut simplified = cube.clone();
    simplified.indices = cube.indices[..3].to_vec();
    assets.register_for_testing(cube, 45);
    assets.register_for_testing(simplified, 46);

    let Some(device) = device::make_for(device::validation_api(), false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut renderer =
        NativeRenderer::new(&device, None, assets, None, &RenderSettings::new(), &[])
            .expect("renderer");
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(96, 96), 0);
    packet.scene.camera = RenderCamera::new(Float3::new(0.0, 0.0, 5.0), Float3::ZERO);
    let mut distant = MATRIX_IDENTITY_FLOAT4X4;
    distant.columns[3].x = 10_000.0;
    packet.scene.instances = vec![
        RenderInstance::new(
            RenderMeshHandle::new(45, None, vec![RenderMeshLOD::new(46, 1.0)]),
            MATRIX_IDENTITY_FLOAT4X4,
        ),
        RenderInstance::from_mesh_index(
            45,
            distant,
            Float3::splat(1.0),
            RenderMaterial::fallback(),
            None,
        ),
    ];
    renderer.render_checked(&packet).expect("first frame");
    let stats = renderer.current_frame_stats();
    assert_eq!(stats.visible_mesh_instance_count, 1);
    assert_eq!(stats.culled_mesh_instance_count, 1);
    assert_eq!(stats.lod_mesh_instance_count, 1);
    assert_eq!(stats.submitted_mesh_triangle_count, 1);

    packet.render_settings.visibility.distance_lod = false;
    renderer.render_checked(&packet).expect("no LOD frame");
    assert_eq!(
        renderer.current_frame_stats().submitted_mesh_triangle_count,
        12
    );

    packet.render_settings.visibility.frustum_culling = false;
    packet.render_settings.visibility.mesh_instancing = false;
    renderer.render_checked(&packet).expect("unculled frame");
    let stats = renderer.current_frame_stats();
    assert_eq!(stats.visible_mesh_instance_count, 2);
    assert_eq!(stats.culled_mesh_instance_count, 0);
    assert_eq!(
        stats
            .pass_draw_call_counts
            .get(&diffuse_render::RenderPassKind::BasePass)
            .copied(),
        Some(2)
    );
    assert_eq!(stats.submitted_mesh_triangle_count, 24);

    device.wait_until_idle().expect("idle");
}

/// Debug view modes and grid/orthographic frames match the reference capture.
#[test]
fn parity_across_debug_modes() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut renderer = NativeRenderer::new(
        &device,
        None,
        AssetRegistry::shared(),
        None,
        &RenderSettings::new(),
        &[],
    )
    .expect("renderer");
    let mut reference = SceneCapture::new(true, Some(api), None).expect("reference");
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(256, 192), 0);
    for mode in [
        DebugViewMode::Unlit,
        DebugViewMode::BaseColor,
        DebugViewMode::WorldNormal,
        DebugViewMode::Roughness,
        DebugViewMode::Metallic,
    ] {
        packet.render_settings.shading.debug_view_mode = mode;
        packet.frame_index += 1;
        renderer.render_checked(&packet).expect("native frame");
        reference.render(&packet).expect("reference frame");
        let native = GridImage::readback(
            &device,
            renderer.color_texture().expect("color"),
            packet.drawable_size,
        )
        .expect("native readback");
        let expected = reference.readback().expect("reference readback");
        let delta = GridImage::difference(&native, &expected).expect("difference");
        assert!(
            delta.mean_absolute_channel_error < 0.5,
            "{api:?} {mode:?}: {delta:?}"
        );
        assert!(
            delta.pixels_over_three < delta.pixel_count / 100,
            "{api:?} {mode:?}: {delta:?}"
        );
        let native_stats = renderer.current_frame_stats();
        let reference_stats = reference.renderer.current_frame_stats();
        assert_eq!(
            native_stats.submitted_mesh_triangle_count,
            reference_stats.submitted_mesh_triangle_count
        );
        assert_eq!(
            native_stats.visible_mesh_instance_count,
            reference_stats.visible_mesh_instance_count
        );
        assert_eq!(
            native_stats
                .pass_draw_call_counts
                .get(&diffuse_render::RenderPassKind::BasePass),
            reference_stats
                .pass_draw_call_counts
                .get(&diffuse_render::RenderPassKind::BasePass)
        );
        assert!(native_stats.instanced_mesh_batch_count > 0);
    }

    packet.render_settings.shading.debug_view_mode = DebugViewMode::Unlit;
    packet.render_settings.viewport.grid_enabled = true;
    packet.scene.camera.projection = RenderCameraProjection::Orthographic;
    packet.scene.camera.orthographic_height = 12.0;
    packet.frame_index += 1;
    renderer.render_checked(&packet).expect("grid frame");
    reference.render(&packet).expect("reference grid frame");
    let native = GridImage::readback(
        &device,
        renderer.color_texture().expect("color"),
        packet.drawable_size,
    )
    .expect("native readback");
    let delta = GridImage::difference(&native, &reference.readback().expect("reference"))
        .expect("difference");
    assert!(delta.mean_absolute_channel_error < 0.5);

    // One-pass base and depth+base must produce the same material/depth result.
    packet.render_settings.shading.pbr = false;
    packet.render_settings.shading.depth_prepass = false;
    packet.frame_index += 1;
    renderer.render_checked(&packet).expect("one-pass frame");
    let one_pass = GridImage::readback(
        &device,
        renderer.color_texture().expect("color"),
        packet.drawable_size,
    )
    .expect("readback");
    assert_eq!(native, one_pass);

    device.wait_until_idle().expect("idle");
}

/// Imported textures and submeshes match the reference and mask holes correctly.
#[test]
fn imported_textures_and_submeshes() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let asset = MeshProbeScene::imported_fixture().expect("fixture");
    assert_eq!(asset.submeshes.len(), 2);
    assert_eq!(asset.textures.len(), 1);
    AssetRegistry::shared().register_for_testing(asset, 2);
    let Some(device) = device::make_for(api, false).expect("device") else {
        AssetRegistry::shared().unregister_testing_mesh(2);
        return;
    };
    let device = Arc::new(device);
    let mut renderer = NativeRenderer::new(
        &device,
        None,
        AssetRegistry::shared(),
        None,
        &RenderSettings::new(),
        &[],
    )
    .expect("renderer");
    let mut reference = SceneCapture::new(true, Some(api), None).expect("reference");

    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(192, 128), 0);
    packet.render_settings.shading.pbr = false;
    packet.render_settings.shading.depth_prepass = true;
    packet.scene.camera = RenderCamera::new(Float3::new(0.0, 0.0, 5.0), Float3::ZERO);
    let mut back = MATRIX_IDENTITY_FLOAT4X4;
    back.columns[0].x = 2.0;
    back.columns[1].y = 2.0;
    back.columns[3].z = -1.5;
    packet.scene.instances = vec![
        RenderInstance::from_mesh_index(
            2,
            MATRIX_IDENTITY_FLOAT4X4,
            Float3::splat(1.0),
            RenderMaterial::fallback(),
            None,
        ),
        RenderInstance::from_mesh_index(
            0,
            back,
            Float3::splat(1.0),
            RenderMaterial {
                base_color_factor: Float4::new(0.2, 0.5, 0.25, 1.0),
                ..RenderMaterial::fallback()
            },
            None,
        ),
    ];
    let directory = std::env::temp_dir().join(format!("cove-native-mask-{api:?}"));
    std::fs::create_dir_all(&directory).expect("output directory");

    for frame in 0..3 {
        packet.frame_index = frame;
        if frame == 1 {
            packet.scene.instances.reverse();
        }
        if frame == 2 {
            packet.scene.instances[1].transform.columns[0].x = -1.0;
            packet.scene.instances[1].material.base_color_factor = Float4::new(0.4, 1.0, 0.5, 1.0);
        }
        let image = render(&mut renderer, &device, &packet);
        if frame == 0 {
            let pixel = (64 * 192 + 80) * 4;
            assert_eq!(image[pixel + 2], 0, "imported zero red factor");
            assert!(image[pixel] > 5);
            assert!(image[pixel + 1] > 5);
        }
        reference.render(&packet).expect("reference frame");
        let expected = reference.readback().expect("reference readback");
        GridImage::write_ppm(
            &image,
            packet.drawable_size,
            &directory.join(format!("frame-{frame}.ppm")),
        )
        .expect("native ppm");
        GridImage::write_ppm(
            &expected,
            packet.drawable_size,
            &directory.join(format!("repeat-{frame}.ppm")),
        )
        .expect("reference ppm");
        let delta = GridImage::difference(&image, &expected).expect("difference");
        assert!(
            delta.mean_absolute_channel_error < 0.5,
            "textured {api:?}: {delta:?}"
        );
        assert!(delta.pixels_over_three < delta.pixel_count / 100);
        assert_eq!(
            renderer
                .current_frame_stats()
                .pass_draw_call_counts
                .get(&diffuse_render::RenderPassKind::BasePass)
                .copied(),
            Some(3)
        );
    }

    // Masked fragments leave both color and depth untouched: opaque coverage
    // must fill the checker holes, independent of instance extraction order.
    packet.scene.instances = vec![RenderInstance::from_mesh_index(
        2,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    )];
    packet.frame_index += 1;
    let holes = render(&mut renderer, &device, &packet);
    packet.scene.instances = Vec::new();
    packet.frame_index += 1;
    let background = render(&mut renderer, &device, &packet);
    let offset = (48 * 192 + 120) * 4;
    assert_eq!(holes[offset..offset + 4], background[offset..offset + 4]);
    assert!(
        GridImage::difference(&holes, &background)
            .expect("difference")
            .pixels_over_three
            > 100
    );

    device.wait_until_idle().expect("idle");
    AssetRegistry::shared().unregister_testing_mesh(2);
}

/// Resource replacement, removal and error recovery keep the renderer usable.
#[test]
fn resource_replacement_and_removal() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let assets: &'static AssetRegistry = Box::leak(Box::new(AssetRegistry::new()));
    let Some(device) = device::make_for(device::validation_api(), false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut renderer =
        NativeRenderer::new(&device, None, assets, None, &RenderSettings::new(), &[])
            .expect("renderer");
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(96, 96), 0);
    let mut asset = BuiltinMesh::cube(Some(Float3::splat(1.0)));
    asset.materials[0].base_color_factor = Float4::new(0.4, 0.7, 0.2, 1.0);
    // Sparse slots are supported; no append-only array assumption.
    assets.register_for_testing(asset.clone(), 45);
    packet.scene.instances = vec![RenderInstance::from_mesh_index(
        45,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    )];
    renderer.render_checked(&packet).expect("first frame");
    assert_eq!(renderer.resident_mesh_count(), 3);
    let first = GridImage::readback(
        &device,
        renderer.color_texture().expect("color"),
        packet.drawable_size,
    )
    .expect("readback");

    for frame in 1..=18 {
        packet.frame_index = frame;
        if frame == 5 {
            asset.materials[0].base_color_factor = Float4::new(0.7, 0.1, 0.4, 1.0);
            assets.register_for_testing(asset.clone(), 45);
        }
        if frame == 10 {
            packet.drawable_size = RenderDrawableSize::new(128, 64);
        }
        renderer.render_checked(&packet).expect("loop frame");
    }
    packet.drawable_size = RenderDrawableSize::new(96, 96);
    renderer
        .render_checked(&packet)
        .expect("restored size frame");
    let replaced = GridImage::readback(
        &device,
        renderer.color_texture().expect("color"),
        packet.drawable_size,
    )
    .expect("readback");
    assert!(
        GridImage::difference(&first, &replaced)
            .expect("difference")
            .pixels_over_three
            > 5
    );

    // A failed catalog transaction keeps old resources and can recover.
    let mut broken = asset.clone();
    broken.indices = vec![u32::MAX, 0, 1];
    assets.register_for_testing(broken, 45);
    assert!(renderer.render_checked(&packet).is_err());
    assets.register_for_testing(asset, 45);
    renderer.render_checked(&packet).expect("recovered frame");
    assets.unregister_testing_mesh(45);
    assert!(renderer.render_checked(&packet).is_err());
    packet.scene.instances = Vec::new();
    renderer.render_checked(&packet).expect("empty frame");
    assert_eq!(renderer.resident_mesh_count(), 2);

    packet.render_settings.shading.pbr = true;
    renderer.render_checked(&packet).expect("pbr frame");
    packet.render_settings.stylization.enabled = true;
    renderer.render_checked(&packet).expect("stylized frame");
    packet.render_settings.stylization.style.outline_width = f32::NAN;
    assert!(renderer.render_checked(&packet).is_err());
    packet.render_settings.stylization.enabled = false;
    packet.render_settings.shading.pbr = false;
    renderer
        .render_checked(&packet)
        .expect("recovered stylized frame");

    device.wait_until_idle().expect("idle");
}
