//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/Core/MeshSurfaceAndVisibilityTests.swift`.

use std::collections::BTreeSet;

use diffuse_assets::asset_pipeline::{MeshAsset, MeshMaterial};
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::frame::render_camera_matrices::RenderCameraMatrices;
use diffuse_render::core::frame::render_packet::RenderDrawableSize;
use diffuse_render::core::mesh::mesh_visibility_plan::MeshVisibilityPlan;
use diffuse_render::core::render_settings::RenderSettings;
use diffuse_render::registries::mesh_bounds_registry::MeshBoundsRegistry;
use diffuse_render::registries::mesh_picking_registry::{MeshPickingRegistry, MeshPickingSurface};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderCameraProjection, RenderEnvironment, RenderInstance, RenderMeshHandle,
    RenderMeshLOD, RenderScene,
};

fn camera(eye: Float3) -> RenderCamera {
    RenderCamera {
        eye,
        target: Float3::ZERO,
        ..RenderCamera::default()
    }
}

fn scene(camera: RenderCamera, instances: Vec<RenderInstance>) -> RenderScene {
    RenderScene::new(
        camera,
        instances,
        Vec::new(),
        RenderEnvironment::fallback(),
        Vec::new(),
        Vec::new(),
        Vec::new(),
        None,
    )
}

/// Triangle surfaces reject empty AABB corners and return nearest hits from
/// either side.
#[test]
fn precise_surface() {
    let surface = MeshPickingSurface::new(
        &[
            Float3::new(0.0, 0.0, 0.0),
            Float3::new(2.0, 0.0, 0.0),
            Float3::new(0.0, 2.0, 0.0),
            Float3::new(0.0, 0.0, -2.0),
            Float3::new(2.0, 0.0, -2.0),
            Float3::new(0.0, 2.0, -2.0),
        ],
        &[0, 1, 2, 3, 4, 5],
    );
    assert_eq!(
        surface.hit_distance(
            Float3::new(1.8, 1.8, 3.0),
            Float3::new(0.0, 0.0, -1.0),
            f32::MAX
        ),
        None
    );
    assert_eq!(
        surface.hit_distance(
            Float3::new(0.3, 0.3, 3.0),
            Float3::new(0.0, 0.0, -1.0),
            f32::MAX
        ),
        Some(3.0)
    );
    assert_eq!(
        surface.hit_distance(
            Float3::new(0.3, 0.3, -3.0),
            Float3::new(0.0, 0.0, 1.0),
            f32::MAX
        ),
        Some(1.0)
    );
    assert_eq!(
        surface.hit_distance(
            Float3::new(0.3, 0.3, 3.0),
            Float3::new(0.0, 0.0, -0.5),
            f32::MAX
        ),
        Some(6.0)
    );
    assert_eq!(
        surface.hit_distance(Float3::new(0.3, 0.3, 3.0), Float3::new(0.0, 0.0, -1.0), 2.0),
        None
    );
    let invalid = MeshPickingSurface::new(&[Float3::ZERO], &[0, 1, 2, 0, 0, 0]);
    assert_eq!(
        invalid.hit_distance(
            Float3::new(0.0, 0.0, 1.0),
            Float3::new(0.0, 0.0, -1.0),
            f32::MAX
        ),
        None
    );
}

/// Surface picking follows the current joint pose rather than the bind pose.
#[test]
fn posed_surface() {
    let mut vertices: Vec<f32> = Vec::new();
    for position in [
        Float3::new(0.0, 0.0, 0.0),
        Float3::new(1.0, 0.0, 0.0),
        Float3::new(0.0, 1.0, 0.0),
    ] {
        MeshAsset::append_vertex(
            &mut vertices,
            position,
            Float3::ZERO,
            Float3::splat(1.0),
            Float2::ZERO,
            Float4::new(1.0, 0.0, 0.0, 1.0),
            0.0,
            Float4::ZERO,
            Float4::new(1.0, 0.0, 0.0, 0.0),
        );
    }
    let slot = 401_002;
    let mut mesh = MeshAsset::new("posed", vertices, vec![0, 1, 2]);
    mesh.materials = vec![MeshMaterial::fallback()];
    MeshPickingRegistry::register(slot, &mesh);
    let mut joint = MATRIX_IDENTITY_FLOAT4X4;
    joint.columns[3].x = 3.0;
    let posed = MeshPickingRegistry::surface(slot, &[joint]).expect("posed surface");
    assert_eq!(
        posed.hit_distance(
            Float3::new(0.2, 0.2, 4.0),
            Float3::new(0.0, 0.0, -1.0),
            f32::MAX
        ),
        None
    );
    assert_eq!(
        posed.hit_distance(
            Float3::new(3.2, 0.2, 4.0),
            Float3::new(0.0, 0.0, -1.0),
            f32::MAX
        ),
        Some(4.0)
    );
    let material = MeshMaterial::new(
        None,
        Float4::new(1.0, 1.0, 1.0, 1.0),
        None,
        None,
        None,
        0.0,
        1.0,
        diffuse_scene::rendering::render_scene::MaterialAlphaMode::Opaque,
        2.0,
        false,
    );
    assert_eq!(material.alpha_cutoff, 2.0);
    MeshPickingRegistry::remove(slot);
}

