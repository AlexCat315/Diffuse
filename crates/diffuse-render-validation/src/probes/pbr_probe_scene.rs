use super::mesh_probe_scene::MeshProbeScene;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::{DebugViewMode, RenderDrawableSize, RenderPacket, RenderShadowSettings};
use diffuse_scene::rendering::render_scene::{
    RenderEnvironment, RenderInstance, RenderLight, RenderLightType, RenderMaterial,
};

pub enum PBRProbeScene {}
impl PBRProbeScene {
    pub fn packet(size: RenderDrawableSize, frame: i64) -> RenderPacket {
        let mut packet = MeshProbeScene::packet(size, frame);
        packet.render_settings.shading.pbr = true;
        packet.render_settings.shading.depth_prepass = true;
        packet.render_settings.shading.debug_view_mode = DebugViewMode::Shaded;
        packet.render_settings.viewport.grid_enabled = true;
        packet.render_settings.shadows = RenderShadowSettings {
            enabled: true,
            map_resolution: 256,
            depth_bias: 0.004,
            strength: 0.85,
            max_shadowed_directional_lights: 2,
            directional_cascade_count: 2,
            ..RenderShadowSettings::default()
        };
        packet.scene.environment = RenderEnvironment::new(Float3::new(0.8, 0.9, 1.0), 0.2, 1.2);
        packet.scene.lights = vec![
            RenderLight {
                direction: Float3::new(-0.6, -1.0, -0.4),
                color: Float3::new(1.0, 0.8, 0.65),
                intensity: 3.0,
                cast_shadows: true,
                ..RenderLight::new(RenderLightType::Directional)
            },
            RenderLight {
                direction: Float3::new(0.4, -0.6, 0.8),
                color: Float3::new(0.35, 0.55, 1.0),
                intensity: 1.0,
                cast_shadows: true,
                ..RenderLight::new(RenderLightType::Directional)
            },
            RenderLight {
                position: Float3::new(0.0, 3.0, 2.0),
                color: Float3::new(1.0, 0.25, 0.2),
                intensity: 5.0,
                range: 12.0,
                ..RenderLight::new(RenderLightType::Point)
            },
        ];
        let mut ground = MATRIX_IDENTITY_FLOAT4X4;
        ground.columns[0].x = 12.0;
        ground.columns[1].y = 0.2;
        ground.columns[2].z = 12.0;
        ground.columns[3].y = -0.3;
        packet.scene.instances.push(RenderInstance::from_mesh_index(
            0,
            ground,
            Float3::splat(1.0),
            RenderMaterial {
                base_color_factor: Float4::new(0.5, 0.5, 0.55, 1.0),
                ..RenderMaterial::default()
            },
            None,
        ));
        packet
    }
}
