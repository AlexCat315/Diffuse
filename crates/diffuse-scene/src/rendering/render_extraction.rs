//! Render-facing ECS components: mesh, material, camera and light.
//!
//! Ported from `Engine/Sources/SceneRuntime/Rendering/RenderExtraction.swift`.
//!
//! This module currently holds the component types that have no forward
//! dependency. `ExtractedRenderSceneResource` and the two `RenderCamera`/
//! `RenderScene` static-extension members need those container types, which are
//! the remaining tail of `rendering/render_scene.rs`, so they are not here yet.
//!
//! `RenderMaterialComponent` deliberately wraps the existing
//! [`crate::rendering::render_scene::RenderMaterial`] rather than duplicating its
//! clamping rules: Swift's `init` builds a `RenderMaterial` and copies its fields
//! back out, which is how the two stay in step.

use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::entity_id::RuntimeComponent;
use crate::rendering::render_scene::{MaterialAlphaMode, RenderMaterial, RenderMeshLOD};

/// `RenderMeshComponent` — which mesh to draw, and how it is tinted.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderMeshComponent {
    pub mesh_index: i64,
    pub is_visible: bool,
    pub color_tint: Float3,
    pub asset_id: Option<String>,
    pub levels_of_detail: Vec<RenderMeshLOD>,
}

impl RenderMeshComponent {
    pub fn new(
        mesh_index: i64,
        is_visible: bool,
        color_tint: Float3,
        asset_id: Option<String>,
        levels_of_detail: Vec<RenderMeshLOD>,
    ) -> Self {
        RenderMeshComponent {
            mesh_index,
            is_visible,
            color_tint,
            asset_id,
            levels_of_detail,
        }
    }
}

impl RuntimeComponent for RenderMeshComponent {}

/// `RenderMaterialComponent` — the material override stored on an entity.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderMaterialComponent {
    pub base_color_factor: Float4,
    pub base_color_texture_index: Option<i64>,
    pub normal_texture_index: Option<i64>,
    pub metallic_factor: f32,
    pub roughness_factor: f32,
    pub emissive_factor: Float3,
    pub alpha_mode: Option<MaterialAlphaMode>,
    pub alpha_cutoff: Option<f32>,
    pub double_sided: Option<bool>,
}

impl RenderMaterialComponent {
    /// Swift funnels the memberwise `init` through `RenderMaterial`, so all
    /// clamping (`metallic`/`roughness` to `0...1`, non-finite `alphaCutoff` to
    /// `0.5`) happens there and is copied back out unchanged.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        base_color_factor: Float4,
        base_color_texture_index: Option<i64>,
        normal_texture_index: Option<i64>,
        metallic_factor: f32,
        roughness_factor: f32,
        emissive_factor: Float3,
        alpha_mode: Option<MaterialAlphaMode>,
        alpha_cutoff: Option<f32>,
        double_sided: Option<bool>,
    ) -> Self {
        let material = RenderMaterial::new(
            base_color_factor,
            base_color_texture_index,
            normal_texture_index,
            metallic_factor,
            roughness_factor,
            emissive_factor,
            alpha_mode,
            alpha_cutoff,
            double_sided,
        );
        RenderMaterialComponent {
            base_color_factor: material.base_color_factor,
            base_color_texture_index: material.base_color_texture_index,
            normal_texture_index: material.normal_texture_index,
            metallic_factor: material.metallic_factor,
            roughness_factor: material.roughness_factor,
            emissive_factor: material.emissive_factor,
            alpha_mode: material.alpha_mode,
            alpha_cutoff: material.alpha_cutoff,
            double_sided: material.double_sided,
        }
    }

    /// `var renderMaterial` — the rendering-facing value.
    pub fn render_material(&self) -> RenderMaterial {
        RenderMaterial::new(
            self.base_color_factor,
            self.base_color_texture_index,
            self.normal_texture_index,
            self.metallic_factor,
            self.roughness_factor,
            self.emissive_factor,
            self.alpha_mode,
            self.alpha_cutoff,
            self.double_sided,
        )
    }
}

impl RuntimeComponent for RenderMaterialComponent {}

