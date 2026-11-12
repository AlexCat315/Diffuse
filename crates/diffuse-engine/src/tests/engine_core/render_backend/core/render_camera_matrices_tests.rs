//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/Core/RenderCameraMatricesTests.swift`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::frame::render_camera_matrices::RenderCameraMatrices;
use diffuse_render::core::frame::render_packet::RenderDrawableSize;
use diffuse_render::core::lighting::grid_plane::EditorGridPlane;
use diffuse_render::core::lighting::shadow_atlas_planner::ShadowAtlasPlanner;
use diffuse_render::core::render_settings::RenderShadowSettings;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::{JointPalette, JointPaletteMap};
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderCameraProjection, RenderEnvironment, RenderInstance, RenderLight,
    RenderLightType, RenderScene,
};

fn camera(eye: Float3) -> RenderCamera {
    RenderCamera {
        eye,
        target: Float3::ZERO,
        near: 0.1,
        far: 30.0,
        projection: RenderCameraProjection::Perspective,
        orthographic_height: 6.0,
        ..RenderCamera::default()
    }
}

fn scene(
    camera: RenderCamera,
    instances: Vec<RenderInstance>,
    lights: Vec<RenderLight>,
) -> RenderScene {
    RenderScene::new(
        camera,
        instances,
        lights,
        RenderEnvironment::fallback(),
        Vec::new(),
        Vec::new(),
        Vec::new(),
        None,
    )
}

/// Shadow fitting encloses joint-transformed bounds beyond the bind pose.
#[test]
fn posed_shadow_bounds() {
    let entity = EntityID::new(12, 0);
    let scene = scene(
        camera(Float3::new(0.0, 0.0, 8.0)),
        vec![RenderInstance::from_mesh_index(
            0,
            MATRIX_IDENTITY_FLOAT4X4,
            Float3::splat(1.0),
            diffuse_scene::rendering::render_scene::RenderMaterial::fallback(),
            Some(entity),
        )],
        vec![RenderLight {
            type_: RenderLightType::Directional,
            direction: Float3::new(-1.0, -2.0, -1.0),
            ..RenderLight::new(RenderLightType::Directional)
        }],
    );
    let mut pose = MATRIX_IDENTITY_FLOAT4X4;
    pose.columns[3] = Float4::new(12.0, 3.0, 0.0, 1.0);
    let palette = JointPaletteMap::new(BTreeMap::from([(entity, JointPalette::new(vec![pose]))]));
    let mut settings = RenderShadowSettings::new_disabled();
    settings.enabled = true;
    let plan = ShadowAtlasPlanner::make_shadow_atlas_plan(
        &scene,
        RenderDrawableSize::new(256, 256),
        true,
        &settings,
        &palette,
        &|_| Some((Float3::splat(-1.0), Float3::splat(1.0))),
    );
    for x in [-1.0, 1.0] {
        for y in [-1.0, 1.0] {
            for z in [-1.0, 1.0] {
                let projected =
                    plan.uniforms.light_view_projection0 * pose * Float4::new(x, y, z, 1.0);
                let ndc = projected * (1.0 / projected.w);
                assert!(ndc.x.abs() <= 1.0 && ndc.y.abs() <= 1.0 && (0.0..=1.0).contains(&ndc.z));
            }
        }
    }
}

/// Orthographic shadow cascades follow visible height and carry parallel
/// shading with shadows off.
#[test]
fn orthographic_shadow_frustum() {
    let mut scene = scene(
        RenderCamera {
            orthographic_height: 6.0,
            projection: RenderCameraProjection::Orthographic,
            ..camera(Float3::new(0.0, 0.0, 8.0))
        },
        Vec::new(),
        vec![RenderLight {
            type_: RenderLightType::Directional,
            direction: Float3::new(-1.0, -2.0, -1.0),
            ..RenderLight::new(RenderLightType::Directional)
        }],
    );
    let size = RenderDrawableSize::new(800, 600);
    let mut settings = RenderShadowSettings::new_disabled();
    settings.enabled = true;
    settings.directional_cascade_count = 3;
    let disabled = ShadowAtlasPlanner::make_shadow_atlas_plan(
        &scene,
        size,
        false,
        &settings,
        &JointPaletteMap::default(),
        &|_| None,
    );
    assert!(!disabled.uniforms.is_enabled());
    assert_eq!(
        disabled.uniforms.camera_position_and_padding,
        Float4::new(0.0, 0.0, 8.0, 1.0)
    );
    let initial = ShadowAtlasPlanner::make_shadow_atlas_plan(
        &scene,
        size,
        true,
        &settings,
        &JointPaletteMap::default(),
        &|_| None,
    );
    assert_eq!(initial.lights.len(), 3);
    scene.camera.fov_y_radians = std::f32::consts::PI / 3.0;
    let different_fov = ShadowAtlasPlanner::make_shadow_atlas_plan(
        &scene,
        size,
        true,
        &settings,
        &JointPaletteMap::default(),
        &|_| None,
    );
    assert_eq!(
        initial.uniforms.light_view_projection0,
        different_fov.uniforms.light_view_projection0
    );
    scene.camera.orthographic_height *= 2.0;
    let expanded = ShadowAtlasPlanner::make_shadow_atlas_plan(
        &scene,
        size,
        true,
        &settings,
        &JointPaletteMap::default(),
        &|_| None,
    );
    assert_ne!(
        initial.uniforms.light_view_projection0,
        expanded.uniforms.light_view_projection0
    );
}

/// Orthographic rendering uses the drawable aspect and a parallel grid plane.
#[test]
fn orthographic_camera_matrices_and_grid_plane() {
    let mut camera = RenderCamera {
        orthographic_height: 4.0,
        projection: RenderCameraProjection::Orthographic,
        ..camera(Float3::new(0.0, 0.0, 5.0))
    };
    let matrices = RenderCameraMatrices::make(
        &scene(camera, Vec::new(), Vec::new()),
        RenderDrawableSize::new(200, 100),
    );
    assert_eq!(matrices.projection.columns[0].x, 0.25);
    assert_eq!(matrices.projection.columns[1].y, 0.5);
    assert_eq!(matrices.projection.columns[3].w, 1.0);
    assert_eq!(
        EditorGridPlane::make(&camera).normal(),
        Float3::new(0.0, 0.0, 1.0)
    );
    camera.eye = Float3::new(5.0, 0.0, 0.0);
    assert_eq!(
        EditorGridPlane::make(&camera).normal(),
        Float3::new(-1.0, 0.0, 0.0)
    );
    camera.eye = Float3::new(0.0, 5.0, 0.0);
    assert_eq!(
        EditorGridPlane::make(&camera).normal(),
        Float3::new(0.0, -1.0, 0.0)
    );
    camera.projection = RenderCameraProjection::Perspective;
    camera.eye = Float3::new(0.0, 0.0, 5.0);
    assert_eq!(
        EditorGridPlane::make(&camera).normal(),
        Float3::new(0.0, -1.0, 0.0)
    );
}

/// Builds projection, view and combined matrices.
#[test]
fn makes_projection_view_and_combined_matrices() {
    let scene = scene(
        RenderCamera {
            fov_y_radians: std::f32::consts::FRAC_PI_2,
            far: 100.0,
            ..camera(Float3::new(0.0, 0.0, 5.0))
        },
        Vec::new(),
        Vec::new(),
    );
    let matrices = RenderCameraMatrices::make(&scene, RenderDrawableSize::new(100, 50));
    assert!((matrices.projection.columns[0].x - 0.5).abs() < 0.000_001);
    assert_eq!(
        matrices.view_projection,
        matrices.projection * matrices.view
    );
}
