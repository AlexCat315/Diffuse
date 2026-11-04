use super::pbr_probe_scene::PBRProbeScene;
use diffuse_assets::asset_pipeline::{BuiltinMesh, MeshAsset};
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::{RenderDrawableSize, RenderPacket};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::JointPalette;
use diffuse_scene::rendering::render_scene::{
    MaterialAlphaMode, RenderDeformableMesh, RenderInstance, RenderMaterial,
};

pub enum AnimatedProbeScene {}
impl AnimatedProbeScene {
    pub fn skinned_fixture() -> MeshAsset {
        let mut mesh = BuiltinMesh::cube(Some(Float3::splat(1.0)));
        mesh.name = "animated-native-probe".into();
        for vertex in 0..mesh.vertex_count() {
            let offset = vertex * MeshAsset::VERTEX_FLOAT_COUNT;
            mesh.vertices[offset + MeshAsset::JOINTS_FLOAT_OFFSET] =
                if mesh.vertices[offset + 1] > 0.0 {
                    1.0
                } else {
                    0.0
                };
            mesh.vertices[offset + MeshAsset::WEIGHTS_FLOAT_OFFSET] = 1.0;
        }
        mesh
    }
    pub fn packet(size: RenderDrawableSize, frame: i64) -> RenderPacket {
        let mut packet = PBRProbeScene::packet(size, frame);
        packet.scene.camera.eye.x += (frame % 11) as f32 * 0.002;
        let time = frame as f32 * 0.04;
        for index in 0..6 {
            let entity = EntityID::from_raw_value(100 + index);
            let mut transform = MATRIX_IDENTITY_FLOAT4X4;
            transform.columns[3] = Float4::new(index as f32 * 1.4 - 3.5, 2.5, 1.0, 1.0);
            let mut joint = MATRIX_IDENTITY_FLOAT4X4;
            let angle = (time + index as f32).sin() * 0.3;
            joint.columns[0] = Float4::new(angle.cos(), angle.sin(), 0.0, 0.0);
            joint.columns[1] = Float4::new(-angle.sin(), angle.cos(), 0.0, 0.0);
            packet.joint_palette_map.palettes.insert(
                entity,
                JointPalette::new(vec![MATRIX_IDENTITY_FLOAT4X4, joint]),
            );
            packet.scene.instances.push(RenderInstance::from_mesh_index(
                2,
                transform,
                Float3::splat(1.0),
                RenderMaterial {
                    base_color_factor: Float4::new(0.25, 0.65, 0.85, 1.0),
                    ..RenderMaterial::default()
                },
                Some(entity),
            ));
            transform.columns[3] = Float4::new(index as f32 * 1.4 - 3.5, 0.9, 3.0, 1.0);
            packet.scene.instances.push(RenderInstance::from_mesh_index(
                0,
                transform,
                Float3::splat(1.0),
                RenderMaterial {
                    base_color_factor: Float4::new(0.7, 0.2, 0.45, 0.35),
                    alpha_mode: Some(MaterialAlphaMode::Blend),
                    double_sided: Some(true),
                    ..RenderMaterial::default()
                },
                None,
            ));
        }
        let cloth = EntityID::from_raw_value(200);
        let mut positions = Vec::new();
        let mut indices = Vec::new();
        for y in 0..12 {
            for x in 0..12 {
                let u = x as f32 / 11.0;
                let v = y as f32 / 11.0;
                positions.push(Float3::new(
                    u * 4.0 - 2.0,
                    3.2 + v * 2.0,
                    (u * 5.0 + time).sin() * 0.3 - 1.0,
                ));
                if x < 11 && y < 11 {
                    let i = (y * 12 + x) as u32;
                    indices.extend_from_slice(&[i, i + 1, i + 13, i, i + 13, i + 12]);
                }
            }
        }
        packet.scene.deformable_meshes = vec![RenderDeformableMesh::with_geometry(
            cloth,
            frame.max(0) as u64,
            Some(1),
            positions,
            indices,
            Vec::new(),
            None,
        )];
        packet.scene.instances.push(RenderInstance::from_mesh_index(
            0,
            MATRIX_IDENTITY_FLOAT4X4,
            Float3::splat(1.0),
            RenderMaterial {
                base_color_factor: Float4::new(0.85, 0.55, 0.2, 1.0),
                double_sided: Some(true),
                ..RenderMaterial::default()
            },
            Some(cloth),
        ));
        packet
    }
}
