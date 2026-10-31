//! A backend that accepts every descriptor and simulates none of them.
//!
//! Swift's `NullPhysicsBackend` is a complete implementation, not a placeholder:
//! every one of the eleven `PhysicsBackend` methods has real null behaviour, and
//! `capabilities` reports `.all()` so no authored feature is reported unsupported.

use crate::physics::backend::physics_backend::PhysicsBackend;
use crate::physics::backend::physics_backend_capabilities::PhysicsBackendCapabilities;
use crate::physics::backend::physics_backend_context::{
    PhysicsPrepareContext, PhysicsPrepareResult, PhysicsStepContext, PhysicsStepResult,
    PhysicsSyncEvent,
};
use crate::physics::queries::physics_query_types::{
    PhysicsOverlapAABBQuery, PhysicsOverlapHit, PhysicsOverlapShapeQuery, PhysicsQueryFilter,
    PhysicsRaycastHit, PhysicsRaycastQuery, PhysicsSweepAABBQuery, PhysicsSweepHit,
    PhysicsSweepShapeQuery,
};
use crate::physics::queries::trigger_detection::TriggerFrameResource;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct NullPhysicsBackend;

impl NullPhysicsBackend {
    pub fn new() -> Self {
        NullPhysicsBackend
    }
}

impl PhysicsBackend for NullPhysicsBackend {
    fn identifier(&self) -> &str {
        "none"
    }

    fn capabilities(&self) -> PhysicsBackendCapabilities {
        PhysicsBackendCapabilities::all()
    }

    /// Counts the sync events by kind. Nothing is stored, so nothing is ever
    /// removed and no body is ever created.
    fn prepare(&mut self, context: PhysicsPrepareContext) -> PhysicsPrepareResult {
        let mut result = PhysicsPrepareResult::default();
        for event in &context.sync_events {
            match event {
                PhysicsSyncEvent::BodyUpsert(_) => result.synchronized_bodies += 1,
                PhysicsSyncEvent::BodyRemove(_) => result.removed_bodies += 1,
                PhysicsSyncEvent::ConstraintUpsert(_) => result.synchronized_constraints += 1,
                PhysicsSyncEvent::ConstraintRemove(_) => result.removed_constraints += 1,
                PhysicsSyncEvent::VehicleUpsert(_) => result.synchronized_vehicles += 1,
                PhysicsSyncEvent::VehicleRemove(_) => result.removed_vehicles += 1,
                PhysicsSyncEvent::SoftBodyUpsert(_) => result.synchronized_soft_bodies += 1,
                PhysicsSyncEvent::SoftBodyRemove(_) => result.removed_soft_bodies += 1,
            }
        }
        result
    }

    /// Reports the authored counts but produces no contacts and no write-backs.
    fn step(&mut self, context: PhysicsStepContext) -> PhysicsStepResult {
        PhysicsStepResult {
            body_count: context.active_bodies.len() as i64,
            constraint_count: context.active_constraints.len() as i64,
            contact_count: 0,
            writebacks: Vec::new(),
            ..PhysicsStepResult::default()
        }
    }

    fn raycast(
        &self,
        _query: PhysicsRaycastQuery,
        _filter: PhysicsQueryFilter,
    ) -> Option<PhysicsRaycastHit> {
        None
    }

    fn overlap_aabb(
        &self,
        _query: PhysicsOverlapAABBQuery,
        _filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        Vec::new()
    }

    fn overlap_shape(
        &self,
        _query: PhysicsOverlapShapeQuery,
        _filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        Vec::new()
    }

    fn sweep_aabb(
        &self,
        _query: PhysicsSweepAABBQuery,
        _filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        None
    }

    fn sweep_shape(
        &self,
        _query: PhysicsSweepShapeQuery,
        _filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        None
    }

    fn detect_trigger_frame(&self, _max_event_count: usize) -> TriggerFrameResource {
        TriggerFrameResource::default()
    }

