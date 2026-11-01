//! `PhysicsQueryScene` — mirrors the world's physics state into a backend so
//! spatial queries can run outside the simulation phase.
//!
//! Holds the `PhysicsBackend` trait rather than a concrete engine, so any backend
//! implementation can be queried this way.

use crate::physics::backend::physics_backend::{PhysicsBackend, SharedPhysicsBackend};
use crate::physics::backend::physics_backend_context::{
    PhysicsPrepareContext, PhysicsPrepareResult,
};
use crate::physics::backend::physics_descriptors::{
    PhysicsBodyDescriptor, PhysicsCharacterDescriptor, PhysicsConstraintDescriptor,
};
use crate::physics::character_controller::CharacterController;
use crate::physics::collider::Collider;
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::queries::spatial_queries::{
    MeshColliderBoundsResource, MeshColliderGeometry, MeshColliderGeometryResource,
    resolved_collider_shape,
};
use crate::physics::rigid_body::RigidBody;
use crate::runtime_world::RuntimeWorld;
use std::sync::{Arc, Mutex, MutexGuard};

/// Cache statistics for one `PhysicsQueryScene`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsQueryCacheStats {
    pub source_revision: Option<u64>,
    pub body_count: usize,
    pub constraint_count: usize,
    pub query_count: usize,
    pub rebuild_count: usize,
    pub cache_hit_count: usize,
}

impl PhysicsQueryCacheStats {
    #[inline]
    pub fn new() -> Self {
        Self::default()
    }
}

/// Swift's query cache is a reference object shared by copied schedules.
#[derive(Clone)]
pub struct PhysicsQueryScene {
    state: Arc<Mutex<QuerySceneState>>,
}

struct QuerySceneState {
    backend: SharedPhysicsBackend,
    stats: PhysicsQueryCacheStats,
}

impl PhysicsQueryScene {
    pub fn new(backend: Box<dyn PhysicsBackend>) -> Self {
        Self::with_shared_backend(SharedPhysicsBackend::new(backend))
    }

    pub fn with_shared_backend(backend: SharedPhysicsBackend) -> Self {
        Self {
            state: Arc::new(Mutex::new(QuerySceneState {
                backend,
                stats: PhysicsQueryCacheStats::default(),
            })),
        }
    }

    fn lock(&self) -> MutexGuard<'_, QuerySceneState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    pub fn backend(&mut self, world: &RuntimeWorld) -> SharedPhysicsBackend {
        let mut state = self.lock();
        state.stats.query_count += 1;
        if state.stats.source_revision == Some(world.physics_revision()) {
            state.stats.cache_hit_count += 1;
        }
        Self::synchronize_state(&mut state, world);
        state.backend.clone()
    }

    pub fn synchronize(&mut self, world: &RuntimeWorld) -> SharedPhysicsBackend {
        let mut state = self.lock();
        Self::synchronize_state(&mut state, world);
        state.backend.clone()
    }

    fn synchronize_state(state: &mut QuerySceneState, world: &RuntimeWorld) {
        if state.stats.source_revision == Some(world.physics_revision()) {
            return;
        }
        let snapshot = build_physics_scene_snapshot(world, None);
        let _: PhysicsPrepareResult = state.backend.prepare(PhysicsPrepareContext::new(
            snapshot.settings,
            0.0,
            snapshot.bodies.clone(),
            snapshot.constraints.clone(),
            Vec::new(),
            snapshot.characters.clone(),
            Vec::new(),
            Vec::new(),
            true,
        ));
        state.stats.source_revision = Some(world.physics_revision());
        state.stats.body_count = snapshot.bodies.len();
        state.stats.constraint_count = snapshot.constraints.len();
        state.stats.rebuild_count += 1;
    }

    pub fn adopt_synchronized_world(
        &mut self,
        world: &RuntimeWorld,
        body_count: usize,
        constraint_count: usize,
    ) {
        let mut state = self.lock();
        state.stats.source_revision = Some(world.physics_revision());
        state.stats.body_count = body_count;
        state.stats.constraint_count = constraint_count;
    }

    pub fn replace_backend(&mut self, next: Box<dyn PhysicsBackend>) {
        self.replace_shared_backend(SharedPhysicsBackend::new(next));
    }

    pub fn replace_shared_backend(&mut self, next: SharedPhysicsBackend) {
        let mut state = self.lock();
        state.backend = next;
        state.stats.source_revision = None;
        state.stats.body_count = 0;
        state.stats.constraint_count = 0;
    }

    pub fn invalidate(&mut self) {
        let mut state = self.lock();
        state.stats.source_revision = None;
        state.stats.body_count = 0;
        state.stats.constraint_count = 0;
    }

    pub fn stats(&self) -> PhysicsQueryCacheStats {
        self.lock().stats.clone()
    }

    pub fn backend_identifier(&self) -> String {
        self.lock().backend.identifier().to_string()
    }
}

/// One physics-scene snapshot: the descriptors a backend needs to answer queries.
pub struct PhysicsSceneSnapshot {
    pub settings: PhysicsSettingsResource,
    pub bodies: Vec<PhysicsBodyDescriptor>,
    pub constraints: Vec<PhysicsConstraintDescriptor>,
    pub characters: Vec<PhysicsCharacterDescriptor>,
}

