//! Lighting uniform blocks shared by both render backends.
//!
//! Ported from `Engine/Sources/RenderBackend/Core/Lighting/Uniforms.swift`.
//! `SceneLightUniforms`, `ShadowUniforms` and `ShadowRenderUniforms` are
//! uploaded verbatim (MIGRATION.md §5.3); their layouts match
//! `SceneLights`/`ShadowView` in `pbr_lighting.slang` and `ShadowView` in
//! `mesh_common.slang`.

use diffuse_math::simd::simd_compat::{
    Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, simd_length_squared,
};
use diffuse_scene::rendering::render_scene::{RenderLight, RenderLightType, RenderScene};

pub const MAX_SCENE_LIGHT_UNIFORM_COUNT: usize = 8;
pub const MAX_SHADOW_ATLAS_TILE_COUNT: usize = 4;
pub const MAX_SHADOWED_DIRECTIONAL_LIGHT_COUNT: usize = MAX_SHADOW_ATLAS_TILE_COUNT;
pub const DEFAULT_SHADOW_MAP_RESOLUTION: u32 = 1024;

/// The shadow tile range granted to one scene light.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ShadowLightBinding {
    pub base_slot: usize,
    pub cascade_count: usize,
}

impl ShadowLightBinding {
    pub fn new(base_slot: usize, cascade_count: usize) -> Self {
        ShadowLightBinding {
            base_slot,
            cascade_count,
        }
    }
}

/// One light packed for the mesh shader; matches `SceneLight` in
/// `pbr_lighting.slang` (16 bytes, 16-aligned).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneLightUniform {
    pub position_and_type: Float4,
    pub direction_and_range: Float4,
    pub color_and_intensity: Float4,
    pub spot_angles_and_padding: Float4,
}

impl SceneLightUniform {
    pub const ZERO: SceneLightUniform = SceneLightUniform {
        position_and_type: Float4::ZERO,
        direction_and_range: Float4::ZERO,
        color_and_intensity: Float4::ZERO,
        spot_angles_and_padding: Float4::ZERO,
    };

    pub fn new(
        position_and_type: Float4,
        direction_and_range: Float4,
        color_and_intensity: Float4,
        spot_angles_and_padding: Float4,
    ) -> Self {
        SceneLightUniform {
            position_and_type,
            direction_and_range,
            color_and_intensity,
            spot_angles_and_padding,
        }
    }

    /// `init(_ light:shadowBinding:)` — `shadow_binding` defaults to `None` at
    /// the two call sites that omit it.
    pub fn from_light(light: &RenderLight, shadow_binding: Option<&ShadowLightBinding>) -> Self {
        SceneLightUniform::new(
            Float4::new(
                light.position.x,
                light.position.y,
                light.position.z,
                light.type_.uniform_code(),
            ),
            Float4::new(
                normalized(&light.direction).x,
                normalized(&light.direction).y,
                normalized(&light.direction).z,
                light.range,
            ),
            Float4::new(light.color.x, light.color.y, light.color.z, light.intensity),
            Float4::new(
                light.spot_inner_angle_radians,
                light.spot_outer_angle_radians,
                shadow_binding.map_or(0.0, |binding| (binding.base_slot + 1) as f32),
                shadow_binding.map_or(0.0, |binding| binding.cascade_count as f32),
            ),
        )
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<SceneLightUniform>() == 64);
const _: () = assert!(core::mem::align_of::<SceneLightUniform>() == 16);

/// The light block; matches `SceneLights` in `pbr_lighting.slang`
/// (16 + 16 + 8×64 = 544 bytes, 16-aligned).
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneLightUniforms {
    pub ambient_color_and_intensity: Float4,
    pub exposure_and_light_count: Float4,
    pub light0: SceneLightUniform,
    pub light1: SceneLightUniform,
    pub light2: SceneLightUniform,
    pub light3: SceneLightUniform,
    pub light4: SceneLightUniform,
    pub light5: SceneLightUniform,
    pub light6: SceneLightUniform,
    pub light7: SceneLightUniform,
}

impl SceneLightUniforms {
    /// `MemoryLayout<SceneLightUniforms>.stride`, used for buffer sizing.
    pub const BYTE_SIZE: u64 = core::mem::size_of::<SceneLightUniforms>() as u64;

    /// `init(scene:shadowBindingsByLightIndex:)` — `shadow_bindings` defaults
    /// to an empty map at call sites that omit it.
    pub fn new(
        scene: &RenderScene,
        shadow_bindings_by_light_index: &std::collections::BTreeMap<usize, ShadowLightBinding>,
    ) -> Self {
        let packed_lights: Vec<SceneLightUniform> = scene
            .lights
            .iter()
            .take(MAX_SCENE_LIGHT_UNIFORM_COUNT)
            .enumerate()
            .map(|(index, light)| {
                SceneLightUniform::from_light(light, shadow_bindings_by_light_index.get(&index))
            })
            .collect();
        SceneLightUniforms {
            ambient_color_and_intensity: Float4::new(
                scene.environment.ambient_color.x,
                scene.environment.ambient_color.y,
                scene.environment.ambient_color.z,
                scene.environment.ambient_intensity,
            ),
            exposure_and_light_count: Float4::new(
                scene.environment.exposure,
                packed_lights.len() as f32,
                0.0,
                0.0,
            ),
            light0: Self::light_at(0, &packed_lights),
            light1: Self::light_at(1, &packed_lights),
            light2: Self::light_at(2, &packed_lights),
            light3: Self::light_at(3, &packed_lights),
            light4: Self::light_at(4, &packed_lights),
            light5: Self::light_at(5, &packed_lights),
            light6: Self::light_at(6, &packed_lights),
            light7: Self::light_at(7, &packed_lights),
        }
    }

