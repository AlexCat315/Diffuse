//! Ported from `Engine/Tests/NativeRendererTests/NativeEmptyGeometryTests.swift`.

use std::collections::BTreeSet;
use std::sync::Arc;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::polygon_mesh::GeometryLimits;
use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::registries::mesh_picking_registry::MeshPickingRegistry;
use diffuse_render::registries::mesh_wireframe_registry::MeshWireframeRegistry;
use diffuse_render::{RenderDrawableSize, RenderSettings};
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderInstance, RenderMaterial};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::tests::native_renderer::support::device;

fn instance(mesh_index: i64) -> RenderInstance {
    RenderInstance::from_mesh_index(
        mesh_index,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    )
}

/// Deleting every face clears pixels and restoring the asset restores the image.
#[test]
fn deleting_every_face_clears_pixels_and_restoring_restores_image() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = crate::tests::native_renderer::support::lock_serial();
    let limits = GeometryLimits::default();
    let root = std::env::temp_dir().join(format!(
        "native-empty-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("temporary root");
    let url = root.join("surface.dmesh");
    let url_text = url.to_str().expect("UTF-8 path").to_string();
    let assets: &'static AssetRegistry = Box::leak(Box::new(AssetRegistry::new()));
    let original = GeometryDocument::with_source(
        "surface",
        GeometrySource::Box {
            size: Float3::splat(2.0),
        },
    );
    original.save(&url_text, limits).expect("save document");
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
    packet.scene.camera = RenderCamera::new(Float3::new(0.0, 0.0, 6.0), Float3::ZERO);
    packet.scene.instances = Vec::new();
    renderer.render_checked(&packet).expect("background frame");
    let background = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");

    packet.scene.instances = vec![instance(slot)];
    packet.frame_index = 1;
    renderer.render_checked(&packet).expect("filled frame");
    let filled = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");
    assert!(
        GridImage::difference(&background, &filled)
            .expect("difference")
            .pixels_over_three
            > 100
    );

    let mut mesh = original.source.evaluate(limits).expect("evaluate box");
    let faces: BTreeSet<i64> = (0..mesh.faces.len() as i64).collect();
    mesh.delete(&BTreeSet::new(), &BTreeSet::new(), &faces, limits)
        .expect("delete every face");
    let mut empty = original.clone();
    empty.source = GeometrySource::Polygon { mesh };
    empty.save(&url_text, limits).expect("save empty document");
    assert_eq!(
        assets
            .load_project_default(&root_text)
            .expect("reload project")
            .first()
            .expect("mesh entry")
            .mesh_index,
        slot
    );

    packet.frame_index = 2;
    renderer.render_checked(&packet).expect("empty frame");
    let cleared = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");
    assert_eq!(cleared, background);
    assert_eq!(
        renderer.current_frame_stats().submitted_mesh_triangle_count,
        0
    );
    assert_eq!(
        MeshWireframeRegistry::edges(slot)
            .map(|edges| edges.len())
            .unwrap_or_default(),
        0
    );
    assert!(
        MeshPickingRegistry::surface(slot, &[])
            .and_then(|surface| {
                surface.hit_distance(
                    Float3::new(0.0, 0.0, 6.0),
                    Float3::new(0.0, 0.0, -1.0),
                    f32::MAX,
                )
            })
            .is_none()
    );

    original.save(&url_text, limits).expect("restore document");
    assert_eq!(
        assets
            .load_project_default(&root_text)
            .expect("reload project")
            .first()
            .expect("mesh entry")
            .mesh_index,
        slot
    );
    packet.frame_index = 3;
    renderer.render_checked(&packet).expect("restored frame");
    let restored = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");
    assert_eq!(restored, filled);
    assert_eq!(
        renderer.current_frame_stats().submitted_mesh_triangle_count,
        12
    );

    device.wait_until_idle().expect("idle");
    let _ = std::fs::remove_dir_all(&root);
}