/// `CameraComponent` — an orbit-style camera target.
#[derive(Clone, Debug, PartialEq)]
pub struct CameraComponent {
    pub target: Float3,
    pub up: Float3,
    pub fov_y_radians: f32,
    pub aspect_ratio: f32,
    pub near: f32,
    pub far: f32,
    pub is_active: bool,
}

impl CameraComponent {
    pub fn new(
        target: Float3,
        up: Float3,
        fov_y_radians: f32,
        aspect_ratio: f32,
        near: f32,
        far: f32,
        is_active: bool,
    ) -> Self {
        CameraComponent {
            target,
            up,
            fov_y_radians,
            aspect_ratio: aspect_ratio.max(0.001),
            near,
            far,
            is_active,
        }
    }
}

impl Default for CameraComponent {
    /// Swift's memberwise defaults: identity target, +Y up, 45° vertical FOV,
    /// unit aspect, `0.1...100` depth range, active.
    fn default() -> Self {
        CameraComponent {
            target: Float3::ZERO,
            up: Float3::new(0.0, 1.0, 0.0),
            fov_y_radians: std::f32::consts::PI / 4.0,
            aspect_ratio: 1.0,
            near: 0.1,
            far: 100.0,
            is_active: true,
        }
    }
}

impl RuntimeComponent for CameraComponent {}

/// `LightType`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LightType {
    Directional,
    Point,
    Spot,
}

impl LightType {
    /// The case name, which is what Swift's `String` raw value encodes.
    pub const fn raw_value(&self) -> &'static str {
        match self {
            LightType::Directional => "directional",
            LightType::Point => "point",
            LightType::Spot => "spot",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "directional" => Some(LightType::Directional),
            "point" => Some(LightType::Point),
            "spot" => Some(LightType::Spot),
            _ => None,
        }
    }

    /// Swift `CaseIterable.allCases`, in declaration order.
    pub const ALL: [LightType; 3] = [LightType::Directional, LightType::Point, LightType::Spot];
}

impl RuntimeComponent for LightType {}

/// `LightComponent`.
#[derive(Clone, Debug, PartialEq)]
pub struct LightComponent {
    pub light_type: LightType,
    pub color: Float3,
    pub intensity: f32,
    pub range: f32,
    pub spot_inner_angle_degrees: f32,
    pub spot_outer_angle_degrees: f32,
    pub cast_shadows: bool,
}

impl LightComponent {
    /// The spot angles are clamped in order: `outer = clamp(1...179)`, then
    /// `inner = clamp(0...outer)`. Reversing them changes the result when both
    /// are out of range, so the two steps stay separate.
    pub fn new(
        light_type: LightType,
        color: Float3,
        intensity: f32,
        range: f32,
        spot_inner_angle_degrees: f32,
        spot_outer_angle_degrees: f32,
        cast_shadows: bool,
    ) -> Self {
        let outer = spot_outer_angle_degrees.clamp(1.0, 179.0);
        let inner = spot_inner_angle_degrees.clamp(0.0, outer);
        LightComponent {
            light_type,
            color,
            intensity,
            range: range.max(0.0),
            spot_inner_angle_degrees: inner,
            spot_outer_angle_degrees: outer,
            cast_shadows,
        }
    }
}

impl Default for LightComponent {
    /// Swift's memberwise defaults: directional white light at intensity 1,
    /// range 10, 20°/30° spot cones, shadows off.
    fn default() -> Self {
        LightComponent {
            light_type: LightType::Directional,
            color: Float3::new(1.0, 1.0, 1.0),
            intensity: 1.0,
            range: 10.0,
            spot_inner_angle_degrees: 20.0,
            spot_outer_angle_degrees: 30.0,
            cast_shadows: false,
        }
    }
}

impl RuntimeComponent for LightComponent {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn material_component_clamps_through_render_material() {
        let material = RenderMaterialComponent::new(
            Float4::new(1.0, 1.0, 1.0, 1.0),
            None,
            None,
            5.0,
            -2.0,
            Float3::ZERO,
            None,
            Some(f32::NAN),
            None,
        );
        assert_eq!(material.metallic_factor, 1.0);
        assert_eq!(material.roughness_factor, 0.0);
        // Non-finite cutoff falls back to 0.5, matching `RenderMaterial`.
        assert_eq!(material.alpha_cutoff, Some(0.5));
    }