    fn reset(&mut self) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entity_id::EntityID;
    use crate::physics::backend::physics_descriptors::PhysicsBodyDescriptor;
    use crate::physics::collider::SpatialAABB;
    use crate::physics::physics_settings::PhysicsSettingsResource;
    use crate::physics::queries::physics_query_types::PhysicsQueryShape;
    use crate::runtime_world::{LocalTransform, WorldTransform};
    use diffuse_math::simd::simd_compat::Float3;
    use std::collections::BTreeMap;

    fn body(entity: EntityID) -> PhysicsBodyDescriptor {
        PhysicsBodyDescriptor::new(
            entity,
            LocalTransform::IDENTITY,
            WorldTransform::IDENTITY,
            None,
            None,
            None,
        )
    }

    fn prepare_context() -> PhysicsPrepareContext {
        PhysicsPrepareContext::new(
            PhysicsSettingsResource::default(),
            0.0,
            Vec::new(),
            Vec::new(),
            vec![
                PhysicsSyncEvent::BodyUpsert(Box::new(body(EntityID::new(0, 0)))),
                PhysicsSyncEvent::BodyRemove(EntityID::new(1, 0)),
                PhysicsSyncEvent::ConstraintRemove(EntityID::new(2, 0)),
                PhysicsSyncEvent::VehicleRemove(EntityID::new(3, 0)),
                PhysicsSyncEvent::SoftBodyRemove(EntityID::new(4, 0)),
            ],
            Vec::new(),
            Vec::new(),
            Vec::new(),
            false,
        )
    }

    fn step_context() -> PhysicsStepContext {
        PhysicsStepContext::new(
            PhysicsSettingsResource::default(),
            1.0 / 60.0,
            0,
            Vec::new(),
            Vec::new(),
            Vec::new(),
            BTreeMap::new(),
            Vec::new(),
            BTreeMap::new(),
            Vec::new(),
        )
    }

    #[test]
    fn identifier_and_capabilities_match_swift() {
        let backend = NullPhysicsBackend::new();
        assert_eq!(backend.identifier(), "none");
        // A semantic, not a placeholder: nothing is reported unsupported.
        assert_eq!(backend.capabilities(), PhysicsBackendCapabilities::all());
    }

    #[test]
    fn prepare_counts_events_by_kind() {
        let mut backend = NullPhysicsBackend::new();
        let result = backend.prepare(prepare_context());
        assert_eq!(result.synchronized_bodies, 1);
        assert_eq!(result.removed_bodies, 1);
        assert_eq!(result.removed_constraints, 1);
        assert_eq!(result.removed_vehicles, 1);
        assert_eq!(result.removed_soft_bodies, 1);
        assert_eq!(result.synchronized_vehicles, 0);
        assert_eq!(result.synchronized_soft_bodies, 0);
        assert!(result.error.is_none());
    }

    #[test]
    fn step_reports_counts_with_no_contacts_or_writebacks() {
        let mut backend = NullPhysicsBackend::new();
        let mut context = step_context();
        context.active_bodies.push(body(EntityID::new(0, 0)));
        let result = backend.step(context);
        assert_eq!(result.body_count, 1);
        assert_eq!(result.constraint_count, 0);
        assert_eq!(result.contact_count, 0);
        assert!(result.writebacks.is_empty());
        assert!(result.contact_events.is_empty());
        assert!(result.character_states.is_empty());
    }

    #[test]
    fn queries_return_the_null_answer() {
        let backend = NullPhysicsBackend::new();
        let filter = PhysicsQueryFilter::default();
        let bounds = SpatialAABB::new(Float3::ZERO, Float3::splat(1.0));
        let ray = PhysicsRaycastQuery::new(Float3::ZERO, Float3::new(0.0, 0.0, 1.0));
        let sweep_shape = PhysicsSweepShapeQuery::new(
            PhysicsQueryShape::Sphere { radius: 1.0 },
            Float3::ZERO,
            Float3::new(0.0, 1.0, 0.0),
        );

        assert!(backend.raycast(ray, filter.clone()).is_none());
        assert!(
            backend
                .raycast_all(ray, filter.clone(), usize::MAX)
                .is_empty()
        );
        assert!(
            backend
                .overlap_aabb(PhysicsOverlapAABBQuery::new(bounds), filter.clone())
                .is_empty()
        );
        assert!(
            backend
                .overlap_shape(
                    PhysicsOverlapShapeQuery::new(
                        PhysicsQueryShape::Sphere { radius: 1.0 },
                        Float3::ZERO
                    ),
                    filter.clone()
                )
                .is_empty()
        );
        assert!(
            backend
                .sweep_aabb(
                    PhysicsSweepAABBQuery::new(bounds, Float3::new(0.0, 1.0, 0.0)),
                    filter.clone()
                )
                .is_none()
        );
        assert!(backend.sweep_shape(sweep_shape, filter.clone()).is_none());
        assert!(
            backend
                .sweep_shape_all(sweep_shape, filter, usize::MAX)
                .is_empty()
        );
        assert!(backend.detect_trigger_frame(usize::MAX).is_empty());
    }

