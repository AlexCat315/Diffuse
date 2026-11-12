//! `Editor/Sources/EditorCore/Scene/Adapter/Ragdoll.swift`.

use std::collections::BTreeMap;

use diffuse_assets::asset_pipeline::MeshNode;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::{
    Float3, Float4x4, MATRIX_IDENTITY_FLOAT4X4, Quatf, simd_inverse, simd_length,
    simd_length_squared,
};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::physics::collider::{Collider, ColliderShape, ColliderShapeInstance};
use diffuse_scene::physics::joints::physics_joint::PhysicsJoint;
use diffuse_scene::physics::joints::physics_joint_configuration::{
    ConeJointConfiguration, PhysicsJointConfiguration,
};
use diffuse_scene::physics::ragdoll::{Ragdoll, RagdollBoneMapping, RagdollMode};
use diffuse_scene::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_bootstrap::{
    AssetReferenceComponent, SceneKindComponent, SceneNameComponent,
};

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EditorRagdollGenerationResult {
    pub body_count: usize,
    pub joint_count: usize,
    pub error: Option<String>,
}

impl EditorRagdollGenerationResult {
    pub fn new(body_count: usize, joint_count: usize, error: Option<String>) -> Self {
        EditorRagdollGenerationResult {
            body_count,
            joint_count,
            error,
        }
    }

    pub fn with_error(error: impl Into<String>) -> Self {
        EditorRagdollGenerationResult {
            body_count: 0,
            joint_count: 0,
            error: Some(error.into()),
        }
    }
}

impl EditorSceneAdapter {
    /// Generates a playable first-pass ragdoll from the first skin of the entity's mesh.
    /// Bodies and joints are created as children of the selected skinned entity so the
    /// result remains editable and serializable like ordinary scene physics components.
    pub fn generate_ragdoll(&self, raw_id: u64) -> EditorRagdollGenerationResult {
        let root = EntityID::from_raw_value(raw_id);
        if !self.scene().contains(root) {
            return EditorRagdollGenerationResult::with_error("Entity not found");
        }
        if self.scene().has_component::<Ragdoll>(root) {
            return EditorRagdollGenerationResult::with_error("Entity already has a ragdoll");
        }
        let asset = match self.scene().component::<AssetReferenceComponent>(root) {
            Some(asset) => asset,
            None => {
                return EditorRagdollGenerationResult::with_error(
                    "Skinned mesh data is unavailable",
                );
            }
        };
        let mesh = match AssetRegistry::shared().mesh_asset(asset.mesh_index) {
            Some(mesh) => mesh,
            None => {
                return EditorRagdollGenerationResult::with_error(
                    "Skinned mesh data is unavailable",
                );
            }
        };
        let skin = match mesh.skins.first() {
            Some(skin) if !skin.joint_node_indices.is_empty() => skin.clone(),
            _ => {
                return EditorRagdollGenerationResult::with_error(
                    "Skinned mesh data is unavailable",
                );
            }
        };

        let node_world = ragdoll_node_world_matrices(&mesh.nodes);
        let joint_set: std::collections::BTreeSet<i64> =
            skin.joint_node_indices.iter().copied().collect();
        let root_name = self
            .scene()
            .component::<SceneNameComponent>(root)
            .map(|name| name.value)
            .unwrap_or_else(|| "Ragdoll".to_string());

        let (mappings, joint_count) = self.with_scene_mut(|scene| {
            let mut body_by_node: BTreeMap<i64, EntityID> = BTreeMap::new();
            let mut mappings: Vec<RagdollBoneMapping> = Vec::new();

            for (palette_index, node_index) in skin.joint_node_indices.iter().copied().enumerate() {
                let Some(node_slot_index) = node_slot(node_index, mesh.nodes.len()) else {
                    continue;
                };
                if node_slot_index >= node_world.len() {
                    continue;
                }
                let node = &mesh.nodes[node_slot_index];
                let bone_name = node
                    .name
                    .clone()
                    .unwrap_or_else(|| format!("bone_{node_index}"));
                let child_index = skin.joint_node_indices.iter().copied().find(|candidate| {
                    node_slot_of(*candidate, &mesh.nodes)
                        .and_then(|slot| mesh.nodes[slot].parent_index)
                        == Some(node_index)
                });
                let child_offset: Option<Float3> = child_index.and_then(|child| {
                    let child_slot = node_slot(child, node_world.len())?;
                    let local = simd_inverse(node_world[node_slot_index]) * node_world[child_slot];
                    let translation = local.column(3);
                    Some(Float3::new(translation.x, translation.y, translation.z))
                });
                let length = child_offset
                    .map(simd_length)
                    .map_or(0.25, |child_length| child_length.max(0.15));
                let radius = (length * 0.2).clamp(0.04, 0.15);
                let body = scene.create_entity();
                scene.set_component(
                    SceneNameComponent::new(format!("{root_name} {bone_name} Body")),
                    body,
                );
                scene.set_component(SceneKindComponent::new("Ragdoll Body"), body);
                scene.set_local_transform(LocalTransform::new(node_world[node_slot_index]), body);
                scene.set_parent(Some(root), body);
                let rigid_body = RigidBody::new(RigidBodyOptions {
                    motion_type: RigidBodyMotionType::Kinematic,
                    mass: length.max(0.25),
                    gravity_scale: 1.0,
                    allow_sleep: true,
                    ..RigidBodyOptions::default()
                });
                scene.set_component(rigid_body, body);
                let collider = match child_offset {
                    Some(offset) if simd_length_squared(offset) > 0.0001 => {
                        let direction = diffuse_math::simd::simd_compat::simd_normalize(offset);
                        let rotation = ragdoll_rotation_from_y(direction);
                        Collider::with_shapes(vec![ColliderShapeInstance::with_transform(
                            ColliderShape::Capsule {
                                radius,
                                half_height: (length * 0.5 - radius).max(0.01),
                                center: Float3::ZERO,
                            },
                            offset * 0.5,
                            rotation.vector,
                            Float3::ONE,
                        )])
                    }
                    _ => Collider::with_shape(ColliderShape::Sphere {
                        radius,
                        center: Float3::ZERO,
                    }),
                };
                scene.set_component(collider, body);
                body_by_node.insert(node_index, body);
                let inverse_bind = skin
                    .inverse_bind_matrices
                    .get(palette_index)
                    .copied()
                    .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
                mappings.push(RagdollBoneMapping::with_mapping(
                    bone_name,
                    palette_index as i64,
                    body,
                    None,
                    simd_inverse(inverse_bind),
                    RigidBodyMotionType::Dynamic,
                    true,
                    1.0,
                ));
            }

            let mut joint_count = 0usize;
            for node_index in skin.joint_node_indices.iter().copied() {
                let Some(body) = body_by_node.get(&node_index).copied() else {
                    continue;
                };
                let Some(node_slot_index) = node_slot(node_index, mesh.nodes.len()) else {
                    continue;
                };
                let Some(parent_index) = mesh.nodes[node_slot_index].parent_index else {
                    continue;
                };
                if !joint_set.contains(&parent_index) {
                    continue;
                }
                let Some(parent_body) = body_by_node.get(&parent_index).copied() else {
                    continue;
                };
                let joint_entity = scene.create_entity();
                let bone_name = mesh.nodes[node_slot_index]
                    .name
                    .clone()
                    .unwrap_or_else(|| format!("bone_{node_index}"));
                scene.set_component(
                    SceneNameComponent::new(format!("{root_name} {bone_name} Joint")),
                    joint_entity,
                );
                scene.set_component(SceneKindComponent::new("Ragdoll Joint"), joint_entity);
                scene.set_local_transform(LocalTransform::IDENTITY, joint_entity);
                scene.set_parent(Some(root), joint_entity);
                let Some(parent_slot) = node_slot(parent_index, node_world.len()) else {
                    continue;
                };
                let current_in_parent =
                    simd_inverse(node_world[parent_slot]) * node_world[node_slot_index];
                let translation = current_in_parent.column(3);
                let pivot_a = Float3::new(translation.x, translation.y, translation.z);
                scene.set_component(
                    PhysicsJoint::new(
                        PhysicsJointConfiguration::Cone(ConeJointConfiguration::new(
                            Float3::new(1.0, 0.0, 0.0),
                            Float3::new(1.0, 0.0, 0.0),
                            0.65,
                            -0.35,
                            0.35,
                            Default::default(),
                        )),
                        parent_body,
                        body,
                        pivot_a,
                        Float3::ZERO,
                        true,
                        PhysicsJoint::DEFAULT_BREAK_LIMIT,
                        PhysicsJoint::DEFAULT_BREAK_LIMIT,
                    ),
                    joint_entity,
                );
                if let Some(mapping) = mappings
                    .iter_mut()
                    .find(|mapping| mapping.body_entity == body)
                {
                    mapping.joint_entity = Some(joint_entity);
                }
                joint_count += 1;
            }

            scene.set_component(
                Ragdoll::new(RagdollMode::Animated, 1.0, true, mappings.clone()),
                root,
            );
            scene.propagate_transforms();
            (mappings, joint_count)
        });

        self.notify_revision_changed(true, None);
        EditorRagdollGenerationResult::new(mappings.len(), joint_count, None)
    }
}

