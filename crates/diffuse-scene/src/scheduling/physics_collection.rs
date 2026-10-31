//! Physics descriptor collection and per-frame sync-event diffing.
//!
//! `diff_physics_sync_events` is the load-bearing part: it decides exactly what the
//! backend is told each frame, and its ordering rules are observable in recorded
//! state hashes. Two rules must not be "tidied":
//!
//! - A constraint is re-upserted when *either* of its bodies changed, even if the
//!   constraint itself is unchanged. Swift compared against the previous frame's
//!   descriptor, which does not encode the bodies' transforms, so without this the
//!   backend would keep a stale anchor.
//! - A vehicle is re-upserted when its own entity changed, for the same reason.
//!
//! Events are emitted in a fixed order — body upserts, body removals, constraint
//! upserts, constraint removals, vehicle upserts, vehicle removals, soft-body
//! upserts, soft-body removals — so a replay produces an identical event stream.

use std::collections::BTreeMap;

use diffuse_kernel::job_system::{JobDispatchReport, JobSystem};

use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_context::PhysicsSyncEvent;
use crate::physics::backend::physics_descriptors::{
    PhysicsBodyDescriptor, PhysicsCharacterDescriptor, PhysicsConstraintDescriptor,
    PhysicsSoftBodyDescriptor, PhysicsSoftBodyTopology, PhysicsVehicleDescriptor,
};
use crate::physics::character_controller::CharacterController;
use crate::physics::collider::Collider;
use crate::physics::joints::physics_joint::Constraint;
use crate::physics::queries::spatial_queries::{
    MeshColliderBoundsResource, MeshColliderGeometry, MeshColliderGeometryResource,
};
use crate::physics::rigid_body::RigidBody;
use crate::physics::soft_bodies::cloth::Cloth;
use crate::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};
use crate::physics::vehicles::vehicle::Vehicle;
use crate::runtime_world::{LocalTransform, RuntimeWorld, WorldTransform};

/// A snapshot of every physics-relevant component, taken once per frame so the
/// collectors do not each walk the component store.
pub struct PhysicsReadView {
    pub entities: Vec<EntityID>,
    pub local_transforms: BTreeMap<EntityID, LocalTransform>,
    pub world_transforms: BTreeMap<EntityID, WorldTransform>,
    pub rigid_bodies: BTreeMap<EntityID, RigidBody>,
    pub colliders: BTreeMap<EntityID, Collider>,
    pub constraints: BTreeMap<EntityID, Constraint>,
    pub characters: BTreeMap<EntityID, CharacterController>,
    pub vehicles: BTreeMap<EntityID, Vehicle>,
    pub soft_bodies: BTreeMap<EntityID, SoftBody>,
    pub cloths: BTreeMap<EntityID, Cloth>,
    pub soft_body_meshes: BTreeMap<EntityID, SoftBodyMesh>,
    pub mesh_geometries: BTreeMap<EntityID, MeshColliderGeometry>,
    pub soft_body_mesh_geometries: BTreeMap<EntityID, MeshColliderGeometry>,
}

/// The previous frame's descriptors, used to compute a minimal sync-event set.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsSyncCache {
    pub bodies: BTreeMap<EntityID, PhysicsBodyDescriptor>,
    pub constraints: BTreeMap<EntityID, PhysicsConstraintDescriptor>,
    pub vehicles: BTreeMap<EntityID, PhysicsVehicleDescriptor>,
    pub soft_bodies: BTreeMap<EntityID, PhysicsSoftBodyDescriptor>,
}

impl PhysicsSyncCache {
    #[inline]
    pub fn new() -> Self {
        Self::default()
    }
}

