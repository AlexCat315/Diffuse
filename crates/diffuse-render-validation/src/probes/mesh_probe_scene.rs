use crate::native_pass_benchmark::NativeValidationError;
use diffuse_assets::asset_pipeline::MeshAsset;
use diffuse_assets::import::gltf_importer::GLTFImporter;
use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::render_backend_resource_bundle::url_for_resource;
use diffuse_render::{DebugViewMode, RenderDrawableSize, RenderPacket, RenderSettings};
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderEnvironment, RenderInstance, RenderMaterial, RenderScene,
};
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

pub enum MeshProbeScene {}
impl MeshProbeScene {
    pub fn imported_fixture() -> Result<MeshAsset, NativeValidationError> {
        let path = url_for_resource("NativeSceneFixture", "gltf", "").ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::NotFound, "NativeSceneFixture.gltf")
        })?;
        let path = path.to_str().ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "glTF fixture path is not UTF-8",
            )
        })?;
        Ok(GLTFImporter::load(path)?)
    }

    /// Repeated real meshes, a mirrored cube and the bundled OBJ fixture.
    pub fn packet(size: RenderDrawableSize, frame: i64) -> RenderPacket {
        let mut settings = RenderSettings::configured(|settings| {
            settings.shading.pbr = false;
            settings.shading.depth_prepass = true;
            settings.shading.debug_view_mode = DebugViewMode::Unlit;
        });
        settings.viewport.grid_enabled = false;
        settings.viewport.offscreen = true;
        let colors = [
            Float4::new(0.75, 0.25, 0.15, 1.0),
            Float4::new(0.2, 0.7, 0.35, 1.0),
            Float4::new(0.2, 0.4, 0.8, 1.0),
        ];
        let mut instances = Vec::new();
        for index in 0..36 {
            let column = index % 6;
            let row = index / 6;
            let mut transform = MATRIX_IDENTITY_FLOAT4X4;
            transform.columns[0].x = if index == 5 { -0.6 } else { 0.6 };
            transform.columns[1].y = 0.6;
            transform.columns[2].z = 0.6;
            transform.columns[3] = Float4::new(
                column as f32 * 1.5 - 3.75,
                0.6,
                row as f32 * 1.5 - 3.75,
                1.0,
            );
            instances.push(RenderInstance::from_mesh_index(
                0,
                transform,
                Float3::splat(1.0),
                RenderMaterial {
                    base_color_factor: colors[index % 3],
                    ..RenderMaterial::default()
                },
                None,
            ));
        }
        let mut fixture = MATRIX_IDENTITY_FLOAT4X4;
        fixture.columns[3] = Float4::new(0.0, 2.5, 0.0, 1.0);
        instances.push(RenderInstance::from_mesh_index(
            1,
            fixture,
            Float3::splat(1.0),
            RenderMaterial {
                base_color_factor: Float4::new(0.7, 0.65, 0.2, 1.0),
                double_sided: Some(true),
                ..RenderMaterial::default()
            },
            None,
        ));
        let snapshot = SceneRuntimeSnapshot::new(instances.len(), frame.max(0) as u64);
        RenderPacket::new(
            frame,
            1.0 / 60.0,
            size,
            RenderScene::new(
                RenderCamera::new(Float3::new(10.0, 9.0, 13.0), Float3::new(0.0, 0.8, 0.0)),
                instances,
                Vec::new(),
                RenderEnvironment::default(),
                Vec::new(),
                Vec::new(),
                Vec::new(),
                None,
            ),
            snapshot,
            settings,
            frame as f64 / 60.0,
            JointPaletteMap::default(),
            InGameCanvas::default(),
        )
    }
}
