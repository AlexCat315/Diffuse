use super::post_probe_scene::PostProbeScene;
use diffuse_render::{RenderDrawableSize, RenderPacket};

pub enum StylizedProbeScene {}
impl StylizedProbeScene {
    pub fn packet(size: RenderDrawableSize, frame: i64) -> RenderPacket {
        let mut packet = PostProbeScene::packet(size, frame);
        packet.render_settings.stylization.enabled = true;
        packet.scene.camera.eye.x += (frame % 11) as f32 * 0.002;
        packet
    }
}
