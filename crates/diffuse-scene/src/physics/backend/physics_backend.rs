//! The physics backend trait.
//!
//! Swift declares `PhysicsBackend: AnyObject, Sendable`; the Rust port uses
//! `Send + Sync` so a backend can live behind a `Mutex` in the scheduler. The
//! two `*All` methods have Swift protocol-extension defaults, reproduced here as
//! provided methods.

use crate::physics::backend::physics_backend_capabilities::PhysicsBackendCapabilities;
use crate::physics::backend::physics_backend_context::{
    PhysicsPrepareContext, PhysicsPrepareResult, PhysicsStepContext, PhysicsStepResult,
};
use crate::physics::queries::physics_query_types::{
    PhysicsOverlapAABBQuery, PhysicsOverlapHit, PhysicsOverlapShapeQuery, PhysicsQueryFilter,
    PhysicsRaycastHit, PhysicsRaycastQuery, PhysicsSweepAABBQuery, PhysicsSweepHit,
    PhysicsSweepShapeQuery,
};
use crate::physics::queries::trigger_detection::TriggerFrameResource;

pub trait PhysicsBackend: Send + Sync {
    fn identifier(&self) -> &str;

    fn capabilities(&self) -> PhysicsBackendCapabilities;

    fn prepare(&mut self, context: PhysicsPrepareContext) -> PhysicsPrepareResult;

    fn step(&mut self, context: PhysicsStepContext) -> PhysicsStepResult;

    fn raycast(
        &self,
        query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsRaycastHit>;

    /// Swift's protocol-extension default: at most one hit, none when `max_hits <= 0`.
    fn raycast_all(
        &self,
        query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter,
        max_hits: usize,
    ) -> Vec<PhysicsRaycastHit> {
        if max_hits == 0 {
            return Vec::new();
        }
        self.raycast(query, filter).into_iter().collect()
    }

    fn overlap_aabb(
        &self,
        query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit>;

    fn overlap_shape(
        &self,
        query: PhysicsOverlapShapeQuery,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit>;

    fn sweep_aabb(
        &self,
        query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit>;

    fn sweep_shape(
        &self,
        query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit>;

    /// Swift's protocol-extension default: at most one hit, none when `max_hits <= 0`.
    fn sweep_shape_all(
        &self,
        query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter,
        max_hits: usize,
    ) -> Vec<PhysicsSweepHit> {
        if max_hits == 0 {
            return Vec::new();
        }
        self.sweep_shape(query, filter).into_iter().collect()
    }

    fn detect_trigger_frame(&self, max_event_count: usize) -> TriggerFrameResource;

    fn reset(&mut self);
}
