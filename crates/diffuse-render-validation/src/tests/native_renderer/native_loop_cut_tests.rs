//! Ported from `Engine/Tests/NativeRendererTests/NativeLoopCutTests.swift`.

use std::sync::Arc;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::polygon_mesh::{GeometryLimits, PolygonMeshEdge};
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::registries::mesh_wireframe_registry::MeshWireframeRegistry;
use diffuse_render::{RenderDrawableSize, RenderSettings};
use diffuse_scene::rendering::render_geometry_overlay::{
    RenderGeometryOverlay, RenderGeometryTriangle,
};
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderInstance, RenderMaterial};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::tests::native_renderer::support::device;

/// A transient loop cut renders selectable surface wires and cancel restores it.
#[test]
fn transient_loop_cut_renders_wires_and_cancel_restores() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = crate::tests::native_renderer::support::lock_serial();
    let limits = GeometryLimits::default();
    let root = std::env::temp_dir().join(format!(
        "loop-cut-gpu-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("temporary root");
    let url = root.join("cube.dmesh");
    let url_text = url.to_str().expect("UTF-8 path").to_string();
    let source = GeometryDocument::with_source(
        "cube",
        GeometrySource::Box {
            size: Float3::splat(2.0),
        },
    );
    source.save(&url_text, limits).expect("save document");
    let assets: &'static AssetRegistry = Box::leak(Box::new(AssetRegistry::new()));
    let root_text = root.to_str().expect("UTF-8 path").to_string();
    let entry = assets
        .load_project_default(&root_text)
        .expect("load project")
        .first()
        .cloned()
        .expect("mesh entry");

    let Some(device) = device::make_for(device::platform_api(), true).expect("device") else {
        let _ = std::fs::remove_dir_all(&root);
        return;
    };
    let device = Arc::new(device);
    let mut renderer =
        NativeRenderer::new(&device, None, assets, None, &RenderSettings::new(), &[])
            .expect("renderer");

    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(128, 128), 0);
    packet.scene.camera = RenderCamera::new(Float3::new(3.0, 2.0, 6.0), Float3::ZERO);
    packet.scene.instances = vec![RenderInstance::from_mesh_index(
        entry.mesh_index,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    )];
    renderer.render_checked(&packet).expect("original frame");
    let original = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");

    let mut mesh = source.source.evaluate(limits).expect("evaluate cube");
    let cuts = mesh
        .loop_cut(PolygonMeshEdge::new(0, 1), 2, 0.3, limits)
        .expect("loop cut");
    let materials = source
        .evaluate(limits)
        .expect("evaluate document")
        .mesh
        .materials
        .clone();
    let baked = mesh
        .bake("cut", GeometryShading::Flat, &materials, limits)
        .expect("bake cut mesh");
    assets.register_transient_mesh(
        baked.mesh,
        entry.mesh_index,
        &entry.id,
        entry.kind,
        Some(vec![baked.topology_slice]),
        Some(mesh.clone()),
    );

    let mut overlay = RenderGeometryOverlay::new(Float2::new(128.0, 128.0));
    let color = Float4::new(1.0, 0.58, 0.12, 1.0);
    let slice = mesh.topology_slice().expect("topology slice");
    for triangle in slice.triangle_indices.as_chunks::<3>().0 {
        let v = [
            triangle[0] as usize,
            triangle[1] as usize,
            triangle[2] as usize,
        ];
        let edges = [
            PolygonMeshEdge::new(v[1] as i64, v[2] as i64),
            PolygonMeshEdge::new(v[2] as i64, v[0] as i64),
            PolygonMeshEdge::new(v[0] as i64, v[1] as i64),
        ];
        overlay.triangles.push(RenderGeometryTriangle {
            a: mesh.positions[v[0]],
            b: mesh.positions[v[1]],
            c: mesh.positions[v[2]],
            color: Float4::ZERO,
            edge_widths: Float3::new(
                if cuts.contains(&edges[0]) { 2.0 } else { 0.0 },
                if cuts.contains(&edges[1]) { 2.0 } else { 0.0 },
                if cuts.contains(&edges[2]) { 2.0 } else { 0.0 },
            ),
            edge_a: color,
            edge_b: color,
            edge_c: color,
        });
    }
    packet.scene.geometry_overlays = vec![overlay];
    packet.frame_index += 1;
    renderer.render_checked(&packet).expect("preview frame");
    let preview = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");
    assert_eq!(
        renderer.current_frame_stats().submitted_mesh_triangle_count,
        28
    );
    assert_eq!(
        MeshWireframeRegistry::edges(entry.mesh_index)
            .map(|edges| edges.len())
            .unwrap_or_default(),
        28
    );
    assert!(
        GridImage::difference(&original, &preview)
            .expect("difference")
            .pixels_over_three
            > 70
    );

    assets.unregister_transient_mesh(entry.mesh_index);
    packet.scene.geometry_overlays.clear();
    packet.frame_index += 1;
    renderer.render_checked(&packet).expect("cancel frame");
    assert_eq!(
        renderer.current_frame_stats().submitted_mesh_triangle_count,
        12
    );
    let cancelled = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");
    assert_eq!(original, cancelled);

    device.wait_until_idle().expect("idle");
    let _ = std::fs::remove_dir_all(&root);
}
