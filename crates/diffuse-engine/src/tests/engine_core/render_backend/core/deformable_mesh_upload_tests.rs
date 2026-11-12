//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/Core/DeformableMeshUploadTests.swift`.
//!
//! The GPU upload test is gated by `COVE_RUN_GPU_SMOKE_TESTS=1`, matching the
//! Swift suite's `.enabled(if:)` condition.

use std::sync::Arc;

use cove_graphics::rhi::{Device, DeviceConfig};
use diffuse_assets::asset_pipeline::MeshAsset;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_math::simd::simd_compat::{Float2, Float3, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::frame::render_packet::{RenderDrawableSize, RenderPacket};
use diffuse_render::core::mesh::deformable_mesh_vertex_stream::DeformableMeshVertexStream;
use diffuse_render::core::render_settings::RenderSettings;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderDeformableMesh, RenderEnvironment, RenderInstance, RenderScene,
};
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

fn make_quad(entity: EntityID, revision: u64) -> RenderDeformableMesh {
    RenderDeformableMesh::with_geometry(
        entity,
        revision,
        None,
        vec![
            Float3::new(-1.0, -1.0, 0.0),
            Float3::new(1.0, -1.0, 0.0),
            Float3::new(1.0, 1.0, 0.0),
            Float3::new(-1.0, 1.0, 0.0),
        ],
        vec![0, 1, 2, 0, 2, 3],
        vec![
            Float2::new(0.0, 0.0),
            Float2::new(1.0, 0.0),
            Float2::new(1.0, 1.0),
            Float2::new(0.0, 1.0),
        ],
        None,
    )
}

fn scene(mesh: RenderDeformableMesh, entity: EntityID) -> RenderScene {
    RenderScene::new(
        RenderCamera {
            eye: Float3::new(0.0, 0.0, 4.0),
            ..RenderCamera::default()
        },
        vec![RenderInstance::from_mesh_index(
            0,
            MATRIX_IDENTITY_FLOAT4X4,
            Float3::splat(1.0),
            diffuse_scene::rendering::render_scene::RenderMaterial::fallback(),
            Some(entity),
        )],
        Vec::new(),
        RenderEnvironment::fallback(),
        vec![mesh],
        Vec::new(),
        Vec::new(),
        None,
    )
}

fn packet(entity: EntityID, mesh: RenderDeformableMesh, frame: u64) -> RenderPacket {
    let mut settings = RenderSettings::new();
    settings.shading.pbr = false;
    settings.shading.depth_prepass = true;
    settings.viewport.offscreen = true;
    RenderPacket::new(
        frame as i64,
        1.0 / 60.0,
        RenderDrawableSize::new(64, 64),
        scene(mesh, entity),
        SceneRuntimeSnapshot::new(1, frame),
        settings,
        frame as f64 / 60.0,
        JointPaletteMap::default(),
        InGameCanvas::new(),
    )
}

/// Packs deformable positions, normals, UVs and indices into the mesh vertex
/// contract.
#[test]
fn builds_interleaved_vertex_stream() {
    let entity = EntityID::new(4, 2);
    let mesh = make_quad(entity, 7);
    let stream = DeformableMeshVertexStream::from_mesh(&mesh).expect("vertex stream");

    assert_eq!(stream.vertices.len(), 4 * MeshAsset::VERTEX_FLOAT_COUNT);
    assert_eq!(stream.indices, vec![0, 1, 2, 0, 2, 3]);
    assert_eq!(
        stream.vertex_buffer_size(),
        4 * MeshAsset::VERTEX_STRIDE as u64
    );
    assert_eq!(stream.index_buffer_size(), 6 * 4);
    assert_eq!(stream.vertices[MeshAsset::POSITION_FLOAT_OFFSET], -1.0);
    assert_eq!(stream.vertices[MeshAsset::NORMAL_FLOAT_OFFSET + 2], 1.0);
    assert_eq!(stream.vertices[MeshAsset::UV_FLOAT_OFFSET], 0.0);
    assert_eq!(
        stream.vertices[2 * MeshAsset::VERTEX_FLOAT_COUNT + MeshAsset::UV_FLOAT_OFFSET],
        1.0
    );

    let mut invalid = mesh;
    invalid.triangle_indices[5] = 99;
    assert!(!invalid.is_valid());
    assert!(DeformableMeshVertexStream::from_mesh(&invalid).is_none());
}

/// Uploads deformable GPU buffers once per content revision.
#[test]
fn uploads_once_per_revision() {
    if std::env::var("COVE_RUN_GPU_SMOKE_TESTS").as_deref() != Ok("1") {
        return;
    }
    let device = Arc::new(Device::make(DeviceConfig::default()).expect("device"));
    let assets: &'static AssetRegistry = Box::leak(Box::new(AssetRegistry::new()));
    let mut renderer =
        NativeRenderer::new(&device, None, assets, None, &RenderSettings::new(), &[])
            .expect("renderer");

    let entity = EntityID::new(1, 0);
    let mut mesh = make_quad(entity, 1);
    renderer
        .render_checked(&packet(entity, mesh.clone(), 0))
        .expect("first frame");
    let mut stats = renderer.current_frame_stats();
    assert_eq!(stats.deformable_mesh_count, 1);
    assert_eq!(stats.deformable_vertex_count, 4);
    assert_eq!(stats.deformable_triangle_count, 2);
    assert_eq!(stats.deformable_rejected_mesh_count, 0);
    assert_eq!(stats.deformable_uploaded_bytes, 408);

    renderer
        .render_checked(&packet(entity, mesh.clone(), 1))
        .expect("second frame");
    stats = renderer.current_frame_stats();
    assert_eq!(stats.deformable_uploaded_bytes, 0);

    mesh.revision = 2;
    mesh.positions[0].y = -0.5;
    mesh.normals = RenderDeformableMesh::smooth_normals(&mesh.positions, &mesh.triangle_indices);
    renderer
        .render_checked(&packet(entity, mesh, 2))
        .expect("third frame");
    stats = renderer.current_frame_stats();
    assert_eq!(
        stats.deformable_uploaded_bytes,
        4 * MeshAsset::VERTEX_STRIDE as u64
    );
}
