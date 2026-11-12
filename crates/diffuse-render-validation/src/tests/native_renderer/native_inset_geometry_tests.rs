//! Ported from `Engine/Tests/NativeRendererTests/NativeInsetGeometryTests.swift`.

use std::collections::BTreeSet;
use std::sync::Arc;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::polygon_mesh::GeometryLimits;
use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::registries::mesh_wireframe_registry::MeshWireframeRegistry;
use diffuse_render::{DebugViewMode, RenderDrawableSize, RenderSettings};
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderInstance, RenderMaterial};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::tests::native_renderer::support::{device, lock_serial};

/// A recessed panel renders and cancellation restores pixels and wireframe.
#[test]
fn recessed_panel_renders_and_cancels() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let limits = GeometryLimits::default();
    let root = std::env::temp_dir().join(format!(
        "native-inset-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("temporary root");
    let url = root.join("panel.dmesh");
    let url_text = url.to_str().expect("UTF-8 path").to_string();
    let assets: &'static AssetRegistry = Box::leak(Box::new(AssetRegistry::new()));
    let document = GeometryDocument::with_source(
        "panel",
        GeometrySource::Box {
            size: Float3::splat(2.0),
        },
    );
    document.save(&url_text, limits).expect("save document");
    let root_text = root.to_str().expect("UTF-8 path").to_string();
    let slot = assets
        .load_project_default(&root_text)
        .expect("load project")
        .first()
        .expect("mesh entry")
        .mesh_index;

    let Some(device) = device::make_for(device::platform_api(), true).expect("device") else {
        let _ = std::fs::remove_dir_all(&root);
        return;
    };
    let device = Arc::new(device);
    let mut renderer =
        NativeRenderer::new(&device, None, assets, None, &RenderSettings::new(), &[])
            .expect("renderer");

    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(128, 128), 0);
    packet.render_settings.shading.debug_view_mode = DebugViewMode::WorldNormal;
    packet.scene.camera = RenderCamera::new(Float3::new(3.0, 2.0, 6.0), Float3::ZERO);
    packet.scene.instances = vec![RenderInstance::from_mesh_index(
        slot,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    )];
    renderer.render_checked(&packet).expect("before frame");
    let before = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");

    let mut mesh = document.source.evaluate(limits).expect("evaluate box");
    let faces: BTreeSet<i64> = [1].into_iter().collect();
    mesh.inset(&faces, 0.25, limits).expect("inset");
    mesh.extrude_faces(&faces, Float3::new(0.0, 0.0, -0.5), limits)
        .expect("extrude");
    let materials = document
        .evaluate(limits)
        .expect("evaluate document")
        .mesh
        .materials
        .clone();
    let preview = mesh
        .bake("recess", GeometryShading::Flat, &materials, limits)
        .expect("bake inset mesh");
    assets.register_transient_mesh(
        preview.mesh,
        slot,
        "recess",
        assets
            .load_project_default(&root_text)
            .expect("reload project")
            .first()
            .expect("mesh entry")
            .kind,
        Some(vec![preview.topology_slice]),
        Some(mesh),
    );

    packet.frame_index = 1;
    renderer.render_checked(&packet).expect("inset frame");
    let inset = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");
    assert!(
        GridImage::difference(&before, &inset)
            .expect("difference")
            .pixels_over_three
            > 100
    );
    assert_eq!(
        renderer.current_frame_stats().submitted_mesh_triangle_count,
        28
    );
    assert_eq!(
        MeshWireframeRegistry::edges(slot)
            .map(|edges| edges.len())
            .unwrap_or_default(),
        28
    );

    assets.unregister_transient_mesh(slot);
    packet.frame_index = 2;
    renderer.render_checked(&packet).expect("cancel frame");
    assert_eq!(
        MeshWireframeRegistry::edges(slot)
            .map(|edges| edges.len())
            .unwrap_or_default(),
        12
    );
    let cancelled = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");
    assert_eq!(before, cancelled);

    device.wait_until_idle().expect("idle");
    let _ = std::fs::remove_dir_all(&root);
}
