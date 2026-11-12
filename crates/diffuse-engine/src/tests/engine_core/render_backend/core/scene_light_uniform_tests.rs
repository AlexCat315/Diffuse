//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/Core/SceneLightUniformTests.swift`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, Float4};
use diffuse_render::core::lighting::uniforms::{
    SceneLightUniform, SceneLightUniforms, ShadowLightBinding,
};
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderEnvironment, RenderLight, RenderLightType, RenderScene,
};

fn scene(lights: Vec<RenderLight>, environment: RenderEnvironment) -> RenderScene {
    RenderScene::new(
        RenderCamera::default(),
        Vec::new(),
        lights,
        environment,
        Vec::new(),
        Vec::new(),
        Vec::new(),
        None,
    )
}

/// Packs render-scene lights into the GPU contract.
#[test]
fn packs_render_scene_lights() {
    let scene = scene(
        vec![RenderLight {
            type_: RenderLightType::Spot,
            position: Float3::new(1.0, 2.0, 3.0),
            direction: Float3::new(0.0, -2.0, 0.0),
            color: Float3::new(0.8, 0.7, 0.6),
            intensity: 3.0,
            range: 12.0,
            spot_inner_angle_radians: 0.25,
            spot_outer_angle_radians: 0.75,
            ..RenderLight::new(RenderLightType::Spot)
        }],
        RenderEnvironment::new(Float3::new(0.2, 0.3, 0.4), 0.5, 1.25),
    );

    let uniforms = SceneLightUniforms::new(&scene, &BTreeMap::new());

    assert_eq!(
        SceneLightUniforms::BYTE_SIZE,
        std::mem::size_of::<SceneLightUniforms>() as u64
    );
    assert_eq!(
        uniforms.ambient_color_and_intensity,
        Float4::new(0.2, 0.3, 0.4, 0.5)
    );
    assert_eq!(
        uniforms.exposure_and_light_count,
        Float4::new(1.25, 1.0, 0.0, 0.0)
    );
    assert_eq!(
        uniforms.light0.position_and_type,
        Float4::new(1.0, 2.0, 3.0, 2.0)
    );
    assert_eq!(
        uniforms.light0.direction_and_range,
        Float4::new(0.0, -1.0, 0.0, 12.0)
    );
    assert_eq!(
        uniforms.light0.color_and_intensity,
        Float4::new(0.8, 0.7, 0.6, 3.0)
    );
    assert_eq!(
        uniforms.light0.spot_angles_and_padding,
        Float4::new(0.25, 0.75, 0.0, 0.0)
    );
    assert_eq!(uniforms.light1, SceneLightUniform::ZERO);
}

/// Packs directional shadow slots into light uniforms.
#[test]
fn packs_directional_shadow_slots() {
    let scene = scene(
        vec![
            RenderLight {
                type_: RenderLightType::Directional,
                direction: Float3::new(0.0, -1.0, 0.0),
                intensity: 1.0,
                ..RenderLight::new(RenderLightType::Directional)
            },
            RenderLight {
                type_: RenderLightType::Directional,
                direction: Float3::new(1.0, -1.0, 0.0),
                intensity: 2.0,
                ..RenderLight::new(RenderLightType::Directional)
            },
        ],
        RenderEnvironment::fallback(),
    );
    let bindings = BTreeMap::from([
        (0, ShadowLightBinding::new(1, 3)),
        (1, ShadowLightBinding::new(0, 1)),
    ]);

    let uniforms = SceneLightUniforms::new(&scene, &bindings);

    assert_eq!(uniforms.light0.spot_angles_and_padding.z, 2.0);
    assert_eq!(uniforms.light0.spot_angles_and_padding.w, 3.0);
    assert_eq!(uniforms.light1.spot_angles_and_padding.z, 1.0);
    assert_eq!(uniforms.light1.spot_angles_and_padding.w, 1.0);
}