/// Take the frame's component snapshot.
pub fn build_physics_read_view(world: &RuntimeWorld) -> PhysicsReadView {
    let entities = world.entities();
    let colliders = world.component_snapshot::<Collider>();
    let soft_body_meshes = world.component_snapshot::<SoftBodyMesh>();
    let geometry_resource = world.resource::<MeshColliderGeometryResource>();
    let _bounds_resource = world.resource::<MeshColliderBoundsResource>();

    let mut mesh_geometries = BTreeMap::new();
    for (entity, collider) in &colliders {
        let shape = collider.shape();
        if let Some(geometry) = geometry_resource
            .as_ref()
            .and_then(|resource| resource.geometry_for(shape.resource_id()))
        {
            mesh_geometries.insert(*entity, geometry.clone());
        }
    }
    let mut soft_body_mesh_geometries = BTreeMap::new();
    for (entity, mesh) in &soft_body_meshes {
        if let Some(geometry) = geometry_resource
            .as_ref()
            .and_then(|resource| resource.geometry_for(mesh.resource_id.as_deref()))
        {
            soft_body_mesh_geometries.insert(*entity, geometry.clone());
        }
    }

    PhysicsReadView {
        entities: entities.clone(),
        local_transforms: world.local_transform_snapshot_matching(&entities),
        world_transforms: world.world_transform_snapshot_matching(&entities),
        rigid_bodies: world.component_snapshot::<RigidBody>(),
        colliders,
        constraints: world.component_snapshot::<Constraint>(),
        characters: world.component_snapshot::<CharacterController>(),
        vehicles: world.component_snapshot::<Vehicle>(),
        soft_bodies: world.component_snapshot::<SoftBody>(),
        cloths: world.component_snapshot::<Cloth>(),
        soft_body_meshes,
        mesh_geometries,
        soft_body_mesh_geometries,
    }
}

/// Collect body descriptors. An entity needs a transform and at least one of a
/// rigid body or a collider.
pub fn collect_physics_bodies(
    view: &PhysicsReadView,
    job_system: &JobSystem,
) -> (Vec<PhysicsBodyDescriptor>, JobDispatchReport) {
    job_system.parallel_compact_map(&view.entities, None, |entity| {
        let rigid_body = view.rigid_bodies.get(entity).cloned();
        let collider = view.colliders.get(entity).cloned();
        if rigid_body.is_none() && collider.is_none() {
            return None;
        }
        let local_transform = view.local_transforms.get(entity).copied()?;
        let world_transform = view.world_transforms.get(entity).copied()?;
        Some(PhysicsBodyDescriptor {
            entity: *entity,
            local_transform,
            world_transform,
            rigid_body,
            collider,
            mesh_geometry: view.mesh_geometries.get(entity).cloned(),
        })
    })
}

/// Collect constraint descriptors; a transform is required.
pub fn collect_physics_constraints(
    view: &PhysicsReadView,
    job_system: &JobSystem,
) -> (Vec<PhysicsConstraintDescriptor>, JobDispatchReport) {
    job_system.parallel_compact_map(&view.entities, None, |entity| {
        let constraint = view.constraints.get(entity).cloned()?;
        let world_transform = view.world_transforms.get(entity).copied()?;
        Some(PhysicsConstraintDescriptor {
            entity: *entity,
            world_transform,
            constraint,
        })
    })
}

/// Collect character descriptors; a transform is required.
pub fn collect_physics_characters(view: &PhysicsReadView) -> Vec<PhysicsCharacterDescriptor> {
    view.entities
        .iter()
        .filter_map(|entity| {
            let controller = view.characters.get(entity).cloned()?;
            let world_transform = view.world_transforms.get(entity).copied()?;
            Some(PhysicsCharacterDescriptor {
                entity: *entity,
                world_transform,
                controller,
            })
        })
        .collect()
}

/// Collect vehicle descriptors. A disabled vehicle is not simulated, so it is
/// omitted entirely rather than sent as a no-op.
pub fn collect_physics_vehicles(view: &PhysicsReadView) -> Vec<PhysicsVehicleDescriptor> {
    view.entities
        .iter()
        .filter_map(|entity| {
            let vehicle = view.vehicles.get(entity).cloned()?;
            if !vehicle.is_enabled {
                return None;
            }
            Some(PhysicsVehicleDescriptor {
                entity: *entity,
                vehicle,
            })
        })
        .collect()
}

