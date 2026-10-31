//! The destruction system: fracture application, fragment spawning and recycling.
//!
//! Ported from `Engine/Sources/SceneRuntime/Physics/DestructionRuntime.swift`.
//!
//! Ordering is load-bearing throughout and is preserved exactly, because these
//! paths feed the deterministic state hash:
//!
//! - Commands are processed in `(entity.rawValue, original offset)` order, so two
//!   commands against one entity keep their submission order.
//! - Contact-driven commands are sorted by `(entity, otherEntity, subShapeID)`.
//! - Every fragment / connection list is sorted by ID *before* budget truncation,
//!   so the truncation is stable across runs.
//! - `source_state` is written back into `runtime.sources` *before* the early
//!   returns that can follow. That matters: broken connection IDs survive a
//!   command that decides not to fracture.
//!
//! Swift's `inout` world/runtime/frame triple becomes explicit `&mut` parameters.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_math::simd::simd_compat::{
    Float3, Float4x4, MATRIX_IDENTITY_FLOAT4X4, simd_cross, simd_dot, simd_length,
    simd_length_squared,
};

use crate::entity_id::EntityID;
use crate::physics::collider::{Collider, ColliderShape, ColliderShapeInstance};
use crate::physics::destruction::{
    Destructible, DestructibleAsset, DestructibleAssetResource, DestructibleConnectionAsset,
    DestructibleFragment, DestructibleFragmentAsset, DestructibleRetainedFragment,
    DestructionCause, DestructionCommand, DestructionCommandFrameResource, DestructionEvent,
    DestructionEventFrameResource, DestructionFailureEvent, DestructionFailureReason,
    DestructionRecycleEvent, DestructionRecycleReason, DestructionRuntimeSourceState,
    DestructionRuntimeStateResource, DestructionSettingsResource, DestructionSourceState,
    DestructionStateFrameResource,
};
use crate::physics::physics_events::{PhysicsContactEvent, PhysicsContactEventKind};
use crate::physics::queries::spatial_queries::MeshColliderGeometryResource;
use crate::physics::rigid_body::{RigidBody, RigidBodyMassMode, RigidBodyMotionType};
use crate::rendering::render_extraction::{RenderMaterialComponent, RenderMeshComponent};
use crate::runtime_world::{LocalTransform, RuntimeWorld};
use crate::scene_bootstrap::SceneNameComponent;

/// `advanceDestructionPrePhysics(in:deltaTimeSeconds:frame:)`.
pub fn advance_destruction_pre_physics(
    world: &mut RuntimeWorld,
    delta_time_seconds: f64,
    frame: &mut DestructionEventFrameResource,
) {
    let mut runtime = world
        .resource::<DestructionRuntimeStateResource>()
        .unwrap_or_default();
    // Swift `max(0, deltaTimeSeconds)` also maps NaN to 0.
    runtime.elapsed_seconds += if delta_time_seconds >= 0.0 {
        delta_time_seconds
    } else {
        0.0
    };
    recycle_destruction_fragments(world, &mut runtime, frame);

    let commands = world
        .resource::<DestructionCommandFrameResource>()
        .map(|resource| resource.commands)
        .unwrap_or_default();
    let mut indexed: Vec<(usize, DestructionCommand)> = commands.into_iter().enumerate().collect();
    indexed.sort_by_key(|(offset, command)| (command.entity.raw_value(), *offset));

    let mut changed_hierarchy = false;
    for (_, command) in indexed {
        changed_hierarchy |= apply_destruction(command, false, world, &mut runtime, frame);
    }
    if changed_hierarchy {
        world.propagate_transforms_default();
    }
    publish_destruction_state(world, &runtime);
    world.set_derived_resource(runtime);
    world.set_derived_resource(frame.clone());
}

/// `applyDestructionContacts(_:in:frame:)`.
pub fn apply_destruction_contacts(
    contacts: &[PhysicsContactEvent],
    world: &mut RuntimeWorld,
    frame: &mut DestructionEventFrameResource,
) {
    let mut runtime = world
        .resource::<DestructionRuntimeStateResource>()
        .unwrap_or_default();

    struct ContactCommand {
        command: DestructionCommand,
        other_entity: EntityID,
        sub_shape_id: u32,
    }

    let mut commands: Vec<ContactCommand> = Vec::with_capacity(contacts.len() * 2);
    for contact in contacts {
        // Swift filters on `contact.impulse > 0`, which is false for NaN; keep that
        // exact predicate rather than `<=`, which would admit NaN.
        #[allow(clippy::neg_cmp_op_on_partial_ord)]
        let is_positive_impulse = contact.impulse > 0.0;
        if contact.kind == PhysicsContactEventKind::Ended || !is_positive_impulse {
            continue;
        }
        let normal = safe_normalized(contact.normal, contact.relative_velocity);
        if world.component::<Destructible>(contact.entity_a).is_some() {
            commands.push(ContactCommand {
                command: DestructionCommand::new(
                    contact.entity_a,
                    0.0,
                    -normal * contact.impulse,
                    Some(contact.position),
                    false,
                ),
                other_entity: contact.entity_b,
                sub_shape_id: contact.sub_shape_id_a,
            });
        }
        if world.component::<Destructible>(contact.entity_b).is_some() {
            commands.push(ContactCommand {
                command: DestructionCommand::new(
                    contact.entity_b,
                    0.0,
                    normal * contact.impulse,
                    Some(contact.position),
                    false,
                ),
                other_entity: contact.entity_a,
                sub_shape_id: contact.sub_shape_id_b,
            });
        }
    }
    commands.sort_by_key(|candidate| {
        (
            candidate.command.entity.raw_value(),
            candidate.other_entity.raw_value(),
            candidate.sub_shape_id,
        )
    });

    let mut changed_hierarchy = false;
    for candidate in commands {
        changed_hierarchy |= apply_destruction(candidate.command, true, world, &mut runtime, frame);
    }
    if changed_hierarchy {
        world.propagate_transforms_default();
    }
    publish_destruction_state(world, &runtime);
    world.set_derived_resource(runtime);
    world.set_derived_resource(frame.clone());
}

