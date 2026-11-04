//! CPU geometry/material batching shared by camera and shadow views.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use cove_graphics::rhi::RhiError;
use diffuse_assets::asset_pipeline::MeshMaterial;
use diffuse_math::simd::simd_compat::{
    Float3, Float4, Float4x4, simd_determinant, simd_dot, simd_normalize,
};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::rendering::render_scene::MaterialAlphaMode;

use crate::core::frame::render_packet::RenderPacket;
use crate::core::mesh::mesh_instance_uniforms::MeshInstanceUniforms;
use crate::core::mesh::mesh_visibility_plan::MeshVisibilityPlan;
use crate::core::mesh::resolved_mesh_material::ResolvedMeshMaterial;
use crate::core::render_settings::{RenderSettings, Visibility};
use crate::native::mesh::native_mesh_store::{NativeMesh, NativeMeshGeometry, NativeMeshStore};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NativeMeshBatchKey {
    pub mesh: i64,
    pub first_index: i64,
    pub index_count: i64,
    pub mode: MaterialAlphaMode,
    pub cutoff: u32,
    pub double_sided: bool,
    pub mirrored: bool,
    pub material_index: i64,
    pub base_texture: Option<usize>,
    pub normal_texture: Option<usize>,
    pub mr_texture: Option<usize>,
    pub unique_instance: Option<usize>,
}

#[derive(Clone)]
pub struct NativeMeshBatch {
    pub mesh: NativeMesh,
    pub geometry: NativeMeshGeometry,
    pub key: NativeMeshBatchKey,
    pub uniforms: Vec<MeshInstanceUniforms>,
    pub skin_entity: Option<EntityID>,
    pub distance: f32,
}

/// Key ordering must follow Swift's memberwise order; `cutoff` is hashed as the
/// bit pattern so NaN keys still dedupe deterministically.
fn cutoff_bits(cutoff: f32) -> u32 {
    cutoff.to_bits()
}

pub enum NativeMeshBatchPlanner {}

