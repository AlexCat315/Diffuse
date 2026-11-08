//! Ported from `Engine/Sources/AIRuntime/Semantic/SceneSemanticEncoder.swift`.

use diffuse_math::simd::simd_compat::{Float3, Float4x4, MATRIX_IDENTITY_FLOAT4X4, length};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::media::animation::AnimationPlayer;
use diffuse_scene::media::audio::AudioSource;
use diffuse_scene::physics::collider::{Collider, ColliderShape};
use diffuse_scene::physics::destruction::{Destructible, DestructibleAssetResource};
use diffuse_scene::physics::joints::physics_joint::Constraint;
use diffuse_scene::physics::queries::spatial_queries::MeshColliderGeometryResource;
use diffuse_scene::physics::ragdoll::Ragdoll;
use diffuse_scene::physics::rigid_body::RigidBody;
use diffuse_scene::physics::soft_bodies::cloth::{Cloth, ClothBendType};
use diffuse_scene::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};
use diffuse_scene::physics::vehicles::vehicle::Vehicle;
use diffuse_scene::physics::vehicles::vehicle_controller_configuration::VehicleControllerKind;
use diffuse_scene::physics::vehicles::vehicle_wheel_configuration::VehicleTransmissionMode;
use diffuse_scene::rendering::render_extraction::{
    CameraComponent, LightComponent, LightType, RenderMaterialComponent, RenderMeshComponent,
};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_bootstrap::{SceneKindComponent, SceneNameComponent};
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_script::core::script_component::ScriptComponent;

use crate::semantic::scene_semantic_snapshot::{
    SceneSemanticSnapshot, SceneSemanticSnapshotEntity, SceneSemanticSnapshotScriptBindingRecord,
};

/// Converts a live `SceneRuntime` into a `SceneSemanticSnapshot` for AI planning.
///
/// Reads SceneNameComponent, SceneKindComponent, LocalTransform, LightComponent,
/// CameraComponent, RenderMeshComponent, RigidBody, Collider, and the
/// parent/children hierarchy. Runs synchronously — call before crossing a
/// thread boundary and pass the snapshot value (not the runtime reference) into
/// the worker.
#[derive(Clone, Copy, Debug, Default)]
pub struct SceneSemanticEncoder;

impl SceneSemanticEncoder {
    pub fn new() -> Self {
        Self
    }

    /// `encode(_:selectedEntityID:workspaceMode:localeIdentifier:)` with the
    /// Swift default arguments.
    pub fn encode_with_defaults(&self, scene: &SceneRuntime) -> SceneSemanticSnapshot {
        self.encode(scene, None, None, None)
    }