    fn light_at(index: usize, lights: &[SceneLightUniform]) -> SceneLightUniform {
        if index < lights.len() {
            lights[index]
        } else {
            SceneLightUniform::ZERO
        }
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<SceneLightUniforms>() == 544);
const _: () = assert!(core::mem::align_of::<SceneLightUniforms>() == 16);

/// The shadow block; matches `ShadowView` in `mesh_common.slang`
/// (4×64 + 8×16 = 384 bytes, 16-aligned).
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShadowUniforms {
    pub light_view_projection0: Float4x4,
    pub light_view_projection1: Float4x4,
    pub light_view_projection2: Float4x4,
    pub light_view_projection3: Float4x4,
    pub params0: Float4,
    pub params1: Float4,
    pub params2: Float4,
    pub params3: Float4,
    pub atlas_params: Float4,
    pub cascade_splits: Float4,
    /// xyz: eye position; w: 1 for orthographic view-dependent shading.
    pub camera_position_and_padding: Float4,
    pub camera_forward_and_padding: Float4,
}

impl ShadowUniforms {
    /// `static let disabled` — the fully zeroed atlas with the default map
    /// resolution and no camera.
    pub const DISABLED: ShadowUniforms = ShadowUniforms {
        light_view_projection0: MATRIX_IDENTITY_FLOAT4X4,
        light_view_projection1: MATRIX_IDENTITY_FLOAT4X4,
        light_view_projection2: MATRIX_IDENTITY_FLOAT4X4,
        light_view_projection3: MATRIX_IDENTITY_FLOAT4X4,
        params0: Float4::new(0.004, 0.55, 0.0, 0.0),
        params1: Float4::new(0.004, 0.55, 0.0, 0.0),
        params2: Float4::new(0.004, 0.55, 0.0, 0.0),
        params3: Float4::new(0.004, 0.55, 0.0, 0.0),
        atlas_params: Float4::new(
            0.0,
            0.0,
            DEFAULT_SHADOW_MAP_RESOLUTION as f32,
            DEFAULT_SHADOW_MAP_RESOLUTION as f32,
        ),
        cascade_splits: Float4::ZERO,
        camera_position_and_padding: Float4::ZERO,
        camera_forward_and_padding: Float4::new(0.0, 0.0, -1.0, 0.0),
    };

    /// Disabled-shadow uniforms. The camera position/forward must still be the
    /// real camera: the mesh shader reads `camera_position_and_padding` to build
    /// its view vector for ALL view-dependent shading (specular, Fresnel, and the
    /// environment reflection). Leaving it zero when shadows are off pins the view
    /// vector to the world origin and blows glossy metal out to a flat "white
    /// model" — independent of whether any shadow is actually cast.
    pub fn disabled(
        map_resolution: u32,
        camera_position: Float3,
        camera_forward: Float3,
        orthographic: bool,
    ) -> Self {
        ShadowUniforms {
            light_view_projection0: MATRIX_IDENTITY_FLOAT4X4,
            light_view_projection1: MATRIX_IDENTITY_FLOAT4X4,
            light_view_projection2: MATRIX_IDENTITY_FLOAT4X4,
            light_view_projection3: MATRIX_IDENTITY_FLOAT4X4,
            params0: Float4::new(0.004, 0.55, 0.0, 0.0),
            params1: Float4::new(0.004, 0.55, 0.0, 0.0),
            params2: Float4::new(0.004, 0.55, 0.0, 0.0),
            params3: Float4::new(0.004, 0.55, 0.0, 0.0),
            atlas_params: Float4::new(0.0, 0.0, map_resolution as f32, map_resolution as f32),
            cascade_splits: Float4::ZERO,
            camera_position_and_padding: Float4::new(
                camera_position.x,
                camera_position.y,
                camera_position.z,
                if orthographic { 1.0 } else { 0.0 },
            ),
            camera_forward_and_padding: Float4::new(
                camera_forward.x,
                camera_forward.y,
                camera_forward.z,
                0.0,
            ),
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.atlas_params.x > 0.5 && self.atlas_params.y > 0.5
    }
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<ShadowUniforms>() == 384);
const _: () = assert!(core::mem::align_of::<ShadowUniforms>() == 16);

/// The per-tile shadow-pass uniform; matches `ShadowView` in
/// `shadow_mesh.slang` / `mesh_common.slang` (64 bytes, 16-aligned).
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShadowRenderUniforms {
    pub light_view_projection: Float4x4,
}

// MIGRATION.md §5.3: the bytes uploaded to the GPU must not change.
const _: () = assert!(core::mem::size_of::<ShadowRenderUniforms>() == 64);
const _: () = assert!(core::mem::align_of::<ShadowRenderUniforms>() == 16);

impl RenderLightType {
    /// `private extension RenderLightType.uniformCode`.
    pub fn uniform_code(self) -> f32 {
        match self {
            RenderLightType::Directional => 0.0,
            RenderLightType::Point => 1.0,
            RenderLightType::Spot => 2.0,
        }
    }
}

/// `private func normalized(_:)` — a degenerate direction falls back to
/// `(0, -1, 0)`.
pub(crate) fn normalized(value: &Float3) -> Float3 {
    let length_squared = simd_length_squared(*value);
    if length_squared > 0.000_001 {
        *value / length_squared.sqrt()
    } else {
        Float3::new(0.0, -1.0, 0.0)
    }
}