    #[test]
    fn reset_is_a_noop_and_stays_usable() {
        let mut backend = NullPhysicsBackend::new();
        backend.reset();
        assert_eq!(backend.identifier(), "none");
        let result = backend.prepare(prepare_context());
        assert_eq!(result.synchronized_bodies, 1);
    }

    /// Guards the trait's method set. If `PhysicsBackend` grows or loses a method,
    /// this test is the place that fails; it is deliberately named to be greppable.
    #[test]
    fn null_backend_implements_every_trait_method() {
        fn assert_backend<B: PhysicsBackend>() {}
        assert_backend::<NullPhysicsBackend>();

        let mut backend = NullPhysicsBackend::new();
        let filter = PhysicsQueryFilter::default();
        let bounds = SpatialAABB::new(Float3::ZERO, Float3::splat(1.0));
        let shape = PhysicsQueryShape::Sphere { radius: 1.0 };
        let ray = PhysicsRaycastQuery::new(Float3::ZERO, Float3::new(0.0, 0.0, 1.0));
        let sweep = PhysicsSweepShapeQuery::new(shape, Float3::ZERO, Float3::new(0.0, 1.0, 0.0));

        // 1 identifier / 2 capabilities / 3 prepare / 4 step
        let _ = backend.identifier();
        let _ = backend.capabilities();
        let _ = backend.prepare(prepare_context());
        let _ = backend.step(step_context());
        // 5 raycast / 6 raycastAll
        let _ = backend.raycast(ray, filter.clone());
        let _ = backend.raycast_all(ray, filter.clone(), 1);
        // 7 overlapAABB / 8 overlapShape
        let _ = backend.overlap_aabb(PhysicsOverlapAABBQuery::new(bounds), filter.clone());
        let _ = backend.overlap_shape(
            PhysicsOverlapShapeQuery::new(shape, Float3::ZERO),
            filter.clone(),
        );
        // 9 sweepAABB / 10 sweepShape / 11 sweepShapeAll
        let _ = backend.sweep_aabb(
            PhysicsSweepAABBQuery::new(bounds, Float3::new(0.0, 1.0, 0.0)),
            filter.clone(),
        );
        let _ = backend.sweep_shape(sweep, filter.clone());
        let _ = backend.sweep_shape_all(sweep, filter, 1);
        // 12 detectTriggerFrame / 13 reset
        let _ = backend.detect_trigger_frame(1);
        backend.reset();
    }

    /// Swift's `*All` protocol-extension defaults return nothing when
    /// `maxHits <= 0`, and `NullPhysicsBackend` must inherit rather than override.
    #[test]
    fn all_variants_short_circuit_on_zero_max_hits() {
        let backend = NullPhysicsBackend::new();
        let query = PhysicsSweepShapeQuery::new(
            PhysicsQueryShape::Sphere { radius: 1.0 },
            Float3::ZERO,
            Float3::ZERO,
        );
        assert!(
            backend
                .sweep_shape_all(query, PhysicsQueryFilter::default(), 0)
                .is_empty()
        );
        assert!(
            backend
                .raycast_all(
                    PhysicsRaycastQuery::new(Float3::ZERO, Float3::new(0.0, 0.0, 1.0)),
                    PhysicsQueryFilter::default(),
                    0
                )
                .is_empty()
        );
    }
}
