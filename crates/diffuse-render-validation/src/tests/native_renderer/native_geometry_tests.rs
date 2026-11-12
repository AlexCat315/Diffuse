//! Ported from `Engine/Tests/NativeRendererTests/NativeGeometryTests.swift`.

use std::collections::BTreeSet;
use std::sync::Arc;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_document::{
    GeometryDocument, GeometryMaterial, GeometrySource,
};
use diffuse_assets::geometry::geometry_modifier::{GeometryModifier, GeometryModifierEntry};
use diffuse_assets::geometry::polygon_mesh::GeometryLimits;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::registries::mesh_bounds_registry::MeshBoundsRegistry;
use diffuse_render::registries::mesh_wireframe_registry::MeshWireframeRegistry;
use diffuse_render::{RenderDrawableSize, RenderSettings};
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderInstance, RenderMaterial};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::tests::native_renderer::support::{device, lock_serial};

fn instance(mesh_index: i64) -> RenderInstance {
    RenderInstance::from_mesh_index(
        mesh_index,
        MATRIX_IDENTITY_FLOAT4X4,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    )
}

/// Interactive preview and cancellation change and restore pixels.
#[test]
fn interactive_preview_and_cancellation_restore_pixels() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let limits = GeometryLimits::default();
    let assets: &'static AssetRegistry = Box::leak(Box::new(AssetRegistry::new()));
    let root = std::env::temp_dir().join(format!(
        "native-preview-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("temporary root");
    let document = GeometryDocument::with_source(
        "original",
        GeometrySource::Box {
            size: Float3::splat(2.0),
        },
    );
    let original = document.evaluate(limits).expect("evaluate document");
    let url = root.join("cube.dmesh");
    let url_text = url.to_str().expect("UTF-8 path").to_string();
    document.save(&url_text, limits).expect("save document");
    let root_text = root.to_str().expect("UTF-8 path").to_string();
    let entry = assets
        .load_project_default(&root_text)
        .expect("load project")
        .first()
        .cloned()
        .expect("mesh entry");
    let slot = entry.mesh_index;

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
    packet.scene.instances = vec![instance(slot)];
    renderer.render_checked(&packet).expect("before frame");
    let before = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");

    let mut mesh = original.control_mesh;
    let vertices: BTreeSet<i64> = (0..mesh.positions.len() as i64).collect();
    let mut delta = MATRIX_IDENTITY_FLOAT4X4;
    delta.columns[3].x = 0.8;
    mesh.transform(&vertices, delta, limits).expect("translate");
    let materials = document
        .evaluate(limits)
        .expect("evaluate document")
        .mesh
        .materials
        .clone();
    let preview = mesh
        .bake("preview", GeometryShading::Flat, &materials, limits)
        .expect("bake preview");
    assets.register_transient_mesh(
        preview.mesh,
        slot,
        "preview",
        entry.kind,
        Some(vec![preview.topology_slice]),
        Some(preview.control_mesh),
    );

    packet.frame_index = 1;
    renderer.render_checked(&packet).expect("preview frame");
    let moved = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");
    assert!(
        GridImage::difference(&before, &moved)
            .expect("difference")
            .pixels_over_three
            > 100
    );

    assets.unregister_transient_mesh(slot);
    packet.frame_index = 2;
    renderer.render_checked(&packet).expect("cancel frame");
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

/// Native geometry loads, renders and replaces a resident mesh.
#[test]
fn native_geometry_loads_renders_and_replaces_mesh() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let limits = GeometryLimits::default();
    let root = std::env::temp_dir().join(format!(
        "native-geometry-{}",
        diffuse_kernel::codable::new_uuid()
    ));
    std::fs::create_dir_all(&root).expect("temporary root");
    let url = root.join("rounded.dmesh");
    let url_text = url.to_str().expect("UTF-8 path").to_string();
    let mut document = GeometryDocument::new(
        "Rounded",
        GeometrySource::Box {
            size: Float3::splat(2.0),
        },
        vec![GeometryModifierEntry::with_operation(
            GeometryModifier::Subdivision { levels: 2 },
        )],
        GeometryShading::Smooth,
        vec![GeometryMaterial {
            name: "Material".to_string(),
            base_color: Float4::new(0.1, 0.6, 0.9, 1.0),
            metallic: 0.0,
            roughness: 0.5,
        }],
    );
    document.save(&url_text, limits).expect("save document");
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
    packet.scene.camera = RenderCamera::new(Float3::new(3.0, 2.0, 5.0), Float3::ZERO);
    packet.scene.instances = Vec::new();
    renderer.render_checked(&packet).expect("empty frame");
    let empty = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");

    packet.frame_index = 1;
    packet.scene.instances = vec![instance(entry.mesh_index)];
    renderer.render_checked(&packet).expect("rounded frame");
    let rounded = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");
    assert_eq!(
        renderer.current_frame_stats().submitted_mesh_triangle_count,
        192
    );
    assert_eq!(
        MeshWireframeRegistry::edges(entry.mesh_index)
            .map(|edges| edges.len())
            .unwrap_or_default(),
        192
    );
    assert_eq!(
        assets
            .polygon_mesh(entry.mesh_index)
            .expect("polygon mesh")
            .faces
            .len(),
        96
    );
    assert!(MeshBoundsRegistry::bounds(entry.mesh_index).is_some());
    assert!(
        GridImage::difference(&empty, &rounded)
            .expect("difference")
            .pixels_over_three
            > 100
    );

    document.modifiers.clear();
    document.save(&url_text, limits).expect("save box document");
    assert_eq!(
        assets
            .load_project_default(&root_text)
            .expect("reload project")
            .first()
            .expect("mesh entry")
            .mesh_index,
        entry.mesh_index
    );
    packet.frame_index = 2;
    renderer.render_checked(&packet).expect("box frame");
    let boxed = GridImage::readback(
        &device,
        renderer.color_texture().expect("color texture"),
        packet.drawable_size,
    )
    .expect("readback");
    assert_eq!(
        renderer.current_frame_stats().submitted_mesh_triangle_count,
        12
    );
    assert_eq!(
        MeshWireframeRegistry::edges(entry.mesh_index)
            .map(|edges| edges.len())
            .unwrap_or_default(),
        12
    );
    assert!(
        GridImage::difference(&rounded, &boxed)
            .expect("difference")
            .pixels_over_three
            > 100
    );

    std::fs::remove_file(&url).expect("remove document");
    let _ = assets.load_project_default(&root_text);
    packet.frame_index = 3;
    packet.scene.instances = Vec::new();
    renderer.render_checked(&packet).expect("removed frame");
    assert!(MeshWireframeRegistry::edges(entry.mesh_index).is_none());
    assert!(MeshBoundsRegistry::bounds(entry.mesh_index).is_none());
    assert!(MeshWireframeRegistry::edges(0).is_some());

    device.wait_until_idle().expect("idle");
    let _ = std::fs::remove_dir_all(&root);
}