    pub fn encode(
        &self,
        scene: &SceneRuntime,
        selected_entity_id: Option<u64>,
        workspace_mode: Option<String>,
        locale_identifier: Option<String>,
    ) -> SceneSemanticSnapshot {
        let selected_ref = selected_entity_id.map(|id| format!("scene:{id}"));
        let mut records: Vec<SceneSemanticSnapshotEntity> = Vec::new();

        // The frame resources are immutable for the duration of the encode, so
        // they are cloned once instead of once per entity.
        let ragdoll_states = scene.ragdoll_state_frame().states;
        let vehicle_states = scene.vehicle_state_frame().states;
        let soft_body_states = scene.soft_body_state_frame().states;
        let destruction_sources = scene.destruction_state_frame().sources;
        let mesh_geometry_resource = scene.resource::<MeshColliderGeometryResource>();
        let destructible_asset_resource = scene.resource::<DestructibleAssetResource>();

        for entity in scene.entities() {
            let raw = raw_id(entity);
            let reference = format!("scene:{raw}");

            let name = scene
                .component::<SceneNameComponent>(entity)
                .map(|component| component.value)
                .unwrap_or_else(|| format!("Entity {raw}"));
            let kind = entity_kind(scene, entity);

            let parent_ref = scene
                .parent(entity)
                .map(|parent| format!("scene:{}", raw_id(parent)));
            let child_refs = scene
                .children(entity)
                .into_iter()
                .map(|child| format!("scene:{}", raw_id(child)))
                .collect::<Vec<String>>();

            let mut position: Option<Vec<f32>> = None;
            let mut scale: Option<Vec<f32>> = None;
            let mut euler_degrees: Option<Vec<f32>> = None;
            let mut world_position: Option<Vec<f32>> = None;
            let mut world_euler_degrees: Option<Vec<f32>> = None;
            let mut world_scale: Option<Vec<f32>> = None;
            if let Some(local_transform) = scene.local_transform(entity) {
                let translation = local_transform.translation();
                position = Some(vec![translation.x, translation.y, translation.z]);
                let local_scale = extract_scale(&local_transform.matrix);
                let is_uniform_one = (local_scale.x - 1.0).abs() < 0.0001
                    && (local_scale.y - 1.0).abs() < 0.0001
                    && (local_scale.z - 1.0).abs() < 0.0001;
                if !is_uniform_one {
                    scale = Some(vec![local_scale.x, local_scale.y, local_scale.z]);
                }
                let local_euler = extract_euler_xyz_degrees(&local_transform.matrix);
                let is_zero_rotation = local_euler.x.abs() < 0.01
                    && local_euler.y.abs() < 0.01
                    && local_euler.z.abs() < 0.01;
                if !is_zero_rotation {
                    euler_degrees = Some(vec![local_euler.x, local_euler.y, local_euler.z]);
                }
                let world = world_matrix(scene, entity);
                let world_translation = world.columns[3];
                world_position = Some(vec![
                    world_translation.x,
                    world_translation.y,
                    world_translation.z,
                ]);
                let world_euler = extract_euler_xyz_degrees(&world);
                let is_zero_world_rotation = world_euler.x.abs() < 0.01
                    && world_euler.y.abs() < 0.01
                    && world_euler.z.abs() < 0.01;
                if !is_zero_world_rotation {
                    world_euler_degrees = Some(vec![world_euler.x, world_euler.y, world_euler.z]);
                }
                let cumulative_scale = extract_scale(&world);
                let is_world_uniform_one = (cumulative_scale.x - 1.0).abs() < 0.0001
                    && (cumulative_scale.y - 1.0).abs() < 0.0001
                    && (cumulative_scale.z - 1.0).abs() < 0.0001;
                if !is_world_uniform_one {
                    world_scale = Some(vec![
                        cumulative_scale.x,
                        cumulative_scale.y,
                        cumulative_scale.z,
                    ]);
                }
            }

            let mut components: Vec<String> = Vec::new();
            if scene.has_component::<LocalTransform>(entity) {
                components.push("transform".to_string());
            }
            if scene.has_component::<RenderMeshComponent>(entity) {
                components.push("mesh".to_string());
            }
            if scene.has_component::<LightComponent>(entity) {
                components.push("light".to_string());
            }
            if scene.has_component::<CameraComponent>(entity) {
                components.push("camera".to_string());
            }
            if scene.has_component::<RigidBody>(entity) {
                components.push("rigidbody".to_string());
            }
            if scene.has_component::<Collider>(entity) {
                components.push("collider".to_string());
            }
            if scene.has_component::<AudioSource>(entity) {
                components.push("audio_source".to_string());
            }
            if scene.has_component::<AnimationPlayer>(entity) {
                components.push("animation".to_string());
            }
            if scene.has_component::<ScriptComponent>(entity) {
                components.push("script".to_string());
            }
            if scene.has_component::<Constraint>(entity) {
                components.push("constraint".to_string());
            }
            if scene.has_component::<Ragdoll>(entity) {
                components.push("ragdoll".to_string());
            }
            if scene.has_component::<Vehicle>(entity) {
                components.push("vehicle".to_string());
            }
            if scene.has_component::<SoftBody>(entity) {
                components.push("softbody".to_string());
            }
            if scene.has_component::<Cloth>(entity) {
                components.push("cloth".to_string());
            }
            if scene.has_component::<SoftBodyMesh>(entity) {
                components.push("softbody_mesh".to_string());
            }
            if scene.has_component::<Destructible>(entity) {
                components.push("destructible".to_string());
            }

            let mut light_type: Option<String> = None;
            let mut light_intensity: Option<f32> = None;
            let mut light_color: Option<Vec<f32>> = None;
            let mut light_range: Option<f32> = None;
            let mut light_spot_inner: Option<f32> = None;
            let mut light_spot_outer: Option<f32> = None;
            let mut light_cast_shadows: Option<bool> = None;
            if let Some(light) = scene.component::<LightComponent>(entity) {
                light_type = Some(light.light_type.raw_value().to_string());
                light_intensity = Some(light.intensity);
                light_color = Some(vec![light.color.x, light.color.y, light.color.z]);
                light_range = Some(light.range);
                if light.light_type == LightType::Spot {
                    light_spot_inner = Some(light.spot_inner_angle_degrees);
                    light_spot_outer = Some(light.spot_outer_angle_degrees);
                }
                if light.cast_shadows {
                    light_cast_shadows = Some(true);
                }
            }

            let mut camera_fov_y_degrees: Option<f32> = None;
            let mut camera_is_active: Option<bool> = None;
            if let Some(camera) = scene.component::<CameraComponent>(entity) {
                camera_fov_y_degrees =
                    Some(camera.fov_y_radians * (180.0f32 / std::f32::consts::PI));
                camera_is_active = Some(camera.is_active);
            }

            let mut mesh_color: Option<Vec<f32>> = None;
            if let Some(mesh) = scene.component::<RenderMeshComponent>(entity) {
                let color = mesh.color_tint;
                let is_white = (color.x - 1.0).abs() < 0.001
                    && (color.y - 1.0).abs() < 0.001
                    && (color.z - 1.0).abs() < 0.001;
                if !is_white {
                    mesh_color = Some(vec![color.x, color.y, color.z]);
                }
            }

            let mut material_base_color: Option<Vec<f32>> = None;
            let mut material_metallic: Option<f32> = None;
            let mut material_roughness: Option<f32> = None;
            let mut material_emissive: Option<Vec<f32>> = None;
            if let Some(material) = scene.component::<RenderMaterialComponent>(entity) {
                let base_color = material.base_color_factor;
                let is_white_opaque = (base_color.x - 1.0).abs() < 0.001
                    && (base_color.y - 1.0).abs() < 0.001
                    && (base_color.z - 1.0).abs() < 0.001
                    && (base_color.w - 1.0).abs() < 0.001;
                if !is_white_opaque {
                    material_base_color =
                        Some(vec![base_color.x, base_color.y, base_color.z, base_color.w]);
                }
                if material.metallic_factor > 0.001 {
                    material_metallic = Some(material.metallic_factor);
                }
                if (material.roughness_factor - 1.0).abs() > 0.001 {
                    material_roughness = Some(material.roughness_factor);
                }
                let emissive = material.emissive_factor;
                if emissive.x > 0.001 || emissive.y > 0.001 || emissive.z > 0.001 {
                    material_emissive = Some(vec![emissive.x, emissive.y, emissive.z]);
                }
            }

            let mut rigid_body_motion_type: Option<String> = None;
            let mut rigid_body_mass: Option<f32> = None;
            let mut rigid_body_gravity_scale: Option<f32> = None;
            let mut rigid_body_allow_sleep: Option<bool> = None;
            if let Some(rigid_body) = scene.component::<RigidBody>(entity) {
                rigid_body_motion_type = Some(rigid_body.motion_type.raw_value().to_string());
                rigid_body_mass = Some(rigid_body.mass);
                rigid_body_gravity_scale = Some(rigid_body.gravity_scale);
                rigid_body_allow_sleep = Some(rigid_body.allow_sleep);
            }

            let mut collider_shape: Option<String> = None;
            let mut collider_is_trigger: Option<bool> = None;
            let mut collider_friction: Option<f32> = None;
            let mut collider_restitution: Option<f32> = None;
            let mut collider_density: Option<f32> = None;
            let mut collider_layer_id: Option<i64> = None;
            let mut collider_layer_mask: Option<i64> = None;
            let mut collider_box_half_extents: Option<Vec<f32>> = None;
            let mut collider_sphere_radius: Option<f32> = None;
            let mut collider_capsule_radius: Option<f32> = None;
            let mut collider_capsule_half_height: Option<f32> = None;
            if let Some(collider) = scene.component::<Collider>(entity) {
                let shape = collider.shape();
                collider_shape = Some(shape.kind().raw_value().to_string());
                match shape {
                    ColliderShape::Box { half_extents, .. } => {
                        collider_box_half_extents =
                            Some(vec![half_extents.x, half_extents.y, half_extents.z]);
                    }
                    ColliderShape::Sphere { radius, .. } => {
                        collider_sphere_radius = Some(radius);
                    }
                    ColliderShape::Capsule {
                        radius,
                        half_height,
                        ..
                    } => {
                        collider_capsule_radius = Some(radius);
                        collider_capsule_half_height = Some(half_height);
                    }
                    _ => {}
                }
                collider_is_trigger = Some(collider.is_trigger);
                collider_friction = Some(collider.material.friction);
                collider_restitution = Some(collider.material.restitution);
                collider_density = Some(collider.material.density);
                collider_layer_id = Some(i64::from(collider.layer_id));
                collider_layer_mask = Some(i64::from(collider.layer_mask));
            }

            let mut audio_clip: Option<String> = None;
            let mut audio_volume: Option<f32> = None;
            let mut audio_loop: Option<bool> = None;
            let mut audio_play_on_awake: Option<bool> = None;
            let mut audio_pitch: Option<f32> = None;
            let mut audio_spatial_blend: Option<f32> = None;
            if let Some(source) = scene.component::<AudioSource>(entity) {
                audio_clip = if source.clip_name.is_empty() {
                    None
                } else {
                    Some(source.clip_name.clone())
                };
                audio_volume = Some(source.volume);
                audio_loop = Some(source.loop_);
                audio_play_on_awake = Some(source.play_on_awake);
                if (source.pitch - 1.0).abs() > 0.0001 {
                    audio_pitch = Some(source.pitch);
                }
                if source.spatial_blend > 0.0001 {
                    audio_spatial_blend = Some(source.spatial_blend);
                }
            }

            let mut mesh_is_visible: Option<bool> = None;
            if let Some(mesh) = scene.component::<RenderMeshComponent>(entity)
                && !mesh.is_visible
            {
                mesh_is_visible = Some(false);
            }

            let mut animation_clip: Option<String> = None;
            let mut animation_speed: Option<f32> = None;
            let mut animation_loop: Option<bool> = None;
            let mut animation_is_playing: Option<bool> = None;
            if let Some(animation) = scene.component::<AnimationPlayer>(entity) {
                animation_clip = animation.clip_name.clone();
                if (animation.speed - 1.0).abs() > 0.0001 {
                    animation_speed = Some(animation.speed);
                }
                animation_loop = Some(animation.loop_);
                animation_is_playing = Some(animation.is_playing);
            }

            let mut script_bindings: Option<Vec<SceneSemanticSnapshotScriptBindingRecord>> = None;
            if let Some(script) = scene.component::<ScriptComponent>(entity)
                && !script.bindings.is_empty()
            {
                script_bindings = Some(
                    script
                        .bindings
                        .iter()
                        .map(|binding| {
                            SceneSemanticSnapshotScriptBindingRecord::new(
                                binding.script.raw_value,
                                binding.identifier.clone(),
                                binding.is_enabled,
                                binding.parameters_json.clone(),
                            )
                        })
                        .collect(),
                );
            }

            let constraint_enabled = scene
                .component::<Constraint>(entity)
                .map(|constraint| constraint.is_enabled);

            let ragdoll = scene.component::<Ragdoll>(entity);
            let ragdoll_state = ragdoll_states.get(&entity);
            let vehicle = scene.component::<Vehicle>(entity);
            let vehicle_state = vehicle_states.get(&entity);
            let soft_body = scene.component::<SoftBody>(entity);
            let cloth = scene.component::<Cloth>(entity);
            let soft_body_mesh = scene.component::<SoftBodyMesh>(entity);
            let soft_body_mesh_geometry = soft_body_mesh.as_ref().and_then(|mesh| {
                mesh_geometry_resource
                    .as_ref()?
                    .geometry_for(mesh.resource_id.as_deref())
            });
            let soft_body_state = soft_body_states.get(&entity);
            let destructible = scene.component::<Destructible>(entity);
            let destructible_asset = destructible.as_ref().and_then(|component| {
                destructible_asset_resource
                    .as_ref()?
                    .asset(&component.asset_resource_id)
            });
            let destruction_state = destruction_sources.get(&entity);

            records.push(SceneSemanticSnapshotEntity {
                id: reference.clone(),
                name,
                kind,
                parent_ref,
                child_refs,
                is_selected: selected_ref.as_ref() == Some(&reference),
                position,
                scale,
                euler_degrees,
                world_position,
                world_euler_degrees,
                world_scale,
                components,
                light_type,
                light_intensity,
                light_color,
                light_range,
                light_spot_inner,
                light_spot_outer,
                light_cast_shadows,
                camera_fov_y_degrees,
                camera_is_active,
                mesh_color,
                material_base_color,
                material_metallic,
                material_roughness,
                material_emissive,
                rigid_body_motion_type,
                rigid_body_mass,
                rigid_body_gravity_scale,
                rigid_body_allow_sleep,
                collider_shape,
                collider_box_half_extents,
                collider_sphere_radius,
                collider_capsule_radius,
                collider_capsule_half_height,
                collider_is_trigger,
                collider_friction,
                collider_restitution,
                collider_density,
                collider_layer_id,
                collider_layer_mask,
                audio_clip,
                audio_volume,
                audio_loop,
                audio_play_on_awake,
                audio_pitch,
                audio_spatial_blend,
                mesh_is_visible,
                animation_clip,
                animation_speed,
                animation_loop,
                animation_is_playing,
                script_bindings,
                constraint_enabled,
                ragdoll_mode: ragdoll
                    .as_ref()
                    .map(|value| value.mode.raw_value().to_string()),
                ragdoll_blend_weight: ragdoll.as_ref().map(|value| value.blend_weight),
                ragdoll_bone_count: ragdoll.as_ref().map(|value| value.bones.len() as i64),
                ragdoll_simulated_bone_count: ragdoll_state.map(|state| {
                    state.bones.iter().filter(|bone| bone.is_simulated).count() as i64
                }),
                ragdoll_is_enabled: ragdoll.as_ref().map(|value| value.is_enabled),
                vehicle_is_enabled: vehicle.as_ref().map(|value| value.is_enabled),
                vehicle_controller_kind: vehicle
                    .as_ref()
                    .map(|value| vehicle_controller_kind_name(value.controller.kind()).to_string()),
                vehicle_wheel_count: vehicle.as_ref().map(|value| value.wheels.len() as i64),
                vehicle_differential_count: vehicle
                    .as_ref()
                    .map(|value| value.differentials.len() as i64),
                vehicle_transmission_mode: vehicle.as_ref().map(|value| {
                    if value.transmission.mode == VehicleTransmissionMode::Automatic {
                        "automatic".to_string()
                    } else {
                        "manual".to_string()
                    }
                }),
                vehicle_max_torque: vehicle.as_ref().map(|value| value.engine.max_torque),
                vehicle_forward_speed: vehicle_state.map(|state| state.forward_speed),
                vehicle_engine_rpm: vehicle_state.map(|state| state.engine_rpm),
                vehicle_current_gear: vehicle_state.map(|state| state.current_gear),
                vehicle_wheel_contact_count: vehicle_state.map(|state| {
                    state
                        .wheels
                        .iter()
                        .filter(|wheel| wheel.has_contact)
                        .count() as i64
                }),
                soft_body_is_enabled: soft_body.as_ref().map(|value| value.is_enabled),
                soft_body_pressure: soft_body.as_ref().map(|value| value.pressure),
                soft_body_linear_damping: soft_body.as_ref().map(|value| value.linear_damping),
                soft_body_vertex_radius: soft_body.as_ref().map(|value| value.vertex_radius),
                soft_body_is_sleeping: soft_body_state.map(|state| state.is_sleeping),
                soft_body_deformed_vertex_count: soft_body_state
                    .map(|state| state.positions.len() as i64),
                cloth_grid_size_x: cloth.as_ref().map(|value| value.grid_size_x),
                cloth_grid_size_z: cloth.as_ref().map(|value| value.grid_size_z),
                cloth_spacing: cloth.as_ref().map(|value| value.spacing),
                cloth_fixed_vertex_count: cloth
                    .as_ref()
                    .map(|value| value.fixed_vertex_indices.len() as i64),
                cloth_bend_type: cloth
                    .as_ref()
                    .map(|value| bend_type_name(value.bend_type).to_string()),
                soft_body_topology_kind: if cloth.is_some() {
                    Some("cloth".to_string())
                } else if soft_body_mesh.is_some() {
                    Some(
                        if soft_body_mesh_geometry
                            .map(|geometry| geometry.tetrahedron_count())
                            .unwrap_or(0)
                            > 0
                        {
                            "volume_mesh"
                        } else {
                            "surface_mesh"
                        }
                        .to_string(),
                    )
                } else {
                    None
                },
                soft_body_mesh_resource_id: soft_body_mesh
                    .as_ref()
                    .and_then(|value| value.resource_id.clone()),
                soft_body_mesh_vertex_count: soft_body_mesh_geometry
                    .map(|geometry| geometry.positions.len() as i64),
                soft_body_mesh_triangle_count: soft_body_mesh_geometry
                    .map(|geometry| geometry.triangle_count() as i64),
                soft_body_mesh_tetrahedron_count: soft_body_mesh_geometry
                    .map(|geometry| geometry.tetrahedron_count() as i64),
                soft_body_mesh_fixed_vertex_count: soft_body_mesh
                    .as_ref()
                    .map(|value| value.fixed_vertex_indices.len() as i64),
                soft_body_mesh_bend_type: soft_body_mesh
                    .as_ref()
                    .map(|value| bend_type_name(value.bend_type).to_string()),
                soft_body_mesh_volume_compliance: soft_body_mesh
                    .as_ref()
                    .map(|value| value.volume_compliance),
                soft_body_mesh_geometry_revision: soft_body_mesh_geometry
                    .map(|geometry| geometry.revision),
                destructible_asset_resource_id: destructible
                    .as_ref()
                    .map(|value| value.asset_resource_id.clone()),
                destructible_is_enabled: destructible.as_ref().map(|value| value.is_enabled),
                destructible_damage_threshold: destructible
                    .as_ref()
                    .map(|value| value.damage_threshold),
                destructible_impulse_threshold: destructible
                    .as_ref()
                    .map(|value| value.impulse_threshold),
                destructible_fragment_budget: destructible
                    .as_ref()
                    .map(|value| value.fragment_budget),
                destructible_maximum_fragment_lifetime_seconds: destructible
                    .as_ref()
                    .map(|value| value.maximum_fragment_lifetime_seconds),
                destructible_sleeping_recycle_delay_seconds: destructible
                    .as_ref()
                    .map(|value| value.sleeping_recycle_delay_seconds),
                destructible_separation_impulse: destructible
                    .as_ref()
                    .map(|value| value.separation_impulse),
                destructible_asset_revision: destructible_asset.map(|asset| asset.revision),
                destructible_asset_fragment_count: destructible_asset
                    .map(|asset| asset.fragments.len() as i64),
                destructible_asset_connection_count: destructible_asset
                    .map(|asset| asset.connections.len() as i64),
                destructible_has_fractured: destruction_state.map(|state| state.has_fractured),
                destructible_is_fully_fractured: destruction_state
                    .map(|state| state.is_fully_fractured),
                destructible_active_fragment_count: destruction_state
                    .map(|state| state.active_fragment_entities.len() as i64),
                destructible_broken_connection_count: destruction_state
                    .map(|state| state.broken_connection_ids.len() as i64),
                destructible_released_fragment_count: destruction_state
                    .map(|state| state.released_fragment_ids.len() as i64),
                destructible_retained_fragment_count: destruction_state
                    .map(|state| state.retained_fragment_ids.len() as i64),
            });
        }

        let snapshot = scene.snapshot();
        SceneSemanticSnapshot::new(snapshot.revision, snapshot.entity_count as i64, records)
            .with_selected_ref(selected_ref)
            .with_workspace_mode(workspace_mode)
            .with_locale_identifier(locale_identifier)
    }
}