/// `applyDestruction(_:contactDriven:in:runtime:frame:)` — returns whether the
/// hierarchy changed, so the caller knows to propagate transforms.
fn apply_destruction(
    command: DestructionCommand,
    contact_driven: bool,
    world: &mut RuntimeWorld,
    runtime: &mut DestructionRuntimeStateResource,
    frame: &mut DestructionEventFrameResource,
) -> bool {
    if !world.contains(command.entity) {
        return false;
    }
    let Some(destructible) = world.component::<Destructible>(command.entity) else {
        return false;
    };
    if !destructible.is_enabled {
        return false;
    }
    let mut source_state = runtime
        .sources
        .get(&command.entity)
        .cloned()
        .unwrap_or_default();
    if source_state.is_fully_fractured {
        return false;
    }

    if !is_valid_destruction_command(&command) {
        append_failure(
            DestructionFailureEvent::new(
                command.entity,
                DestructionFailureReason::InvalidCommand,
                "Destruction command contains a non-finite or negative value",
            ),
            world,
            frame,
        );
        return false;
    }
    if !is_valid_destructible_configuration(&destructible) {
        append_failure(
            DestructionFailureEvent::new(
                command.entity,
                DestructionFailureReason::InvalidConfiguration,
                "Destructible configuration contains an invalid value",
            ),
            world,
            frame,
        );
        return false;
    }

    let Some(asset) = world
        .resource::<DestructibleAssetResource>()
        .and_then(|resource| resource.asset(&destructible.asset_resource_id).cloned())
    else {
        append_failure(
            DestructionFailureEvent::new(
                command.entity,
                DestructionFailureReason::MissingAsset,
                format!(
                    "Missing destructible asset '{}'",
                    destructible.asset_resource_id
                ),
            ),
            world,
            frame,
        );
        return false;
    };
    if let Some(invalid_reason) = validate_destructible_asset(&asset, world) {
        append_failure(
            DestructionFailureEvent::new(
                command.entity,
                DestructionFailureReason::InvalidAsset,
                invalid_reason,
            ),
            world,
            frame,
        );
        return false;
    }

    // `min(Float.greatestFiniteMagnitude, a + b)` saturates rather than reaching inf.
    source_state.accumulated_damage =
        (source_state.accumulated_damage + command.damage).min(f32::MAX);
    let impulse_magnitude = simd_length(command.impulse);
    let source_transform = world
        .world_transform(command.entity)
        .map(|transform| transform.matrix)
        .or_else(|| {
            world
                .local_transform(command.entity)
                .map(|transform| transform.matrix)
        })
        .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);

    let mut eligible_connections: Vec<DestructibleConnectionAsset> = asset
        .connections
        .iter()
        .filter(|connection| {
            if source_state
                .broken_connection_ids
                .contains(&connection.connection_id)
            {
                return false;
            }
            let damage_threshold = if connection.damage_threshold > 0.0 {
                connection.damage_threshold
            } else {
                destructible.damage_threshold
            };
            let impulse_threshold = if connection.impulse_threshold > 0.0 {
                connection.impulse_threshold
            } else {
                destructible.impulse_threshold
            };
            let damage_break =
                damage_threshold > 0.0 && source_state.accumulated_damage >= damage_threshold;
            let impulse_break = impulse_threshold > 0.0 && impulse_magnitude >= impulse_threshold;
            damage_break || impulse_break || command.force_fracture
        })
        .cloned()
        .collect();
    eligible_connections.sort_by_key(|connection| connection.connection_id);

    // A localized hit breaks only the nearest eligible edge unless the command forces.
    let connections_to_break: Vec<DestructibleConnectionAsset> =
        match (command.force_fracture, command.world_point) {
            (false, Some(world_point)) => {
                match nearest_connection(
                    world_point,
                    &eligible_connections,
                    &asset,
                    source_transform,
                ) {
                    Some(nearest) => vec![nearest],
                    None => eligible_connections.clone(),
                }
            }
            _ => eligible_connections.clone(),
        };
    let newly_broken_connection_ids: Vec<u32> = connections_to_break
        .iter()
        .map(|connection| connection.connection_id)
        .collect();
    for connection_id in &newly_broken_connection_ids {
        source_state.broken_connection_ids.insert(*connection_id);
    }
    runtime.sources.insert(command.entity, source_state.clone());

    let damage_exceeded = destructible.damage_threshold > 0.0
        && source_state.accumulated_damage >= destructible.damage_threshold;
    let impulse_exceeded =
        destructible.impulse_threshold > 0.0 && impulse_magnitude >= destructible.impulse_threshold;
    let connection_disconnected = !asset.connections.is_empty()
        && graph_is_disconnected(&asset, &source_state.broken_connection_ids);
    if !(command.force_fracture || damage_exceeded || impulse_exceeded || connection_disconnected) {
        // The edge broke but the graph still holds: report the partial break only.
        if !newly_broken_connection_ids.is_empty() {
            append_event(
                DestructionEvent::new(
                    command.entity,
                    DestructionCause::ConnectionBreak,
                    Vec::new(),
                    Vec::new(),
                    newly_broken_connection_ids,
                    source_state.accumulated_damage,
                    impulse_magnitude,
                    0,
                ),
                world,
                frame,
            );
        }
        return false;
    }

    let source_body = world.component::<RigidBody>(command.entity);
    let source_collider = world.component::<Collider>(command.entity);
    let source_render_mesh = world.component::<RenderMeshComponent>(command.entity);
    let source_material = world.component::<RenderMaterialComponent>(command.entity);
    if connection_disconnected
        && !command.force_fracture
        && !damage_exceeded
        && !impulse_exceeded
        && let Some(changed_hierarchy) = release_detached_islands_if_supported(
            command.entity,
            &command,
            &destructible,
            &asset,
            source_transform,
            source_body.clone(),
            source_collider.clone(),
            source_render_mesh.clone(),
            source_material.clone(),
            impulse_magnitude,
            &newly_broken_connection_ids,
            &mut source_state,
            world,
            runtime,
            frame,
        )
    {
        return changed_hierarchy;
    }

    let settings = world
        .resource::<DestructionSettingsResource>()
        .unwrap_or_default();
    let active_count = world.entities_with::<DestructibleFragment>().len() as i64;
    let global_available = (settings.maximum_active_fragment_count - active_count).max(0);
    let active_source_count = active_fragment_count(command.entity, world);
    let source_available = (destructible.fragment_budget - active_source_count).max(0);
    let mut ordered_fragments: Vec<DestructibleFragmentAsset> = asset
        .fragments
        .iter()
        .filter(|fragment| {
            !source_state
                .released_fragment_ids
                .contains(&fragment.fragment_id)
        })
        .cloned()
        .collect();
    ordered_fragments.sort_by_key(|fragment| fragment.fragment_id);
    let allowed_count = global_available
        .min(source_available)
        .min(ordered_fragments.len() as i64);
    if allowed_count <= 0 {
        append_failure(
            DestructionFailureEvent::new(
                command.entity,
                DestructionFailureReason::FragmentBudgetExhausted,
                "No fragment capacity is available",
            ),
            world,
            frame,
        );
        return false;
    }

    let fragments: Vec<DestructibleFragmentAsset> = ordered_fragments
        .iter()
        .take(allowed_count as usize)
        .cloned()
        .collect();
    let spawned = spawn_destruction_fragments(
        &fragments,
        command.entity,
        source_transform,
        source_body.clone(),
        source_collider.clone(),
        source_material.clone(),
        &destructible,
        &command,
        impulse_magnitude,
        runtime.elapsed_seconds,
        world,
    );

    if !source_state.has_authored_source_snapshot {
        source_state.has_authored_source_snapshot = true;
        source_state.authored_rigid_body = source_body.clone();
        source_state.authored_collider = source_collider.clone();
        source_state.authored_render_mesh = source_render_mesh.clone();
    }
    world.remove_component::<Collider>(command.entity);
    world.remove_component::<RigidBody>(command.entity);
    world.update_component::<RenderMeshComponent>(command.entity, |mesh| {
        mesh.is_visible = false;
    });
    destroy_retained_fragment_proxies(command.entity, world);
    let mut all_connection_ids: Vec<u32> = asset
        .connections
        .iter()
        .map(|connection| connection.connection_id)
        .collect();
    all_connection_ids.sort_unstable();
    for fragment in &ordered_fragments {
        source_state
            .released_fragment_ids
            .insert(fragment.fragment_id);
    }
    source_state.has_fractured = true;
    source_state.is_fully_fractured = true;
    source_state.broken_connection_ids = all_connection_ids.iter().copied().collect();
    runtime.sources.insert(command.entity, source_state.clone());

    let cause = if command.force_fracture {
        DestructionCause::Forced
    } else if connection_disconnected && !damage_exceeded && !impulse_exceeded {
        DestructionCause::ConnectionBreak
    } else if contact_driven || impulse_exceeded {
        DestructionCause::ContactImpulse
    } else {
        DestructionCause::Damage
    };
    append_event(
        DestructionEvent::new(
            command.entity,
            cause,
            spawned.entities,
            spawned.fragment_ids,
            all_connection_ids,
            source_state.accumulated_damage,
            impulse_magnitude,
            ordered_fragments.len() as i64 - fragments.len() as i64,
        ),
        world,
        frame,
    );
    true
}