impl NativeMeshBatchPlanner {
    pub fn prepare(
        packet: &RenderPacket,
        store: &NativeMeshStore,
        view_projection: Float4x4,
        deformables: &BTreeMap<EntityID, NativeMeshGeometry>,
        shadow: bool,
    ) -> Result<(Vec<NativeMeshBatch>, MeshVisibilityPlan), RhiError> {
        let settings = if shadow {
            shadow_settings(&packet.render_settings)
        } else {
            packet.render_settings
        };
        let skinned_entities: BTreeSet<EntityID> =
            packet.joint_palette_map.palettes.keys().copied().collect();
        let visibility = MeshVisibilityPlan::make(
            &packet.scene,
            view_projection,
            &settings,
            &skinned_entities,
            |mesh_index| store.mesh(mesh_index).map(|mesh| mesh.geometry.bounds),
            |mesh_index| store.mesh(mesh_index).is_some(),
        );
        let mut members: HashMap<NativeMeshBatchKey, Vec<usize>> = HashMap::new();
        let mut order: Vec<NativeMeshBatchKey> = Vec::new();
        for index in &visibility.visible_indices {
            let instance = &packet.scene.instances[*index];
            let mesh_index = visibility
                .mesh_indices
                .get(index)
                .copied()
                .unwrap_or_else(|| instance.mesh.mesh_index);
            let dynamic = instance.entity.and_then(|entity| deformables.get(&entity));
            let mesh = match store.mesh(mesh_index) {
                Some(mesh) => Some(mesh.clone()),
                None => dynamic.map(|geometry| NativeMesh {
                    geometry: geometry.clone(),
                    materials: vec![MeshMaterial::fallback()],
                    textures: Default::default(),
                }),
            };
            let Some(mesh) = mesh else {
                return Err(RhiError::invalid_argument(format!(
                    "unregistered native mesh {mesh_index}"
                )));
            };
            for part in &(match dynamic {
                Some(geometry) => &geometry.submeshes,
                None => &mesh.geometry.submeshes,
            }) {
                let imported = mesh
                    .materials
                    .get(part.material_index as usize)
                    .cloned()
                    .unwrap_or_else(MeshMaterial::fallback);
                let material = ResolvedMeshMaterial::new(&imported, &instance.material);
                if shadow && material.alpha_mode == MaterialAlphaMode::Blend {
                    continue;
                }
                let posed = instance
                    .entity
                    .and_then(|entity| packet.joint_palette_map.palette(entity))
                    .is_some();
                let isolated = !packet.render_settings.visibility.mesh_instancing
                    || material.alpha_mode == MaterialAlphaMode::Blend
                    || posed
                    || dynamic.is_some();
                let key = NativeMeshBatchKey {
                    mesh: mesh_index,
                    first_index: part.index_start as i64,
                    index_count: part.index_count as i64,
                    mode: material.alpha_mode,
                    cutoff: cutoff_bits(material.cutoff),
                    double_sided: material.double_sided,
                    mirrored: simd_determinant(instance.transform) < 0.0,
                    material_index: part.material_index,
                    base_texture: material.base_texture.map(|value| value as usize),
                    normal_texture: material.normal_texture.map(|value| value as usize),
                    mr_texture: material.mr_texture.map(|value| value as usize),
                    unique_instance: if isolated { Some(*index) } else { None },
                };
                if !members.contains_key(&key) {
                    order.push(key);
                }
                members.entry(key).or_default().push(*index);
            }
        }
        if packet.render_settings.visibility.grouped_draw_by_mesh {
            order.sort_by_key(|key| key.mesh);
        }
        let mut batches: Vec<NativeMeshBatch> = Vec::new();
        let forward = simd_normalize(packet.scene.camera.target - packet.scene.camera.eye);
        for key in &order {
            let Some(indices) = members.get(key) else {
                continue;
            };
            let mut start = 0;
            while start < indices.len() {
                let first = &packet.scene.instances[indices[start]];
                let dynamic = first.entity.and_then(|entity| deformables.get(&entity));
                let mesh = match store.mesh(key.mesh) {
                    Some(mesh) => Some(mesh.clone()),
                    None => dynamic.map(|geometry| NativeMesh {
                        geometry: geometry.clone(),
                        materials: vec![MeshMaterial::fallback()],
                        textures: Default::default(),
                    }),
                };
                let Some(mesh) = mesh else {
                    start += 16_384;
                    continue;
                };
                let imported = mesh
                    .materials
                    .get(key.material_index as usize)
                    .cloned()
                    .unwrap_or_else(MeshMaterial::fallback);
                let end = (start + 16_384).min(indices.len());
                let mut uniforms = Vec::with_capacity(end - start);
                for index in &indices[start..end] {
                    let instance = &packet.scene.instances[*index];
                    let mode: f32 = match key.mode {
                        MaterialAlphaMode::Blend => 2.0,
                        MaterialAlphaMode::Mask => 1.0,
                        MaterialAlphaMode::Opaque => 0.0,
                    };
                    let color = ResolvedMeshMaterial::new(&imported, &instance.material).color;
                    let tint = instance.color_tint;
                    uniforms.push(MeshInstanceUniforms {
                        mvp: view_projection * instance.transform,
                        model: instance.transform,
                        color_tint: Float4::new(
                            tint.x * color.x,
                            tint.y * color.y,
                            tint.z * color.z,
                            color.w,
                        ),
                        material: Float4::new(
                            mode,
                            cutoff_bits_inverse(key.cutoff),
                            if key.double_sided { 1.0 } else { 0.0 },
                            0.0,
                        ),
                    });
                }
                let position = first.transform.columns[3];
                let geometry = match dynamic {
                    Some(geometry) => geometry.clone(),
                    None => mesh.geometry.clone(),
                };
                batches.push(NativeMeshBatch {
                    mesh,
                    geometry,
                    key: *key,
                    uniforms,
                    skin_entity: first.entity,
                    distance: simd_dot(
                        Float3::new(position.x, position.y, position.z) - packet.scene.camera.eye,
                        forward,
                    ),
                });
                start += 16_384;
            }
        }
        Ok((batches, visibility))
    }
}

fn cutoff_bits_inverse(bits: u32) -> f32 {
    f32::from_bits(bits)
}

fn shadow_settings(settings: &RenderSettings) -> RenderSettings {
    let mut result = *settings;
    result.visibility = Visibility {
        frustum_culling: false,
        distance_lod: false,
        ..result.visibility
    };
    result
}