fn entity_kind(scene: &SceneRuntime, entity: EntityID) -> String {
    if let Some(kind) = scene.component::<SceneKindComponent>(entity) {
        return kind.value;
    }
    if scene.has_component::<CameraComponent>(entity) {
        return "Camera".to_string();
    }
    if let Some(light) = scene.component::<LightComponent>(entity) {
        return match light.light_type {
            LightType::Directional => "Directional Light",
            LightType::Point => "Point Light",
            LightType::Spot => "Spot Light",
        }
        .to_string();
    }
    if scene.has_component::<Destructible>(entity) {
        return "Destructible".to_string();
    }
    if scene.has_component::<RenderMeshComponent>(entity) {
        return "Static Mesh".to_string();
    }
    if !scene.children(entity).is_empty() {
        return "Group".to_string();
    }
    "Entity".to_string()
}

fn raw_id(entity: EntityID) -> u64 {
    entity.raw_value()
}

/// Extracts XYZ intrinsic Euler angles in degrees from a TRS matrix.
/// Returns zero when the rotation is identity or near-identity.
fn extract_euler_xyz_degrees(matrix: &Float4x4) -> Float3 {
    let scale = extract_scale(matrix);
    if !(scale.x > 0.0 && scale.y > 0.0 && scale.z > 0.0) {
        return Float3::ZERO;
    }
    // Normalised rotation column elements (row-major R[row][col] = columns[col][row]).
    let r02 = matrix.columns[2].x / scale.z; // sin(y)
    let r12 = matrix.columns[2].y / scale.z; // -sin(x)cos(y)
    let r22 = matrix.columns[2].z / scale.z; // cos(x)cos(y)
    let r01 = matrix.columns[1].x / scale.y; // -cos(y)sin(z)
    let r00 = matrix.columns[0].x / scale.x; // cos(y)cos(z)
    let sin_beta = r02.clamp(-1.0, 1.0);
    let beta = sin_beta.asin();
    let to_degrees = 180.0f32 / std::f32::consts::PI;
    if sin_beta.abs() < 0.9999 {
        let alpha = (-r12).atan2(r22);
        let gamma = (-r01).atan2(r00);
        Float3::new(alpha * to_degrees, beta * to_degrees, gamma * to_degrees)
    } else {
        let r10 = matrix.columns[0].y / scale.x; // sin(x+z) when beta = +90°
        let r11 = matrix.columns[1].y / scale.y; // cos(x+z) when beta = +90°
        let alpha = r10.atan2(r11);
        Float3::new(alpha * to_degrees, beta * to_degrees, 0.0)
    }
}

