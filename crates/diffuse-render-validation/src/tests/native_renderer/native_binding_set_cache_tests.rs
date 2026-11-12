//! Ported from `Engine/Tests/NativeRendererTests/NativeBindingSetCacheTests.swift`.
//!
//! Regression test for the per-frame BindingSet cache miss that used to occur
//! because the cache descriptor baked the upload ring's per-frame offset. The
//! mesh pass now binds ring-backed blocks at offset 0 and passes the per-frame
//! offset as a dynamic offset, so the descriptor (and hence the cached
//! BindingSet) is stable once the per-frame-slot set exists. After the initial
//! warmup, changing the number of visible instances must not create any new
//! BindingSets.

use std::sync::Arc;

use diffuse_assets::asset_pipeline::BuiltinMesh;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::{RenderDrawableSize, RenderSettings};
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderInstance, RenderMaterial};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::tests::native_renderer::support::device;

/// Varying instance counts reuse the warmup BindingSet for every slot.
#[test]
fn varying_instance_count_reuses_binding_sets() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = crate::tests::native_renderer::support::lock_serial();
    let frames_in_flight = 3;
    let cube = BuiltinMesh::cube(Some(Float3::splat(1.0)));
    AssetRegistry::shared().register_for_testing(cube, 77);
    let Some(device) = device::make_for(device::validation_api(), false).expect("device") else {
        AssetRegistry::shared().unregister_testing_mesh(77);
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
    let size = RenderDrawableSize::new(96, 96);

    let render = |renderer: &mut NativeRenderer, count: usize, frame: i64| {
        let mut packet = MeshProbeScene::packet(size, frame);
        packet.render_settings.shading.pbr = false;
        packet.render_settings.shading.depth_prepass = false;
        // Isolate every instance so the number of draws moves 1:1 with the
        // visible instance count, exercising the worst-case churn path.
        packet.render_settings.visibility.mesh_instancing = false;
        packet.scene.camera = RenderCamera::with_parameters(
            Float3::new(0.0, 0.0, 40.0),
            Float3::ZERO,
            Float3::new(0.0, 1.0, 0.0),
            core::f32::consts::FRAC_PI_4,
            1.0,
            0.1,
            100.0,
            diffuse_scene::rendering::render_scene::RenderCameraProjection::Perspective,
            10.0,
        );
        packet.scene.instances = (0..count)
            .map(|index| {
                let mut transform = MATRIX_IDENTITY_FLOAT4X4;
                transform.columns[3] =
                    Float4::new(index as f32 * 1.5 - count as f32 * 0.75, 0.0, 0.0, 1.0);
                RenderInstance::from_mesh_index(
                    77,
                    transform,
                    Float3::splat(1.0),
                    RenderMaterial::fallback(),
                    None,
                )
            })
            .collect();
        renderer.render_checked(&packet).expect("render");
    };

    // Warmup: one frame per in-flight frame slot.
    for frame in 0..frames_in_flight {
        render(&mut renderer, 10 + frame * 3, frame as i64);
    }
    let misses_after_warmup = device.binding_set_cache_stats().misses;

    // Vary the visible instance count across frame slots; every draw must
    // reuse the warmup set for its slot.
    let post_warmup_counts = [10, 19, 13, 16, 10, 19];
    for (index, count) in post_warmup_counts.iter().enumerate() {
        let frame = (frames_in_flight + index) as i64;
        render(&mut renderer, *count, frame);
        assert_eq!(
            device.binding_set_cache_stats().misses,
            misses_after_warmup,
            "frame {index} created a new BindingSet despite stable descriptors"
        );
    }

    // Measure the hit delta for two frames with different counts. Each frame
    // performs one BindingSet lookup per mesh batch plus a fixed number for the
    // other passes, so the difference between the two deltas must equal the
    // difference in instance count — and every one must be a hit.
    let frame_for_a = (frames_in_flight + post_warmup_counts.len()) as i64;
    let stats_before_a = device.binding_set_cache_stats();
    render(&mut renderer, 12, frame_for_a);
    let stats_after_a = device.binding_set_cache_stats();
    render(&mut renderer, 18, frame_for_a + 1);
    let stats_after_b = device.binding_set_cache_stats();

    assert_eq!(stats_after_a.misses, stats_before_a.misses);
    assert_eq!(stats_after_b.misses, stats_after_a.misses);
    let delta_a = stats_after_a.hits - stats_before_a.hits;
    let delta_b = stats_after_b.hits - stats_after_a.hits;
    assert_eq!(delta_b - delta_a, 18 - 12);

    device.wait_until_idle().expect("idle");
    AssetRegistry::shared().unregister_testing_mesh(77);
}
