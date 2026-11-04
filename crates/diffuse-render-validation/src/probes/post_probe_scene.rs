use super::pbr_probe_scene::PBRProbeScene;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::{RenderDrawableSize, RenderPacket};
use diffuse_scene::rendering::render_scene::{MaterialAlphaMode, RenderInstance, RenderMaterial};

pub enum PostProbeScene {}
impl PostProbeScene {
    pub fn packet(size: RenderDrawableSize, frame: i64) -> RenderPacket {
        let mut packet = PBRProbeScene::packet(size, frame);
        packet.render_settings.post_processing.ssao = true;
        packet.render_settings.post_processing.ssr = true;
        packet.render_settings.post_processing.taa = true;
        packet.render_settings.post_processing.bloom = true;
        packet.render_settings.post_processing.fxaa = true;
        packet.scene.camera.eye.x += ((frame / 12) % 11) as f32 * 0.04;
        packet.scene.lights[2].intensity = 40.0;
        let mut transform = MATRIX_IDENTITY_FLOAT4X4;
        transform.columns[3] = Float4::new(0.0, 1.0, 3.0, 1.0);
        packet.scene.instances.push(RenderInstance::from_mesh_index(
            0,
            transform,
            Float3::splat(1.0),
            RenderMaterial {
                base_color_factor: Float4::new(0.25, 0.65, 0.9, 0.4),
                alpha_mode: Some(MaterialAlphaMode::Blend),
                double_sided: Some(true),
                ..RenderMaterial::default()
            },
            None,
        ));
        packet
    }
}
