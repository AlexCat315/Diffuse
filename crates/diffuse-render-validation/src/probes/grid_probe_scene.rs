use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_render::{RenderDrawableSize, RenderPacket, RenderSettings};
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderEnvironment, RenderScene};
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

pub enum GridProbeScene {}
impl GridProbeScene {
    pub fn packet(
        size: RenderDrawableSize,
        frame: i64,
        camera: Option<RenderCamera>,
    ) -> RenderPacket {
        let mut settings = RenderSettings::configured(|settings| {
            settings.shading.pbr = false;
            settings.shading.depth_prepass = false;
        });
        settings.viewport.grid_enabled = true;
        settings.viewport.grid_spacing = 0.5;
        RenderPacket::new(
            frame,
            1.0 / 60.0,
            size,
            RenderScene::new(
                camera
                    .unwrap_or_else(|| RenderCamera::new(Float3::new(7.0, 6.0, 9.0), Float3::ZERO)),
                Vec::new(),
                Vec::new(),
                RenderEnvironment::default(),
                Vec::new(),
                Vec::new(),
                Vec::new(),
                None,
            ),
            SceneRuntimeSnapshot::new(0, frame.max(0) as u64),
            settings,
            frame as f64 / 60.0,
            JointPaletteMap::default(),
            InGameCanvas::default(),
        )
    }
}
