//! Debug-frame construction: bodies, constraints, contacts and destruction links.
//!
//! Everything here is derived, never authoritative — it exists so a debug renderer can
//! draw what the simulation currently believes. Two ordering rules are observable in
//! recorded frames and must stay:
//!
//! - destruction connections are emitted per source entity in ascending `EntityID`
//!   order, then by `(connection_id, fragment_a, fragment_b)`;
//! - a fragment's world position is the **first** occurrence for that id, so a
//!   duplicated fragment id in an asset does not move the drawn point.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};

use crate::entity_id::EntityID;
use crate::physics::character_controller::{CharacterState, CharacterStateFrameResource};
use crate::physics::collider::Collider;
use crate::physics::destruction::{
    Destructible, DestructibleAssetResource, DestructionRuntimeSourceState,
    DestructionRuntimeStateResource,
};
use crate::physics::joints::physics_joint::Constraint;
use crate::physics::physics_debug_frame::{
    PhysicsDebugBody, PhysicsDebugConstraint, PhysicsDebugDestructionConnection,
    PhysicsDebugFrameResource,
};
use crate::physics::physics_events::PhysicsContactEvent;
use crate::physics::queries::spatial_queries::SpatialIndexResource;
use crate::physics::rigid_body::{RigidBody, RigidBodyMotionType};
use crate::runtime_world::RuntimeWorld;

/// Build the frame's debug view.
///
/// `contacts` are passed in rather than read from a resource because the trigger
/// phase has already computed them and they are not mirrored into the world.
pub fn build_physics_debug_frame(
    world: &RuntimeWorld,
    spatial_index: &SpatialIndexResource,
    contacts: &[PhysicsContactEvent],
    character_state_frame: &CharacterStateFrameResource,
) -> PhysicsDebugFrameResource {
    let bodies: Vec<PhysicsDebugBody> = spatial_index
        .entries
        .iter()
        .map(|entry| {
            let body = world.component::<RigidBody>(entry.entity);
            let collider = world.component::<Collider>(entry.entity);
            let motion_type = body
                .as_ref()
                .map(|body| body.motion_type)
                .unwrap_or(RigidBodyMotionType::Static);
            let is_sleeping = body.as_ref().map(|body| body.is_sleeping).unwrap_or(false);
            PhysicsDebugBody {
                entity: entry.entity,
                shape: entry.shape.clone(),
                shapes: collider
                    .map(|collider| collider.shapes.clone())
                    .unwrap_or_default(),
                world_transform: entry.world_transform,
                bounds: entry.bounds,
                motion_type,
                is_trigger: entry.is_trigger,
                is_sleeping,
            }
        })
        .collect();

    let constraints: Vec<PhysicsDebugConstraint> =
        sorted_entities(world.entities_with::<Constraint>())
            .into_iter()
            .filter_map(|entity| {
                world
                    .component::<Constraint>(entity)
                    .map(|constraint| PhysicsDebugConstraint::new(entity, &constraint))
            })
            .collect();

    let mut characters: Vec<CharacterState> =
        character_state_frame.states.values().cloned().collect();
    characters.sort_by_key(|character| character.entity.raw_value());

    PhysicsDebugFrameResource::new(
        bodies,
        constraints,
        contacts.to_vec(),
        characters,
        build_physics_debug_destruction_connections(world),
    )
}