/// BVH traverses both branches and rays parallel to a bound.
#[test]
fn bvh_traversal() {
    let mut positions: Vec<Float3> = Vec::new();
    let mut indices: Vec<u32> = Vec::new();
    for i in 0..40 {
        let x = i as f32 * 3.0;
        let first = positions.len() as u32;
        positions.extend([
            Float3::new(x, 0.0, 0.0),
            Float3::new(x + 1.0, 0.0, 0.0),
            Float3::new(x, 1.0, 0.0),
        ]);
        indices.extend([first, first + 1, first + 2]);
    }
    let surface = MeshPickingSurface::new(&positions, &indices);
    for i in [0, 10, 20, 39] {
        assert_eq!(
            surface.hit_distance(
                Float3::new(i as f32 * 3.0 + 0.1, 0.1, 4.0),
                Float3::new(0.0, 0.0, -1.0),
                f32::MAX
            ),
            Some(4.0)
        );
    }
}

/// Perspective and orthographic frusta cull outside bounds, retaining unknown
/// and skinned geometry.
#[test]
fn visibility() {
    for projection in [
        RenderCameraProjection::Perspective,
        RenderCameraProjection::Orthographic,
    ] {
        let slot = 401_001;
        MeshBoundsRegistry::register(
            slot,
            diffuse_math::bounds::bounds_3d::Bounds3D::new(Float3::splat(-0.5), Float3::splat(0.5)),
        );
        let camera = RenderCamera {
            eye: Float3::new(0.0, 0.0, 5.0),
            target: Float3::ZERO,
            projection,
            orthographic_height: 5.0,
            ..RenderCamera::default()
        };
        let instance = |x: f32, z: f32, entity: Option<EntityID>, mesh_index: Option<i64>| {
            let mut matrix = MATRIX_IDENTITY_FLOAT4X4;
            matrix.columns[3] = Float4::new(x, 0.0, z, 1.0);
            RenderInstance::from_mesh_index(
                mesh_index.unwrap_or(slot),
                matrix,
                Float3::splat(1.0),
                diffuse_scene::rendering::render_scene::RenderMaterial::fallback(),
                entity,
            )
        };
        let skinned = EntityID::new(99, 0);
        let scene = scene(
            camera,
            vec![
                instance(0.0, 0.0, None, None),
                instance(100.0, 0.0, None, None),
                instance(0.0, 10.0, None, None),
                instance(100.0, 0.0, Some(skinned), None),
                instance(100.0, 0.0, None, Some(slot + 1)),
            ],
        );
        let vp =
            RenderCameraMatrices::make(&scene, RenderDrawableSize::new(128, 128)).view_projection;
        let plan = MeshVisibilityPlan::make(
            &scene,
            vp,
            &RenderSettings::new(),
            &BTreeSet::from([skinned]),
            &|mesh_index| MeshBoundsRegistry::bounds(mesh_index),
            &|_| true,
        );
        assert_eq!(plan.visible_indices, vec![0, 3, 4]);
        assert_eq!(plan.culled_count, 2);

        let mut settings = RenderSettings::new();
        settings.visibility.frustum_culling = false;
        let unculled = MeshVisibilityPlan::make(
            &scene,
            vp,
            &settings,
            &BTreeSet::new(),
            &|mesh_index| MeshBoundsRegistry::bounds(mesh_index),
            &|_| true,
        );
        assert_eq!(unculled.visible_indices.len(), 5);
        MeshBoundsRegistry::remove(slot);
    }
}

/// Distance LOD selects available authored levels and respects the disabled
/// switch.
#[test]
fn distance_lod() {
    let camera = camera(Float3::new(0.0, 0.0, 10.0));
    let instance = RenderInstance::new(
        RenderMeshHandle::new(
            100,
            None,
            vec![RenderMeshLOD::new(102, 20.0), RenderMeshLOD::new(101, 5.0)],
        ),
        MATRIX_IDENTITY_FLOAT4X4,
    );
    let scene = scene(camera, vec![instance]);
    let vp = RenderCameraMatrices::make(&scene, RenderDrawableSize::new(128, 128)).view_projection;
    let plan = MeshVisibilityPlan::make(
        &scene,
        vp,
        &RenderSettings::new(),
        &BTreeSet::new(),
        &|_| None,
        &|mesh_index| mesh_index == 101,
    );
    assert_eq!(plan.mesh_indices.get(&0), Some(&101));
    assert_eq!(plan.lod_count, 1);
    let missing = MeshVisibilityPlan::make(
        &scene,
        vp,
        &RenderSettings::new(),
        &BTreeSet::new(),
        &|_| None,
        &|_| false,
    );
    assert_eq!(missing.mesh_indices.get(&0), Some(&100));
    let mut settings = RenderSettings::new();
    settings.visibility.distance_lod = false;
    let disabled =
        MeshVisibilityPlan::make(&scene, vp, &settings, &BTreeSet::new(), &|_| None, &|_| {
            true
        });
    assert_eq!(disabled.mesh_indices.get(&0), Some(&100));
}