struct SpawnedDestructionFragments {
    entities: Vec<EntityID>,
    fragment_ids: Vec<u32>,
}

/// Returns `None` when this asset cannot represent a partial fracture without
/// rendering the authored whole mesh over the retained pieces. Callers then use
/// the compatible all-at-once fracture path.
#[allow(clippy::too_many_arguments)]
fn release_detached_islands_if_supported(
    source_entity: EntityID,
    command: &DestructionCommand,
    destructible: &Destructible,
    asset: &DestructibleAsset,
    source_transform: Float4x4,
    source_body: Option<RigidBody>,
    source_collider: Option<Collider>,
    source_render_mesh: Option<RenderMeshComponent>,
    source_material: Option<RenderMaterialComponent>,
    impulse_magnitude: f32,
    command_broken_connection_ids: &[u32],
    source_state: &mut DestructionRuntimeSourceState,
    world: &mut RuntimeWorld,
    runtime: &mut DestructionRuntimeStateResource,
    frame: &mut DestructionEventFrameResource,
) -> Option<bool> {
    let supported = asset.fragments.iter().all(|fragment| {
        fragment.render_mesh.is_some()
            && supports_compound_collider_transform(fragment.local_transform)
    });
    if !supported {
        return None;
    }

    let root_island = connected_root_fragment_ids(asset, &source_state.broken_connection_ids);
    let all_ids: BTreeSet<u32> = asset
        .fragments
        .iter()
        .map(|fragment| fragment.fragment_id)
        .collect();
    let detached_ids: BTreeSet<u32> = all_ids
        .difference(&root_island)
        .copied()
        .filter(|id| !source_state.released_fragment_ids.contains(id))
        .collect();
    if detached_ids.is_empty() {
        return Some(false);
    }

    let settings = world
        .resource::<DestructionSettingsResource>()
        .unwrap_or_default();
    let active_count = world.entities_with::<DestructibleFragment>().len() as i64;
    let global_available = (settings.maximum_active_fragment_count - active_count).max(0);
    let active_source_count = active_fragment_count(source_entity, world);
    let source_available = (destructible.fragment_budget - active_source_count).max(0);
    let mut detached_fragments: Vec<DestructibleFragmentAsset> = asset
        .fragments
        .iter()
        .filter(|fragment| detached_ids.contains(&fragment.fragment_id))
        .cloned()
        .collect();
    detached_fragments.sort_by_key(|fragment| fragment.fragment_id);
    let allowed_count = global_available
        .min(source_available)
        .min(detached_fragments.len() as i64);
    if allowed_count <= 0 {
        append_failure(
            DestructionFailureEvent::new(
                source_entity,
                DestructionFailureReason::FragmentBudgetExhausted,
                "No fragment capacity is available for the detached island",
            ),
            world,
            frame,
        );
        return Some(false);
    }

    if !source_state.has_authored_source_snapshot {
        source_state.has_authored_source_snapshot = true;
        source_state.authored_rigid_body = source_body.clone();
        source_state.authored_collider = source_collider.clone();
        source_state.authored_render_mesh = source_render_mesh.clone();
    }

    let fragments_to_spawn: Vec<DestructibleFragmentAsset> = detached_fragments
        .iter()
        .take(allowed_count as usize)
        .cloned()
        .collect();
    let spawned = spawn_destruction_fragments(
        &fragments_to_spawn,
        source_entity,
        source_transform,
        source_body.clone(),
        source_collider.clone(),
        source_material.clone(),
        destructible,
        command,
        impulse_magnitude,
        runtime.elapsed_seconds,
        world,
    );

    let mut implicit_broken_connection_ids: Vec<u32> = asset
        .connections
        .iter()
        .filter(|connection| {
            (detached_ids.contains(&connection.fragment_a)
                || detached_ids.contains(&connection.fragment_b))
                && !source_state
                    .broken_connection_ids
                    .contains(&connection.connection_id)
        })
        .map(|connection| connection.connection_id)
        .collect();
    implicit_broken_connection_ids.sort_unstable();
    for connection_id in &implicit_broken_connection_ids {
        source_state.broken_connection_ids.insert(*connection_id);
    }
    for fragment_id in &detached_ids {
        source_state.released_fragment_ids.insert(*fragment_id);
    }
    source_state.has_fractured = true;
    source_state.is_fully_fractured = false;

    let mut retained_fragments: Vec<DestructibleFragmentAsset> = asset
        .fragments
        .iter()
        .filter(|fragment| {
            !source_state
                .released_fragment_ids
                .contains(&fragment.fragment_id)
        })
        .cloned()
        .collect();
    retained_fragments.sort_by_key(|fragment| fragment.fragment_id);
    let collider_template = source_collider
        .clone()
        .or_else(|| source_state.authored_collider.clone())
        .unwrap_or_else(|| {
            Collider::with_shape(ColliderShape::Box {
                half_extents: Float3::splat(0.5),
                center: Float3::ZERO,
            })
        });
    world.set_component(
        Collider {
            shapes: retained_fragments
                .iter()
                .map(collider_shape_instance)
                .collect(),
            is_trigger: collider_template.is_trigger,
            layer_id: collider_template.layer_id,
            layer_mask: collider_template.layer_mask,
            material: collider_template.material.clone(),
        },
        source_entity,
    );
    if let Some(mut retained_body) = source_body.clone()
        && retained_body.motion_type == RigidBodyMotionType::Dynamic
    {
        retained_body.mass_mode = RigidBodyMassMode::Mass;
        retained_body.mass = retained_fragments
            .iter()
            .fold(0.0f32, |sum, fragment| sum + fragment.mass);
        retained_body.center_of_mass_override = None;
        retained_body.inertia_diagonal_override = None;
        retained_body.is_sleeping = false;
        world.set_component(retained_body, source_entity);
    }
    world.update_component::<RenderMeshComponent>(source_entity, |mesh| {
        mesh.is_visible = false;
    });
    reconcile_retained_fragment_proxies(
        &retained_fragments,
        source_entity,
        source_material.clone(),
        world,
    );
    runtime.sources.insert(source_entity, source_state.clone());

    let mut broken: BTreeSet<u32> = command_broken_connection_ids.iter().copied().collect();
    broken.extend(implicit_broken_connection_ids);
    append_event(
        DestructionEvent::new(
            source_entity,
            DestructionCause::ConnectionBreak,
            spawned.entities,
            spawned.fragment_ids,
            broken.into_iter().collect(),
            source_state.accumulated_damage,
            impulse_magnitude,
            detached_fragments.len() as i64 - fragments_to_spawn.len() as i64,
        ),
        world,
        frame,
    );
    Some(true)
}