/// Collect soft-body descriptors, resolving their single topology provider.
///
/// A soft body with *both* a cloth and a surface mesh is a configuration conflict:
/// it is forwarded as `Invalid` so the backend reports `invalidArgument`, rather
/// than silently picking one. A soft body with neither is simply not a soft body.
pub fn collect_physics_soft_bodies(view: &PhysicsReadView) -> Vec<PhysicsSoftBodyDescriptor> {
    view.entities
        .iter()
        .filter_map(|entity| {
            let soft_body = view.soft_bodies.get(entity).cloned()?;
            if !soft_body.is_enabled {
                return None;
            }
            let world_transform = view.world_transforms.get(entity).copied()?;
            let cloth = view.cloths.get(entity).cloned();
            let mesh = view.soft_body_meshes.get(entity).cloned();
            let topology = match (&cloth, &mesh) {
                (Some(cloth), None) => PhysicsSoftBodyTopology::Cloth(cloth.clone()),
                (None, Some(mesh)) => PhysicsSoftBodyTopology::SurfaceMesh(
                    mesh.clone(),
                    view.soft_body_mesh_geometries.get(entity).cloned(),
                ),
                (Some(_), Some(_)) => PhysicsSoftBodyTopology::Invalid,
                (None, None) => return None,
            };
            Some(PhysicsSoftBodyDescriptor {
                entity: *entity,
                world_transform,
                soft_body,
                topology,
            })
        })
        .collect()
}