/// Build the full descriptor set for `world`.
///
/// `settings_override` lets a caller supply settings the world does not carry; the
/// backend selection lives in those settings, so this snapshot must never claim an
/// engine of its own.
pub fn build_physics_scene_snapshot(
    world: &RuntimeWorld,
    settings_override: Option<PhysicsSettingsResource>,
) -> PhysicsSceneSnapshot {
    let settings = settings_override
        .or_else(|| world.resource::<PhysicsSettingsResource>())
        .unwrap_or_default();

    let entities = world.entities();
    let local_transforms = world.local_transform_snapshot_matching(&entities);
    let world_transforms = world.world_transform_snapshot_matching(&entities);
    let rigid_bodies = world.component_snapshot_matching::<RigidBody>(&entities);
    let colliders = world.component_snapshot_matching::<Collider>(&entities);
    let constraints = world
        .component_snapshot_matching::<crate::physics::joints::physics_joint::Constraint>(
            &entities,
        );
    let characters = world.component_snapshot_matching::<CharacterController>(&entities);
    let geometry_resource = world.resource::<MeshColliderGeometryResource>();
    let mesh_bounds = world.resource::<MeshColliderBoundsResource>();

    let bodies: Vec<PhysicsBodyDescriptor> = entities
        .iter()
        .filter_map(|entity| {
            let rigid_body = rigid_bodies.get(entity).cloned();
            let mut collider = colliders.get(entity).cloned();
            let mut mesh_geometry: Option<MeshColliderGeometry> = None;
            if let Some(current) = &collider {
                let current_shape = current.shape();
                let geometry = geometry_resource
                    .as_ref()
                    .and_then(|resource| resource.geometry_for(current_shape.resource_id()));
                let resolved =
                    resolved_collider_shape(&current_shape, geometry, mesh_bounds.as_ref());
                if resolved == current_shape {
                    mesh_geometry = geometry.cloned();
                } else {
                    // Swift rebuilt the collider with the resolved shape while
                    // keeping the trigger/layer/material fields.
                    let mut rebuilt = Collider::with_shape(resolved);
                    rebuilt.is_trigger = current.is_trigger;
                    rebuilt.layer_id = current.layer_id;
                    rebuilt.layer_mask = current.layer_mask;
                    rebuilt.material = current.material.clone();
                    collider = Some(rebuilt);
                }
            }
            if rigid_body.is_none() && collider.is_none() {
                return None;
            }
            let local_transform = local_transforms.get(entity).copied()?;
            let world_transform = world_transforms.get(entity).copied()?;
            Some(PhysicsBodyDescriptor {
                entity: *entity,
                local_transform,
                world_transform,
                rigid_body,
                collider,
                mesh_geometry,
            })
        })
        .collect();

    let constraint_descriptors: Vec<PhysicsConstraintDescriptor> = entities
        .iter()
        .filter_map(|entity| {
            let constraint = constraints.get(entity).cloned()?;
            let world_transform = world_transforms.get(entity).copied()?;
            Some(PhysicsConstraintDescriptor {
                entity: *entity,
                world_transform,
                constraint,
            })
        })
        .collect();

    let character_descriptors: Vec<PhysicsCharacterDescriptor> = entities
        .iter()
        .filter_map(|entity| {
            let controller = characters.get(entity).cloned()?;
            let world_transform = world_transforms.get(entity).copied()?;
            Some(PhysicsCharacterDescriptor {
                entity: *entity,
                world_transform,
                controller,
            })
        })
        .collect();

    PhysicsSceneSnapshot {
        settings,
        bodies,
        constraints: constraint_descriptors,
        characters: character_descriptors,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;
    use crate::entity_id::EntityID;
    use crate::physics::backend::null_physics_backend::NullPhysicsBackend;

    fn world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    #[test]
    fn cache_stats_start_empty() {
        let scene = PhysicsQueryScene::new(Box::new(NullPhysicsBackend::new()));
        let stats = scene.stats();
        assert_eq!(stats.source_revision, None);
        assert_eq!(stats.query_count, 0);
        assert_eq!(stats.rebuild_count, 0);
    }

    #[test]
    fn the_first_query_builds_the_snapshot_and_the_second_is_a_cache_hit() {
        let mut scene = PhysicsQueryScene::new(Box::new(NullPhysicsBackend::new()));
        let world = world();
        let _ = scene.backend(&world);
        let after_first = scene.stats();
        assert_eq!(after_first.rebuild_count, 1);
        assert_eq!(after_first.cache_hit_count, 0);

        let _ = scene.backend(&world);
        let after_second = scene.stats();
        assert_eq!(
            after_second.rebuild_count, 1,
            "same revision must not rebuild"
        );
        assert_eq!(after_second.cache_hit_count, 1);
        assert_eq!(after_second.query_count, 2);
    }

    #[test]
    fn invalidating_forces_a_rebuild() {
        let mut scene = PhysicsQueryScene::new(Box::new(NullPhysicsBackend::new()));
        let world = world();
        let _ = scene.backend(&world);
        scene.invalidate();
        let _ = scene.backend(&world);
        assert_eq!(scene.stats().rebuild_count, 2);
    }

    #[test]
    fn a_snapshot_of_an_empty_world_has_no_descriptors() {
        let world = world();
        let snapshot = build_physics_scene_snapshot(&world, None);
        assert!(snapshot.bodies.is_empty());
        assert!(snapshot.constraints.is_empty());
        assert!(snapshot.characters.is_empty());
    }

    #[test]
    fn one_entity_is_one_body_descriptor() {
        use crate::physics::rigid_body::RigidBody;
        use crate::runtime_world::{LocalTransform, WorldTransform};

        let mut world = world();
        let entity: EntityID = world.create_entity();
        world.set_component(RigidBody::default(), entity);
        world.set_component(LocalTransform::IDENTITY, entity);
        world.set_component(WorldTransform::IDENTITY, entity);

        let snapshot = build_physics_scene_snapshot(&world, None);
        assert_eq!(snapshot.bodies.len(), 1);
        assert_eq!(snapshot.bodies[0].entity, entity);
        assert!(snapshot.bodies[0].rigid_body.is_some());
    }
}