#[allow(clippy::too_many_arguments)]
fn spawn_destruction_fragments(
    fragments: &[DestructibleFragmentAsset],
    source_entity: EntityID,
    source_transform: Float4x4,
    source_body: Option<RigidBody>,
    source_collider: Option<Collider>,
    source_material: Option<RenderMaterialComponent>,
    destructible: &Destructible,
    command: &DestructionCommand,
    impulse_magnitude: f32,
    elapsed_seconds: f64,
    world: &mut RuntimeWorld,
) -> SpawnedDestructionFragments {
    let source_position = Float3::new(
        source_transform.columns[3].x,
        source_transform.columns[3].y,
        source_transform.columns[3].z,
    );
    let total_mass: f32 = fragments
        .iter()
        .fold(0.0f32, |sum, fragment| sum + fragment.mass);
    let mut entities: Vec<EntityID> = Vec::with_capacity(fragments.len());
    let mut fragment_ids: Vec<u32> = Vec::with_capacity(fragments.len());

    for fragment in fragments {
        let entity = world.create_entity();
        let fragment_matrix = source_transform * fragment.local_transform.matrix;
        world.set_local_transform(LocalTransform::new(fragment_matrix), entity);
        world.set_component(
            SceneNameComponent::new(format!("Fragment {}", fragment.fragment_id)),
            entity,
        );
        world.set_component(
            DestructibleFragment::new(
                source_entity,
                fragment.fragment_id,
                elapsed_seconds,
                destructible.maximum_fragment_lifetime_seconds,
                destructible.sleeping_recycle_delay_seconds,
            ),
            entity,
        );
        let mut body = source_body.clone().unwrap_or_default();
        body.motion_type = RigidBodyMotionType::Dynamic;
        body.mass_mode = RigidBodyMassMode::Mass;
        body.mass = fragment.mass;
        body.center_of_mass_override = None;
        body.inertia_diagonal_override = None;
        body.is_sleeping = false;
        body.kinematic_target = None;
        body.accumulated_force = Float3::ZERO;
        body.accumulated_torque = Float3::ZERO;
        body.accumulated_linear_impulse = Float3::ZERO;
        body.accumulated_angular_impulse = Float3::ZERO;
        world.set_component(body, entity);
        world.set_component(
            Collider {
                shapes: vec![ColliderShapeInstance::new(ColliderShape::Convex {
                    resource_id: Some(fragment.collider_resource_id.clone()),
                    center: Float3::ZERO,
                })],
                is_trigger: false,
                layer_id: source_collider
                    .as_ref()
                    .map_or(0, |collider| collider.layer_id),
                layer_mask: source_collider
                    .as_ref()
                    .map_or(u16::MAX, |collider| collider.layer_mask),
                material: source_collider
                    .as_ref()
                    .map(|collider| collider.material.clone())
                    .unwrap_or_default(),
            },
            entity,
        );
        if let Some(render_mesh) = &fragment.render_mesh {
            world.set_component(render_mesh.clone(), entity);
        }
        if let Some(render_material) = fragment
            .render_material
            .clone()
            .or_else(|| source_material.clone())
        {
            world.set_component(render_material, entity);
        }

        if total_mass > 0.0 && impulse_magnitude > 0.0 {
            let share = fragment.mass / total_mass;
            let distributed_impulse = command.impulse * share;
            match command.world_point {
                Some(world_point) => {
                    world.apply_linear_impulse_at(distributed_impulse, world_point, entity, true);
                }
                None => {
                    world.apply_linear_impulse(distributed_impulse, entity, true);
                }
            }
        }
        if destructible.separation_impulse > 0.0 {
            let fragment_position = Float3::new(
                fragment_matrix.columns[3].x,
                fragment_matrix.columns[3].y,
                fragment_matrix.columns[3].z,
            );
            let direction = safe_normalized(
                Float3::new(
                    fragment_position.x - source_position.x,
                    fragment_position.y - source_position.y,
                    fragment_position.z - source_position.z,
                ),
                Float3::ZERO,
            );
            if direction != Float3::ZERO {
                world.apply_linear_impulse(
                    direction * (destructible.separation_impulse * fragment.mass),
                    entity,
                    true,
                );
            }
        }
        entities.push(entity);
        fragment_ids.push(fragment.fragment_id);
    }
    SpawnedDestructionFragments {
        entities,
        fragment_ids,
    }
}

/// `colliderShapeInstance(for:)`.
fn collider_shape_instance(fragment: &DestructibleFragmentAsset) -> ColliderShapeInstance {
    let matrix = fragment.local_transform.matrix;
    let c0 = Float3::new(
        matrix.columns[0].x,
        matrix.columns[0].y,
        matrix.columns[0].z,
    );
    let c1 = Float3::new(
        matrix.columns[1].x,
        matrix.columns[1].y,
        matrix.columns[1].z,
    );
    let c2 = Float3::new(
        matrix.columns[2].x,
        matrix.columns[2].y,
        matrix.columns[2].z,
    );
    let rotation = fragment.local_transform.rotation();
    ColliderShapeInstance::with_transform(
        ColliderShape::Convex {
            resource_id: Some(fragment.collider_resource_id.clone()),
            center: Float3::ZERO,
        },
        fragment.local_transform.translation(),
        rotation.vector,
        Float3::new(simd_length(c0), simd_length(c1), simd_length(c2)),
    )
}

/// `supportsCompoundColliderTransform(_:)` — orthonormal, right-handed basis above
/// epsilon. A skewed or degenerate fragment transform cannot be represented by a
/// compound collider, so the caller must fall back to all-at-once fracture.
fn supports_compound_collider_transform(transform: LocalTransform) -> bool {
    let matrix = transform.matrix;
    let c0 = Float3::new(
        matrix.columns[0].x,
        matrix.columns[0].y,
        matrix.columns[0].z,
    );
    let c1 = Float3::new(
        matrix.columns[1].x,
        matrix.columns[1].y,
        matrix.columns[1].z,
    );
    let c2 = Float3::new(
        matrix.columns[2].x,
        matrix.columns[2].y,
        matrix.columns[2].z,
    );
    let lengths = Float3::new(simd_length(c0), simd_length(c1), simd_length(c2));
    if !(lengths.x > 1.0e-6 && lengths.y > 1.0e-6 && lengths.z > 1.0e-6) {
        return false;
    }
    let n0 = c0 / lengths.x;
    let n1 = c1 / lengths.y;
    let n2 = c2 / lengths.z;
    simd_dot(simd_cross(n0, n1), n2) > 1.0e-5
        && simd_dot(n0, n1).abs() < 1.0e-4
        && simd_dot(n0, n2).abs() < 1.0e-4
        && simd_dot(n1, n2).abs() < 1.0e-4
}