/// Diff this frame's descriptors against the previous frame's cache.
///
/// Returns the events, the merged dispatch report, and the cache the caller should
/// store for the next frame.
pub fn diff_physics_sync_events(
    bodies: &[PhysicsBodyDescriptor],
    constraints: &[PhysicsConstraintDescriptor],
    vehicles: &[PhysicsVehicleDescriptor],
    soft_bodies: &[PhysicsSoftBodyDescriptor],
    previous: &PhysicsSyncCache,
    job_system: &JobSystem,
) -> (Vec<PhysicsSyncEvent>, JobDispatchReport, PhysicsSyncCache) {
    let body_map: BTreeMap<EntityID, PhysicsBodyDescriptor> = bodies
        .iter()
        .map(|descriptor| (descriptor.entity, descriptor.clone()))
        .collect();
    let constraint_map: BTreeMap<EntityID, PhysicsConstraintDescriptor> = constraints
        .iter()
        .map(|descriptor| (descriptor.entity, descriptor.clone()))
        .collect();
    let vehicle_map: BTreeMap<EntityID, PhysicsVehicleDescriptor> = vehicles
        .iter()
        .map(|descriptor| (descriptor.entity, descriptor.clone()))
        .collect();
    let soft_body_map: BTreeMap<EntityID, PhysicsSoftBodyDescriptor> = soft_bodies
        .iter()
        .map(|descriptor| (descriptor.entity, descriptor.clone()))
        .collect();

    let (body_upserts, body_upsert_report) =
        job_system.parallel_compact_map(bodies, None, |descriptor| {
            if previous.bodies.get(&descriptor.entity) == Some(descriptor) {
                None
            } else {
                Some(PhysicsSyncEvent::BodyUpsert(Box::new(descriptor.clone())))
            }
        });
    let changed_body_entities: std::collections::BTreeSet<EntityID> = body_upserts
        .iter()
        .filter_map(|event| match event {
            PhysicsSyncEvent::BodyUpsert(descriptor) => Some(descriptor.entity),
            _ => None,
        })
        .collect();

    let previous_body_keys: Vec<EntityID> = previous.bodies.keys().copied().collect();
    let (body_removals, body_remove_report) =
        job_system.parallel_compact_map(&previous_body_keys, None, |entity| {
            if body_map.contains_key(entity) {
                None
            } else {
                Some(PhysicsSyncEvent::BodyRemove(*entity))
            }
        });

    // A constraint must be re-sent when either of its bodies moved, because the
    // descriptor does not carry the bodies' transforms.
    let (constraint_upserts, constraint_upsert_report) =
        job_system.parallel_compact_map(constraints, None, |descriptor| {
            let depends_on_changed_body = changed_body_entities
                .contains(&descriptor.constraint.entity_a)
                || changed_body_entities.contains(&descriptor.constraint.entity_b);
            if previous.constraints.get(&descriptor.entity) == Some(descriptor)
                && !depends_on_changed_body
            {
                None
            } else {
                Some(PhysicsSyncEvent::ConstraintUpsert(Box::new(
                    descriptor.clone(),
                )))
            }
        });

    let previous_constraint_keys: Vec<EntityID> = previous.constraints.keys().copied().collect();
    let (constraint_removals, constraint_remove_report) =
        job_system.parallel_compact_map(&previous_constraint_keys, None, |entity| {
            if constraint_map.contains_key(entity) {
                None
            } else {
                Some(PhysicsSyncEvent::ConstraintRemove(*entity))
            }
        });

    let (vehicle_upserts, vehicle_upsert_report) =
        job_system.parallel_compact_map(vehicles, None, |descriptor| {
            let depends_on_changed_body = changed_body_entities.contains(&descriptor.entity);
            if previous.vehicles.get(&descriptor.entity) == Some(descriptor)
                && !depends_on_changed_body
            {
                None
            } else {
                Some(PhysicsSyncEvent::VehicleUpsert(Box::new(
                    descriptor.clone(),
                )))
            }
        });

    let previous_vehicle_keys: Vec<EntityID> = previous.vehicles.keys().copied().collect();
    let (vehicle_removals, vehicle_remove_report) =
        job_system.parallel_compact_map(&previous_vehicle_keys, None, |entity| {
            if vehicle_map.contains_key(entity) {
                None
            } else {
                Some(PhysicsSyncEvent::VehicleRemove(*entity))
            }
        });

    let (soft_body_upserts, soft_body_upsert_report) =
        job_system.parallel_compact_map(soft_bodies, None, |descriptor| {
            if previous.soft_bodies.get(&descriptor.entity) == Some(descriptor) {
                None
            } else {
                Some(PhysicsSyncEvent::SoftBodyUpsert(Box::new(
                    descriptor.clone(),
                )))
            }
        });

    let previous_soft_body_keys: Vec<EntityID> = previous.soft_bodies.keys().copied().collect();
    let (soft_body_removals, soft_body_remove_report) =
        job_system.parallel_compact_map(&previous_soft_body_keys, None, |entity| {
            if soft_body_map.contains_key(entity) {
                None
            } else {
                Some(PhysicsSyncEvent::SoftBodyRemove(*entity))
            }
        });

    let reports = [
        body_upsert_report,
        body_remove_report,
        constraint_upsert_report,
        constraint_remove_report,
        vehicle_upsert_report,
        vehicle_remove_report,
        soft_body_upsert_report,
        soft_body_remove_report,
    ];
    let mut events = Vec::new();
    events.extend(body_upserts);
    events.extend(body_removals);
    events.extend(constraint_upserts);
    events.extend(constraint_removals);
    events.extend(vehicle_upserts);
    events.extend(vehicle_removals);
    events.extend(soft_body_upserts);
    events.extend(soft_body_removals);

    (
        events,
        JobDispatchReport::merged(&reports, job_system.worker_count),
        PhysicsSyncCache {
            bodies: body_map,
            constraints: constraint_map,
            vehicles: vehicle_map,
            soft_bodies: soft_body_map,
        },
    )
}