fn extract_scale(matrix: &Float4x4) -> Float3 {
    Float3::new(
        length(Float3::new(
            matrix.columns[0].x,
            matrix.columns[0].y,
            matrix.columns[0].z,
        )),
        length(Float3::new(
            matrix.columns[1].x,
            matrix.columns[1].y,
            matrix.columns[1].z,
        )),
        length(Float3::new(
            matrix.columns[2].x,
            matrix.columns[2].y,
            matrix.columns[2].z,
        )),
    )
}

/// Recursively computes the world-space transform by walking up the parent chain.
fn world_matrix(scene: &SceneRuntime, entity: EntityID) -> Float4x4 {
    let local = scene
        .local_transform(entity)
        .map(|transform| transform.matrix)
        .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
    let Some(parent) = scene.parent(entity) else {
        return local;
    };
    world_matrix(scene, parent) * local
}

/// Swift `String(describing:)` for a `VehicleControllerKind` case.
fn vehicle_controller_kind_name(kind: VehicleControllerKind) -> &'static str {
    match kind {
        VehicleControllerKind::Wheeled => "wheeled",
        VehicleControllerKind::Tracked => "tracked",
        VehicleControllerKind::Motorcycle => "motorcycle",
    }
}

/// Swift `String(describing:)` for a `ClothBendType` case.
fn bend_type_name(bend_type: ClothBendType) -> &'static str {
    match bend_type {
        ClothBendType::None => "none",
        ClothBendType::Distance => "distance",
        ClothBendType::Dihedral => "dihedral",
    }
}