/// `reconcileRetainedFragmentProxies(_:sourceEntity:fallbackMaterial:in:)`.
fn reconcile_retained_fragment_proxies(
    fragments: &[DestructibleFragmentAsset],
    source_entity: EntityID,
    fallback_material: Option<RenderMaterialComponent>,
    world: &mut RuntimeWorld,
) {
    let mut existing_by_fragment_id: BTreeMap<u32, EntityID> = BTreeMap::new();
    let mut proxy_entities = world.entities_with::<DestructibleRetainedFragment>();
    proxy_entities.sort_by_key(|entity| entity.raw_value());
    for entity in proxy_entities {
        let Some(proxy) = world.component::<DestructibleRetainedFragment>(entity) else {
            continue;
        };
        if proxy.source_entity != source_entity {
            continue;
        }
        // Duplicate proxies for one fragment: keep the first, drop the rest.
        match existing_by_fragment_id.entry(proxy.fragment_id) {
            std::collections::btree_map::Entry::Occupied(_) => {
                world.destroy_entity(entity);
            }
            std::collections::btree_map::Entry::Vacant(slot) => {
                slot.insert(entity);
            }
        }
    }
    let retained_ids: BTreeSet<u32> = fragments.iter().map(|f| f.fragment_id).collect();
    let mut retired: Vec<u32> = existing_by_fragment_id
        .keys()
        .copied()
        .filter(|fragment_id| !retained_ids.contains(fragment_id))
        .collect();
    retired.sort_unstable();
    for fragment_id in retired {
        if let Some(entity) = existing_by_fragment_id.remove(&fragment_id) {
            world.destroy_entity(entity);
        }
    }
    for fragment in fragments {
        let entity = match existing_by_fragment_id.get(&fragment.fragment_id) {
            Some(entity) => *entity,
            None => world.create_entity(),
        };
        world.set_local_transform(fragment.local_transform, entity);
        world.set_parent(Some(source_entity), entity);
        world.set_component(
            SceneNameComponent::new(format!("Retained Fragment {}", fragment.fragment_id)),
            entity,
        );
        world.set_component(
            DestructibleRetainedFragment::new(source_entity, fragment.fragment_id),
            entity,
        );
        if let Some(render_mesh) = &fragment.render_mesh {
            world.set_component(render_mesh.clone(), entity);
        }
        if let Some(render_material) = fragment
            .render_material
            .clone()
            .or_else(|| fallback_material.clone())
        {
            world.set_component(render_material, entity);
        }
    }
}

/// `destroyRetainedFragmentProxies(for:in:)`.
fn destroy_retained_fragment_proxies(source_entity: EntityID, world: &mut RuntimeWorld) {
    for entity in world.entities_with::<DestructibleRetainedFragment>() {
        let Some(proxy) = world.component::<DestructibleRetainedFragment>(entity) else {
            continue;
        };
        if proxy.source_entity == source_entity {
            world.destroy_entity(entity);
        }
    }
}

/// `activeFragmentCount(for:in:)`.
fn active_fragment_count(source_entity: EntityID, world: &RuntimeWorld) -> i64 {
    let mut count = 0;
    for entity in world.entities_with::<DestructibleFragment>() {
        if let Some(fragment) = world.component::<DestructibleFragment>(entity)
            && fragment.source_entity == source_entity
        {
            count += 1;
        }
    }
    count
}

/// `recycleDestructionFragments(in:runtime:frame:)`.
fn recycle_destruction_fragments(
    world: &mut RuntimeWorld,
    runtime: &mut DestructionRuntimeStateResource,
    frame: &mut DestructionEventFrameResource,
) {
    let mut proxies = world.entities_with::<DestructibleRetainedFragment>();
    proxies.sort_by_key(|entity| entity.raw_value());
    for entity in proxies {
        let Some(proxy) = world.component::<DestructibleRetainedFragment>(entity) else {
            continue;
        };
        if !world.contains(proxy.source_entity) {
            world.destroy_entity(entity);
        }
    }

    let mut fragment_entities = world.entities_with::<DestructibleFragment>();
    fragment_entities.sort_by_key(|entity| entity.raw_value());
    for entity in fragment_entities {
        let Some(fragment) = world.component::<DestructibleFragment>(entity) else {
            continue;
        };
        let reason: Option<DestructionRecycleReason> = if !world.contains(fragment.source_entity) {
            Some(DestructionRecycleReason::SourceRemoved)
        } else if fragment.maximum_lifetime_seconds > 0.0
            && runtime.elapsed_seconds - fragment.spawned_at_seconds
                >= f64::from(fragment.maximum_lifetime_seconds)
        {
            Some(DestructionRecycleReason::LifetimeExpired)
        } else if fragment.sleeping_recycle_delay_seconds > 0.0
            && world
                .component::<RigidBody>(entity)
                .is_some_and(|body| body.is_sleeping)
        {
            // Start the sleeping clock on first observation, then require the delay.
            let sleeping_since = *runtime
                .sleeping_since_by_fragment
                .entry(entity)
                .or_insert(runtime.elapsed_seconds);
            if runtime.elapsed_seconds - sleeping_since
                >= f64::from(fragment.sleeping_recycle_delay_seconds)
            {
                Some(DestructionRecycleReason::Sleeping)
            } else {
                None
            }
        } else {
            // Awake or the policy is off: forget the sleeping clock.
            runtime.sleeping_since_by_fragment.remove(&entity);
            None
        };
        let Some(reason) = reason else {
            continue;
        };
        if world.destroy_entity(entity) {
            runtime.sleeping_since_by_fragment.remove(&entity);
            append_recycle(
                DestructionRecycleEvent::new(
                    fragment.source_entity,
                    entity,
                    fragment.fragment_id,
                    reason,
                ),
                world,
                frame,
            );
        }
    }

    // Drop bookkeeping for sources that vanished and own no remaining fragment.
    let sources: Vec<EntityID> = runtime.sources.keys().copied().collect();
    for source in sources {
        if world.contains(source) {
            continue;
        }
        let mut still_owned = false;
        for entity in world.entities_with::<DestructibleFragment>() {
            if let Some(fragment) = world.component::<DestructibleFragment>(entity)
                && fragment.source_entity == source
            {
                still_owned = true;
                break;
            }
        }
        if !still_owned {
            runtime.sources.remove(&source);
        }
    }
}

/// `publishDestructionState(in:runtime:)`.
fn publish_destruction_state(world: &mut RuntimeWorld, runtime: &DestructionRuntimeStateResource) {
    let mut fragments_by_source: BTreeMap<EntityID, Vec<(EntityID, u32)>> = BTreeMap::new();
    for entity in world.entities_with::<DestructibleFragment>() {
        let Some(fragment) = world.component::<DestructibleFragment>(entity) else {
            continue;
        };
        fragments_by_source
            .entry(fragment.source_entity)
            .or_default()
            .push((entity, fragment.fragment_id));
    }
    let mut states: BTreeMap<EntityID, DestructionSourceState> = BTreeMap::new();
    for (source, source_state) in &runtime.sources {
        if !world.contains(*source) {
            continue;
        }
        let mut fragments = fragments_by_source.get(source).cloned().unwrap_or_default();
        fragments.sort_by_key(|(entity, fragment_id)| (*fragment_id, entity.raw_value()));
        let retained_fragment_ids: Vec<u32> = if source_state.is_fully_fractured {
            Vec::new()
        } else {
            match world
                .component::<Destructible>(*source)
                .and_then(|destructible| {
                    world
                        .resource::<DestructibleAssetResource>()
                        .and_then(|resource| {
                            resource.asset(&destructible.asset_resource_id).cloned()
                        })
                }) {
                Some(asset) => {
                    let mut ids: Vec<u32> = asset
                        .fragments
                        .iter()
                        .map(|fragment| fragment.fragment_id)
                        .filter(|fragment_id| {
                            !source_state.released_fragment_ids.contains(fragment_id)
                        })
                        .collect();
                    ids.sort_unstable();
                    ids
                }
                // No asset to consult: read the retained proxies directly.
                None => retained_proxy_fragment_ids(*source, world),
            }
        };
        states.insert(
            *source,
            DestructionSourceState::new(
                *source,
                source_state.has_fractured,
                source_state.is_fully_fractured,
                source_state.accumulated_damage,
                source_state.broken_connection_ids.iter().copied().collect(),
                source_state.released_fragment_ids.iter().copied().collect(),
                retained_fragment_ids,
                fragments.iter().map(|(entity, _)| *entity).collect(),
                fragments
                    .iter()
                    .map(|(_, fragment_id)| *fragment_id)
                    .collect(),
            ),
        );
    }
    world.set_derived_resource(DestructionStateFrameResource::new(states));
}