/// Connection lines for every Destructible source whose asset is loaded.
pub fn build_physics_debug_destruction_connections(
    world: &RuntimeWorld,
) -> Vec<PhysicsDebugDestructionConnection> {
    let Some(assets) = world.resource::<DestructibleAssetResource>() else {
        return Vec::new();
    };
    let runtime = world.resource::<DestructionRuntimeStateResource>();
    let mut result: Vec<PhysicsDebugDestructionConnection> = Vec::new();

    for source in sorted_entities(world.entities_with::<Destructible>()) {
        let Some(destructible) = world.component::<Destructible>(source) else {
            continue;
        };
        let Some(asset) = assets.asset(&destructible.asset_resource_id) else {
            continue;
        };
        let source_matrix = world
            .world_transform(source)
            .map(|transform| transform.matrix)
            .or_else(|| {
                world
                    .local_transform(source)
                    .map(|transform| transform.matrix)
            })
            .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);

        // First occurrence wins, so a duplicated fragment id cannot move the point.
        let mut positions_by_fragment_id: BTreeMap<u32, Float3> = BTreeMap::new();
        let mut fragments: Vec<&crate::physics::destruction::DestructibleFragmentAsset> =
            asset.fragments.iter().collect();
        fragments.sort_by_key(|fragment| fragment.fragment_id);
        for fragment in fragments {
            if positions_by_fragment_id.contains_key(&fragment.fragment_id) {
                continue;
            }
            let transform = source_matrix * fragment.local_transform.matrix;
            positions_by_fragment_id.insert(
                fragment.fragment_id,
                Float3::new(
                    transform.columns[3].x,
                    transform.columns[3].y,
                    transform.columns[3].z,
                ),
            );
        }

        let source_state: Option<&DestructionRuntimeSourceState> = runtime
            .as_ref()
            .and_then(|runtime| runtime.sources.get(&source));

        let mut connections: Vec<&crate::physics::destruction::DestructibleConnectionAsset> =
            asset.connections.iter().collect();
        connections.sort_by(|left, right| {
            if left.connection_id != right.connection_id {
                return left.connection_id.cmp(&right.connection_id);
            }
            if left.fragment_a != right.fragment_a {
                return left.fragment_a.cmp(&right.fragment_a);
            }
            left.fragment_b.cmp(&right.fragment_b)
        });

        for connection in connections {
            let (Some(&point_a), Some(&point_b)) = (
                positions_by_fragment_id.get(&connection.fragment_a),
                positions_by_fragment_id.get(&connection.fragment_b),
            ) else {
                continue;
            };
            result.push(PhysicsDebugDestructionConnection {
                source_entity: source,
                connection_id: connection.connection_id,
                fragment_a: connection.fragment_a,
                fragment_b: connection.fragment_b,
                world_point_a: point_a,
                world_point_b: point_b,
                is_broken: source_state.is_some_and(|state| {
                    state
                        .broken_connection_ids
                        .contains(&connection.connection_id)
                }),
                is_source_fractured: source_state.is_some_and(|state| state.has_fractured),
            });
        }
    }

    result
}

fn sorted_entities(mut entities: Vec<EntityID>) -> Vec<EntityID> {
    entities.sort_by_key(|entity| entity.raw_value());
    entities
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;

    fn empty_world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    #[test]
    fn an_empty_world_produces_an_empty_debug_frame() {
        let world = empty_world();
        let frame = build_physics_debug_frame(
            &world,
            &SpatialIndexResource::default(),
            &[],
            &CharacterStateFrameResource::default(),
        );
        assert!(frame.bodies.is_empty());
        assert!(frame.constraints.is_empty());
        assert!(frame.contacts.is_empty());
        assert!(frame.characters.is_empty());
        assert!(frame.destruction_connections.is_empty());
    }

    #[test]
    fn destruction_connections_are_empty_without_an_asset_resource() {
        let mut world = empty_world();
        let source = world.create_entity();
        world.set_component(Destructible::default(), source);
        assert!(
            build_physics_debug_destruction_connections(&world).is_empty(),
            "no assets means no connections, not a panic"
        );
    }

    #[test]
    fn a_missing_asset_for_a_destructible_is_skipped() {
        let mut world = empty_world();
        let source = world.create_entity();
        let destructible = Destructible {
            asset_resource_id: "missing".to_string(),
            ..Destructible::default()
        };
        world.set_component(destructible, source);
        world.set_resource(DestructibleAssetResource::default());

        assert!(build_physics_debug_destruction_connections(&world).is_empty());
    }

    #[test]
    fn characters_are_sorted_by_entity() {
        let world = empty_world();
        let mut resource = CharacterStateFrameResource::default();
        for raw in [9u32, 2u32] {
            let entity = EntityID::new(raw, 0);
            resource.states.insert(
                entity,
                CharacterState::new(
                    entity,
                    Float3::ZERO,
                    diffuse_math::simd::simd_compat::Float4::new(0.0, 0.0, 0.0, 1.0),
                    Float3::ZERO,
                    crate::physics::character_controller::CharacterGroundState::OnGround,
                    Float3::ZERO,
                    Float3::ZERO,
                    None,
                    crate::physics::character_controller::CharacterStance::Standing,
                ),
            );
        }

        let frame =
            build_physics_debug_frame(&world, &SpatialIndexResource::default(), &[], &resource);
        assert_eq!(frame.characters[0].entity, EntityID::new(2, 0));
        assert_eq!(frame.characters[1].entity, EntityID::new(9, 0));
    }
}