    #[test]
    fn material_component_round_trips_through_render_material() {
        let material = RenderMaterialComponent::new(
            Float4::new(0.5, 0.25, 1.0, 1.0),
            Some(2),
            Some(3),
            0.25,
            0.75,
            Float3::new(0.1, 0.2, 0.3),
            Some(MaterialAlphaMode::Mask),
            Some(0.4),
            Some(true),
        );
        let rendering = material.render_material();
        assert_eq!(material.base_color_factor, rendering.base_color_factor);
        assert_eq!(
            material.base_color_texture_index,
            rendering.base_color_texture_index
        );
        assert_eq!(
            material.normal_texture_index,
            rendering.normal_texture_index
        );
        assert_eq!(material.metallic_factor, rendering.metallic_factor);
        assert_eq!(material.roughness_factor, rendering.roughness_factor);
        assert_eq!(material.emissive_factor, rendering.emissive_factor);
        assert_eq!(material.alpha_mode, rendering.alpha_mode);
        assert_eq!(material.alpha_cutoff, rendering.alpha_cutoff);
        assert_eq!(material.double_sided, rendering.double_sided);
    }

    #[test]
    fn camera_clamps_aspect_to_positive() {
        let camera = CameraComponent::new(
            Float3::ZERO,
            Float3::new(0.0, 1.0, 0.0),
            1.0,
            0.0,
            0.1,
            100.0,
            true,
        );
        assert_eq!(camera.aspect_ratio, 0.001);
        assert_eq!(CameraComponent::default().aspect_ratio, 1.0);
    }

    #[test]
    fn light_spot_angles_clamp_outer_before_inner() {
        // Both out of range: outer clamps to 179 first, then inner to 179.
        let light =
            LightComponent::new(LightType::Spot, Float3::ZERO, 1.0, 1.0, 300.0, 300.0, false);
        assert_eq!(light.spot_outer_angle_degrees, 179.0);
        assert_eq!(light.spot_inner_angle_degrees, 179.0);
        // Outer clamps up to 1; inner cannot exceed that.
        let light = LightComponent::new(LightType::Spot, Float3::ZERO, 1.0, 1.0, 50.0, -5.0, false);
        assert_eq!(light.spot_outer_angle_degrees, 1.0);
        assert_eq!(light.spot_inner_angle_degrees, 1.0);
        // Range floors at zero.
        let light =
            LightComponent::new(LightType::Point, Float3::ZERO, 1.0, -3.0, 20.0, 30.0, false);
        assert_eq!(light.range, 0.0);
    }

    #[test]
    fn light_type_round_trips() {
        for light_type in LightType::ALL {
            assert_eq!(
                LightType::from_raw_value(light_type.raw_value()),
                Some(light_type)
            );
        }
        assert_eq!(LightType::from_raw_value("ambient"), None);
    }
}

/// One frame's extracted render scene, with the entities it came from.
///
/// The entity lists are kept because a consumer often needs to map a drawn instance
/// back to the entity that produced it — the `RenderInstance` itself only carries an
/// optional entity.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ExtractedRenderSceneResource {
    pub scene: crate::rendering::render_scene::RenderScene,
    pub active_camera_entity: Option<crate::entity_id::EntityID>,
    pub instance_entities: Vec<crate::entity_id::EntityID>,
    pub light_entities: Vec<crate::entity_id::EntityID>,
    pub source_revision: u64,
}

impl ExtractedRenderSceneResource {
    pub fn new(
        scene: crate::rendering::render_scene::RenderScene,
        active_camera_entity: Option<crate::entity_id::EntityID>,
        instance_entities: Vec<crate::entity_id::EntityID>,
        light_entities: Vec<crate::entity_id::EntityID>,
        source_revision: u64,
    ) -> Self {
        ExtractedRenderSceneResource {
            scene,
            active_camera_entity,
            instance_entities,
            light_entities,
            source_revision,
        }
    }
}

#[cfg(test)]
mod extracted_scene_tests {
    use super::*;

    #[test]
    fn a_default_extraction_holds_an_empty_scene() {
        let resource = ExtractedRenderSceneResource::default();
        assert!(resource.scene.instances.is_empty());
        assert!(resource.scene.lights.is_empty());
        assert_eq!(resource.active_camera_entity, None);
        assert_eq!(resource.source_revision, 0);
    }
}