fn retained_proxy_fragment_ids(source: EntityID, world: &RuntimeWorld) -> Vec<u32> {
    let mut ids: Vec<u32> = world
        .entities_with::<DestructibleRetainedFragment>()
        .into_iter()
        .filter_map(|entity| world.component::<DestructibleRetainedFragment>(entity))
        .filter(|proxy| proxy.source_entity == source)
        .map(|proxy| proxy.fragment_id)
        .collect();
    ids.sort_unstable();
    ids
}

/// `validateDestructibleAsset(_:in:)`.
fn validate_destructible_asset(asset: &DestructibleAsset, world: &RuntimeWorld) -> Option<String> {
    if asset.fragments.is_empty() {
        return Some("Destructible asset has no fragments".to_string());
    }
    let fragment_ids: Vec<u32> = asset
        .fragments
        .iter()
        .map(|fragment| fragment.fragment_id)
        .collect();
    let unique_fragments: BTreeSet<u32> = fragment_ids.iter().copied().collect();
    if unique_fragments.len() != fragment_ids.len() {
        return Some("Destructible asset contains duplicate fragment IDs".to_string());
    }
    let connection_ids: Vec<u32> = asset
        .connections
        .iter()
        .map(|connection| connection.connection_id)
        .collect();
    let unique_connections: BTreeSet<u32> = connection_ids.iter().copied().collect();
    if unique_connections.len() != connection_ids.len() {
        return Some("Destructible asset contains duplicate connection IDs".to_string());
    }
    let mut connections = asset.connections.clone();
    connections.sort_by_key(|connection| connection.connection_id);
    for connection in &connections {
        let valid = connection.fragment_a != connection.fragment_b
            && unique_fragments.contains(&connection.fragment_a)
            && unique_fragments.contains(&connection.fragment_b)
            && connection.damage_threshold.is_finite()
            && connection.damage_threshold >= 0.0
            && connection.impulse_threshold.is_finite()
            && connection.impulse_threshold >= 0.0;
        if !valid {
            return Some(format!(
                "Connection {} is invalid",
                connection.connection_id
            ));
        }
    }
    // A mutable asset whose graph is already split cannot be fractured incrementally.
    if !asset.connections.is_empty() && graph_is_disconnected(asset, &BTreeSet::new()) {
        return Some("Destructible asset connection graph is initially disconnected".to_string());
    }
    let geometries = world.resource::<MeshColliderGeometryResource>();
    let mut fragments = asset.fragments.clone();
    fragments.sort_by_key(|fragment| fragment.fragment_id);
    for fragment in &fragments {
        let geometry = geometries
            .as_ref()
            .and_then(|resource| resource.geometry_for(Some(&fragment.collider_resource_id)));
        let valid = fragment.mass.is_finite()
            && fragment.mass > 0.0
            && is_finite_matrix(fragment.local_transform.matrix)
            && !fragment.collider_resource_id.is_empty()
            && geometry
                .is_some_and(|geometry| has_non_degenerate_convex_volume(&geometry.positions));
        if !valid {
            return Some(format!(
                "Fragment {} has no valid convex geometry",
                fragment.fragment_id
            ));
        }
    }
    None
}

/// `nearestConnection(to:among:in:sourceTransform:)` — closest edge midpoint,
/// tie-broken by connection ID.
fn nearest_connection(
    world_point: Float3,
    connections: &[DestructibleConnectionAsset],
    asset: &DestructibleAsset,
    source_transform: Float4x4,
) -> Option<DestructibleConnectionAsset> {
    let mut positions_by_fragment_id: BTreeMap<u32, Float3> = BTreeMap::new();
    for fragment in &asset.fragments {
        let transform = source_transform * fragment.local_transform.matrix;
        positions_by_fragment_id
            .entry(fragment.fragment_id)
            .or_insert(Float3::new(
                transform.columns[3].x,
                transform.columns[3].y,
                transform.columns[3].z,
            ));
    }
    let squared_distance = |connection: &DestructibleConnectionAsset| -> f32 {
        let (Some(position_a), Some(position_b)) = (
            positions_by_fragment_id.get(&connection.fragment_a),
            positions_by_fragment_id.get(&connection.fragment_b),
        ) else {
            return f32::MAX;
        };
        let anchor = Float3::new(
            (position_a.x + position_b.x) * 0.5,
            (position_a.y + position_b.y) * 0.5,
            (position_a.z + position_b.z) * 0.5,
        );
        simd_length_squared(Float3::new(
            world_point.x - anchor.x,
            world_point.y - anchor.y,
            world_point.z - anchor.z,
        ))
    };
    let mut best: Option<&DestructibleConnectionAsset> = None;
    let mut best_distance = f32::NAN;
    for connection in connections {
        let distance = squared_distance(connection);
        let better = match best {
            None => true,
            Some(current) => {
                if distance != best_distance {
                    distance < best_distance
                } else {
                    connection.connection_id < current.connection_id
                }
            }
        };
        if better {
            best = Some(connection);
            best_distance = distance;
        }
    }
    best.cloned()
}

/// `graphIsDisconnected(_:brokenConnections:)`.
fn graph_is_disconnected(asset: &DestructibleAsset, broken_connections: &BTreeSet<u32>) -> bool {
    connected_root_fragment_ids(asset, broken_connections).len() != asset.fragments.len()
}

/// `connectedRootFragmentIDs(in:brokenConnections:)` — breadth-first reachability
/// from the lowest fragment ID. Neighbours are visited in sorted order so the
/// traversal is deterministic.
fn connected_root_fragment_ids(
    asset: &DestructibleAsset,
    broken_connections: &BTreeSet<u32>,
) -> BTreeSet<u32> {
    let Some(root) = asset.fragments.iter().map(|f| f.fragment_id).min() else {
        return BTreeSet::new();
    };
    let mut adjacency: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
    let mut connections = asset.connections.clone();
    connections.sort_by_key(|connection| connection.connection_id);
    for connection in &connections {
        if broken_connections.contains(&connection.connection_id) {
            continue;
        }
        adjacency
            .entry(connection.fragment_a)
            .or_default()
            .push(connection.fragment_b);
        adjacency
            .entry(connection.fragment_b)
            .or_default()
            .push(connection.fragment_a);
    }
    let mut visited: BTreeSet<u32> = BTreeSet::from([root]);
    let mut queue: Vec<u32> = vec![root];
    let mut index: usize = 0;
    while index < queue.len() {
        let current = queue[index];
        index += 1;
        let mut neighbors = adjacency.get(&current).cloned().unwrap_or_default();
        neighbors.sort_unstable();
        for neighbor in neighbors {
            if visited.insert(neighbor) {
                queue.push(neighbor);
            }
        }
    }
    visited
}