fn node_slot(index: i64, count: usize) -> Option<usize> {
    usize::try_from(index).ok().filter(|slot| *slot < count)
}

fn node_slot_of(index: i64, nodes: &[MeshNode]) -> Option<usize> {
    node_slot(index, nodes.len())
}

fn ragdoll_node_world_matrices(nodes: &[MeshNode]) -> Vec<Float4x4> {
    fn resolve(
        nodes: &[MeshNode],
        result: &mut [Float4x4],
        resolved: &mut [bool],
        index: usize,
    ) -> Float4x4 {
        if index >= nodes.len() {
            return MATRIX_IDENTITY_FLOAT4X4;
        }
        if resolved[index] {
            return result[index];
        }
        let parent = nodes[index].parent_index.and_then(|parent| {
            node_slot(parent, nodes.len()).map(|slot| resolve(nodes, result, resolved, slot))
        });
        result[index] = parent.unwrap_or(MATRIX_IDENTITY_FLOAT4X4) * nodes[index].local_matrix();
        resolved[index] = true;
        result[index]
    }

    let mut result = vec![MATRIX_IDENTITY_FLOAT4X4; nodes.len()];
    let mut resolved = vec![false; nodes.len()];
    for index in 0..nodes.len() {
        let _ = resolve(nodes, &mut result, &mut resolved, index);
    }
    result
}

fn ragdoll_rotation_from_y(direction: Float3) -> Quatf {
    let y = Float3::new(0.0, 1.0, 0.0);
    let cosine = diffuse_math::simd::simd_compat::simd_dot(y, direction).clamp(-1.0, 1.0);
    if cosine > 0.9999 {
        return Quatf::from_angle_axis(0.0, y);
    }
    if cosine < -0.9999 {
        return Quatf::from_angle_axis(std::f32::consts::PI, Float3::new(1.0, 0.0, 0.0));
    }
    let axis = diffuse_math::simd::simd_compat::simd_normalize(
        diffuse_math::simd::simd_compat::simd_cross(y, direction),
    );
    Quatf::from_angle_axis(cosine.acos(), axis)
}