/// Merge backend writebacks, later entries winning.
pub fn merge_writebacks(
    existing: Vec<crate::physics::backend::physics_backend_context::PhysicsBodyWriteback>,
    incoming: Vec<crate::physics::backend::physics_backend_context::PhysicsBodyWriteback>,
) -> Vec<crate::physics::backend::physics_backend_context::PhysicsBodyWriteback> {
    let mut merged: BTreeMap<EntityID, _> = existing
        .into_iter()
        .map(|writeback| (writeback.entity, writeback))
        .collect();
    for writeback in incoming {
        merged.insert(writeback.entity, writeback);
    }
    merged.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;
    use crate::runtime_world::LocalTransform;

    fn empty_world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    fn empty_cache() -> PhysicsSyncCache {
        PhysicsSyncCache::new()
    }

    #[test]
    fn a_body_without_a_rigid_body_or_collider_is_skipped() {
        let mut world = empty_world();
        world.create_entity();
        // A bare entity has an identity transform (Swift's `localTransform` defaults
        // to `.identity` for a live entity) but no body or collider.
        let view = build_physics_read_view(&world);
        let (bodies, _) = collect_physics_bodies(&view, &JobSystem::new(1, 1));
        assert!(
            bodies.is_empty(),
            "an entity with no body or collider is not a physics body"
        );
    }

    #[test]
    fn a_body_with_a_transform_is_collected_once() {
        let mut world = empty_world();
        let entity = world.create_entity();
        world.set_component(RigidBody::default(), entity);
        world.set_local_transform(LocalTransform::IDENTITY, entity);
        let view = build_physics_read_view(&world);
        let (bodies, _) = collect_physics_bodies(&view, &JobSystem::new(1, 1));
        assert_eq!(bodies.len(), 1);
        assert_eq!(bodies[0].entity, entity);
    }

    #[test]
    fn the_first_frame_upserts_every_body() {
        let mut world = empty_world();
        let entity = world.create_entity();
        world.set_component(RigidBody::default(), entity);
        world.set_local_transform(LocalTransform::IDENTITY, entity);

        let view = build_physics_read_view(&world);
        let jobs = JobSystem::new(1, 1);
        let (bodies, _) = collect_physics_bodies(&view, &jobs);
        let (events, _, cache) =
            diff_physics_sync_events(&bodies, &[], &[], &[], &empty_cache(), &jobs);

        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], PhysicsSyncEvent::BodyUpsert(_)));
        assert_eq!(cache.bodies.len(), 1);
    }

    #[test]
    fn an_unchanged_second_frame_emits_nothing() {
        let mut world = empty_world();
        let entity = world.create_entity();
        world.set_component(RigidBody::default(), entity);
        world.set_local_transform(LocalTransform::IDENTITY, entity);

        let view = build_physics_read_view(&world);
        let jobs = JobSystem::new(1, 1);
        let (bodies, _) = collect_physics_bodies(&view, &jobs);
        let (_, _, cache) = diff_physics_sync_events(&bodies, &[], &[], &[], &empty_cache(), &jobs);
        let (events, _, _) = diff_physics_sync_events(&bodies, &[], &[], &[], &cache, &jobs);

        assert!(
            events.is_empty(),
            "an unchanged frame must send no sync events"
        );
    }

    #[test]
    fn a_removed_body_produces_a_removal_event() {
        let mut world = empty_world();
        let entity = world.create_entity();
        world.set_component(RigidBody::default(), entity);
        world.set_local_transform(LocalTransform::IDENTITY, entity);

        let view = build_physics_read_view(&world);
        let jobs = JobSystem::new(1, 1);
        let (bodies, _) = collect_physics_bodies(&view, &jobs);
        let (_, _, cache) = diff_physics_sync_events(&bodies, &[], &[], &[], &empty_cache(), &jobs);
        let (events, _, _) = diff_physics_sync_events(&[], &[], &[], &[], &cache, &jobs);

        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], PhysicsSyncEvent::BodyRemove(_)));
    }

    #[test]
    fn a_soft_body_with_both_topologies_is_forwarded_as_invalid() {
        use crate::physics::soft_bodies::cloth::Cloth;
        use crate::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};

        let mut world = empty_world();
        let entity = world.create_entity();
        world.set_component(SoftBody::default(), entity);
        world.set_component(Cloth::default(), entity);
        world.set_component(SoftBodyMesh::default(), entity);
        world.set_local_transform(LocalTransform::IDENTITY, entity);

        let view = build_physics_read_view(&world);
        let soft_bodies = collect_physics_soft_bodies(&view);
        assert_eq!(soft_bodies.len(), 1);
        assert!(
            matches!(soft_bodies[0].topology, PhysicsSoftBodyTopology::Invalid),
            "a conflicting topology must be reported, not silently resolved"
        );
    }

    #[test]
    fn a_disabled_vehicle_is_not_collected() {
        use crate::physics::vehicles::vehicle::Vehicle;

        let mut world = empty_world();
        let entity = world.create_entity();
        let vehicle = Vehicle {
            is_enabled: false,
            ..Vehicle::default()
        };
        world.set_component(vehicle, entity);

        let view = build_physics_read_view(&world);
        assert!(collect_physics_vehicles(&view).is_empty());
    }
}