/// `isValidDestructibleConfiguration(_:)`.
fn is_valid_destructible_configuration(destructible: &Destructible) -> bool {
    !destructible.asset_resource_id.is_empty()
        && destructible.damage_threshold.is_finite()
        && destructible.damage_threshold >= 0.0
        && destructible.impulse_threshold.is_finite()
        && destructible.impulse_threshold >= 0.0
        && destructible.fragment_budget >= 0
        && destructible.maximum_fragment_lifetime_seconds.is_finite()
        && destructible.maximum_fragment_lifetime_seconds >= 0.0
        && destructible.sleeping_recycle_delay_seconds.is_finite()
        && destructible.sleeping_recycle_delay_seconds >= 0.0
        && destructible.separation_impulse.is_finite()
        && destructible.separation_impulse >= 0.0
}

/// `isValidDestructionCommand(_:)`.
fn is_valid_destruction_command(command: &DestructionCommand) -> bool {
    command.damage.is_finite()
        && command.damage >= 0.0
        && is_finite_vec(command.impulse)
        && command.world_point.is_none_or(is_finite_vec)
}

/// `hasNonDegenerateConvexVolume(_:)` — at least four finite points, two distinct,
/// three non-collinear, and one off the resulting plane.
fn has_non_degenerate_convex_volume(positions: &[Float3]) -> bool {
    if positions.len() < 4 || !positions.iter().all(|position| is_finite_vec(*position)) {
        return false;
    }
    let origin = positions[0];
    let Some(second) = positions
        .iter()
        .skip(1)
        .find(|position| simd_length_squared(**position - origin) > 1.0e-12)
    else {
        return false;
    };
    let first_edge = *second - origin;
    let Some(third) = positions.iter().skip(1).find(|position| {
        simd_length_squared(simd_cross(first_edge, **position - origin)) > 1.0e-12
    }) else {
        return false;
    };
    let normal = simd_cross(first_edge, *third - origin);
    positions
        .iter()
        .skip(1)
        .any(|position| simd_dot(normal, *position - origin).abs() > 1.0e-9)
}

/// `isFinite(_:)` for a vector.
fn is_finite_vec(value: Float3) -> bool {
    value.x.is_finite() && value.y.is_finite() && value.z.is_finite()
}

/// `isFinite(_:)` for a matrix — every lane of every column.
fn is_finite_matrix(matrix: Float4x4) -> bool {
    matrix.columns.iter().all(|column| {
        column.x.is_finite() && column.y.is_finite() && column.z.is_finite() && column.w.is_finite()
    })
}

/// `safeNormalized(_:fallback:)`.
fn safe_normalized(value: Float3, fallback: Float3) -> Float3 {
    let length = simd_length(value);
    if length > 1.0e-6 {
        return value / length;
    }
    let fallback_length = simd_length(fallback);
    if fallback_length > 1.0e-6 {
        return fallback / fallback_length;
    }
    Float3::ZERO
}

/// `appendEvent(_:in:frame:)` — shared budget across all three event lists.
fn append_event(
    event: DestructionEvent,
    world: &RuntimeWorld,
    frame: &mut DestructionEventFrameResource,
) {
    if destruction_event_count(frame) >= destruction_event_limit(world) {
        frame.did_overflow = true;
        return;
    }
    frame.events.push(event);
}

/// `appendFailure(_:in:frame:)`.
fn append_failure(
    event: DestructionFailureEvent,
    world: &RuntimeWorld,
    frame: &mut DestructionEventFrameResource,
) {
    if destruction_event_count(frame) >= destruction_event_limit(world) {
        frame.did_overflow = true;
        return;
    }
    frame.failures.push(event);
}

/// `appendRecycle(_:in:frame:)`.
fn append_recycle(
    event: DestructionRecycleEvent,
    world: &RuntimeWorld,
    frame: &mut DestructionEventFrameResource,
) {
    if destruction_event_count(frame) >= destruction_event_limit(world) {
        frame.did_overflow = true;
        return;
    }
    frame.recycled_fragments.push(event);
}

/// `destructionEventCount(_:)`.
fn destruction_event_count(frame: &DestructionEventFrameResource) -> i64 {
    (frame.events.len() + frame.failures.len() + frame.recycled_fragments.len()) as i64
}

/// `destructionEventLimit(_:)`.
fn destruction_event_limit(world: &RuntimeWorld) -> i64 {
    world
        .resource::<DestructionSettingsResource>()
        .unwrap_or_default()
        .maximum_event_count_per_frame
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;
    use diffuse_math::simd::simd_compat::Float4;

    fn new_world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    #[test]
    fn safe_normalized_falls_back_then_zeroes() {
        assert_eq!(
            safe_normalized(Float3::new(0.0, 3.0, 0.0), Float3::ZERO),
            Float3::new(0.0, 1.0, 0.0)
        );
        // Degenerate primary uses the fallback direction.
        assert_eq!(
            safe_normalized(Float3::ZERO, Float3::new(0.0, 0.0, -2.0)),
            Float3::new(0.0, 0.0, -1.0)
        );
        // Both degenerate: zero.
        assert_eq!(safe_normalized(Float3::ZERO, Float3::ZERO), Float3::ZERO);
    }

    #[test]
    fn convex_volume_rejects_degenerate_point_sets() {
        assert!(!has_non_degenerate_convex_volume(&[]));
        assert!(!has_non_degenerate_convex_volume(&[Float3::ZERO; 4]));
        // Coplanar points have no volume.
        assert!(!has_non_degenerate_convex_volume(&[
            Float3::new(0.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(1.0, 1.0, 0.0),
        ]));
        // A tetrahedron does.
        assert!(has_non_degenerate_convex_volume(&[
            Float3::new(0.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
        ]));
    }

    #[test]
    fn graph_reachability_starts_at_lowest_id_and_respects_broken_edges() {
        let asset = DestructibleAsset::new(
            0,
            vec![
                DestructibleFragmentAsset::with_geometry(1, "a"),
                DestructibleFragmentAsset::with_geometry(2, "b"),
                DestructibleFragmentAsset::with_geometry(3, "c"),
            ],
            vec![
                DestructibleConnectionAsset::unthresholded(10, 1, 2),
                DestructibleConnectionAsset::unthresholded(11, 2, 3),
            ],
        );
        assert_eq!(
            connected_root_fragment_ids(&asset, &BTreeSet::new()),
            BTreeSet::from([1, 2, 3])
        );
        assert!(!graph_is_disconnected(&asset, &BTreeSet::new()));

        // Breaking the middle edge isolates fragment 3.
        let broken = BTreeSet::from([11]);
        assert_eq!(
            connected_root_fragment_ids(&asset, &broken),
            BTreeSet::from([1, 2])
        );
        assert!(graph_is_disconnected(&asset, &broken));
    }

    #[test]
    fn nearest_connection_uses_midpoint_and_tiebreaks_on_lowest_id() {
        let connections = vec![
            DestructibleConnectionAsset::unthresholded(5, 1, 2),
            DestructibleConnectionAsset::unthresholded(6, 1, 2),
        ];
        let asset = DestructibleAsset::new(
            0,
            vec![
                DestructibleFragmentAsset::with_geometry(1, "a"),
                DestructibleFragmentAsset::with_geometry(2, "b"),
            ],
            connections.clone(),
        );
        // Both edges share the same midpoint, so the lower connection ID wins.
        assert_eq!(
            nearest_connection(Float3::ZERO, &connections, &asset, MATRIX_IDENTITY_FLOAT4X4)
                .map(|connection| connection.connection_id),
            Some(5)
        );
        assert_eq!(
            nearest_connection(Float3::ZERO, &[], &asset, MATRIX_IDENTITY_FLOAT4X4),
            None
        );
    }

    #[test]
    fn validation_rejects_duplicate_ids_and_empty_assets() {
        let empty = DestructibleAsset::new(0, Vec::new(), Vec::new());
        assert_eq!(
            validate_destructible_asset(&empty, &new_world()),
            Some("Destructible asset has no fragments".to_string())
        );

        let duplicate = DestructibleAsset::new(
            0,
            vec![
                DestructibleFragmentAsset::with_geometry(1, "a"),
                DestructibleFragmentAsset::with_geometry(1, "b"),
            ],
            Vec::new(),
        );
        assert_eq!(
            validate_destructible_asset(&duplicate, &new_world()),
            Some("Destructible asset contains duplicate fragment IDs".to_string())
        );
    }

    #[test]
    fn validation_rejects_a_graph_that_starts_disconnected() {
        // Three fragments in two islands: 1-2 and an isolated 3.
        let asset = DestructibleAsset::new(
            0,
            vec![
                DestructibleFragmentAsset::with_geometry(1, "a"),
                DestructibleFragmentAsset::with_geometry(2, "b"),
                DestructibleFragmentAsset::with_geometry(3, "c"),
            ],
            vec![DestructibleConnectionAsset::unthresholded(10, 1, 2)],
        );
        assert_eq!(
            validate_destructible_asset(&asset, &new_world()),
            Some("Destructible asset connection graph is initially disconnected".to_string())
        );
    }

    #[test]
    fn validation_rejects_self_looping_connections() {
        let asset = DestructibleAsset::new(
            0,
            vec![
                DestructibleFragmentAsset::with_geometry(1, "a"),
                DestructibleFragmentAsset::with_geometry(2, "b"),
            ],
            vec![DestructibleConnectionAsset::unthresholded(10, 1, 1)],
        );
        assert_eq!(
            validate_destructible_asset(&asset, &new_world()),
            Some("Connection 10 is invalid".to_string())
        );
    }

    #[test]
    fn configuration_and_command_validity_match_swift() {
        let valid = Destructible::new("asset", 1.0, 1.0, 1, 1.0, 1.0, 0.0, true);
        assert!(is_valid_destructible_configuration(&valid));
        // An empty asset resource ID is invalid.
        let invalid = Destructible::new("", 1.0, 1.0, 1, 1.0, 1.0, 0.0, true);
        assert!(!is_valid_destructible_configuration(&invalid));

        let entity = EntityID::new(1, 0);
        assert!(is_valid_destruction_command(&DestructionCommand::new(
            entity,
            1.0,
            Float3::ZERO,
            None,
            false
        )));
        assert!(!is_valid_destruction_command(&DestructionCommand::new(
            entity,
            1.0,
            Float3::new(f32::NAN, 0.0, 0.0),
            None,
            false
        )));
        assert!(!is_valid_destruction_command(&DestructionCommand::new(
            entity,
            1.0,
            Float3::ZERO,
            Some(Float3::new(0.0, f32::INFINITY, 0.0)),
            false
        )));
        // NaN damage is clamped to 0 by `init`, so it cannot reach this check:
        // Swift's `max(0, .nan)` is 0, exactly like Rust's `f32::max`. The reachable
        // invalid cases are the two fields the initializer stores verbatim.
        let nan_damage = DestructionCommand::new(entity, f32::NAN, Float3::ZERO, None, false);
        assert_eq!(nan_damage.damage, 0.0);
        assert!(is_valid_destruction_command(&nan_damage));
    }

    #[test]
    fn event_limit_overflows_instead_of_growing() {
        let mut world = new_world();
        world.set_resource(DestructionSettingsResource::new(10, 2));
        let mut frame = DestructionEventFrameResource::empty();
        let event = || {
            DestructionEvent::new(
                EntityID::new(1, 0),
                DestructionCause::Forced,
                Vec::new(),
                Vec::new(),
                Vec::new(),
                0.0,
                0.0,
                0,
            )
        };
        append_event(event(), &world, &mut frame);
        append_event(event(), &world, &mut frame);
        assert_eq!(frame.events.len(), 2);
        assert!(!frame.did_overflow);
        // The limit counts events, failures and recycles together.
        append_failure(
            DestructionFailureEvent::new(
                EntityID::new(1, 0),
                DestructionFailureReason::InvalidCommand,
                "x",
            ),
            &world,
            &mut frame,
        );
        assert_eq!(frame.failures.len(), 0);
        assert!(frame.did_overflow);
    }

    #[test]
    fn compound_transform_requires_orthonormal_basis() {
        assert!(supports_compound_collider_transform(
            LocalTransform::IDENTITY
        ));
        // Zero scale is degenerate.
        assert!(!supports_compound_collider_transform(LocalTransform::new(
            Float4x4::diagonal(Float4::new(0.0, 1.0, 1.0, 1.0))
        )));
        // A skewed basis is rejected.
        let skewed = Float4x4::from_rows(&[
            Float4::new(1.0, 0.0, 0.0, 0.0),
            Float4::new(0.5, 1.0, 0.0, 0.0),
            Float4::new(0.0, 0.0, 1.0, 0.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
        ]);
        assert!(!supports_compound_collider_transform(LocalTransform::new(
            skewed
        )));
    }

    #[test]
    fn missing_asset_records_a_failure_without_fracturing() {
        let mut world = new_world();
        let entity = world.create_entity();
        world.set_component(
            Destructible::new("missing", 1.0, 1.0, 8, 30.0, 5.0, 0.0, true),
            entity,
        );
        let mut frame = DestructionEventFrameResource::empty();
        let changed = apply_destruction(
            DestructionCommand::new(entity, 100.0, Float3::ZERO, None, true),
            false,
            &mut world,
            &mut DestructionRuntimeStateResource::default(),
            &mut frame,
        );
        assert!(!changed);
        assert_eq!(frame.failures.len(), 1);
        assert_eq!(
            frame.failures[0].reason,
            DestructionFailureReason::MissingAsset
        );
        assert_eq!(
            frame.failures[0].message,
            "Missing destructible asset 'missing'"
        );
    }

    #[test]
    fn disabled_destructible_is_ignored() {
        let mut world = new_world();
        let entity = world.create_entity();
        world.set_component(
            Destructible::new("asset", 1.0, 1.0, 8, 30.0, 5.0, 0.0, false),
            entity,
        );
        let mut frame = DestructionEventFrameResource::empty();
        let changed = apply_destruction(
            DestructionCommand::new(entity, 100.0, Float3::ZERO, None, true),
            false,
            &mut world,
            &mut DestructionRuntimeStateResource::default(),
            &mut frame,
        );
        assert!(!changed);
        assert!(frame.events.is_empty());
        assert!(frame.failures.is_empty());
    }
}
