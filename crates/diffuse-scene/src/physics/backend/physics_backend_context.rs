//! Prepare/step contexts and their results.

use std::collections::BTreeMap;

use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_capabilities::PhysicsBackendCapabilities;
use crate::physics::backend::physics_descriptors::{
    PhysicsBodyDescriptor, PhysicsCharacterDescriptor, PhysicsConstraintDescriptor,
    PhysicsSoftBodyDescriptor, PhysicsVehicleDescriptor,
};
use crate::physics::character_controller::{CharacterCommand, CharacterState};
use crate::physics::physics_events::{PhysicsContactEvent, PhysicsJointBreakEvent};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::physics_types::PhysicsBackendError;
use crate::physics::soft_bodies::soft_body::SoftBodyMeshState;
use crate::physics::vehicles::vehicle_state::{VehicleCommand, VehicleState};
use crate::runtime_world::WorldTransform;

/// The remove variants hold a bare `EntityID` while the upsert variants hold a
/// full descriptor, so the payloads differ by orders of magnitude. Swift stores the
/// associated value out-of-line; `Box` reproduces that so every event stays small.
#[derive(Clone, Debug, PartialEq)]
pub enum PhysicsSyncEvent {
    BodyUpsert(Box<PhysicsBodyDescriptor>),
    BodyRemove(EntityID),
    ConstraintUpsert(Box<PhysicsConstraintDescriptor>),
    ConstraintRemove(EntityID),
    VehicleUpsert(Box<PhysicsVehicleDescriptor>),
    VehicleRemove(EntityID),
    SoftBodyUpsert(Box<PhysicsSoftBodyDescriptor>),
    SoftBodyRemove(EntityID),
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsPrepareContext {
    pub settings: PhysicsSettingsResource,
    pub delta_time_seconds: f64,
    pub active_bodies: Vec<PhysicsBodyDescriptor>,
    pub active_constraints: Vec<PhysicsConstraintDescriptor>,
    pub sync_events: Vec<PhysicsSyncEvent>,
    pub active_characters: Vec<PhysicsCharacterDescriptor>,
    pub active_vehicles: Vec<PhysicsVehicleDescriptor>,
    pub active_soft_bodies: Vec<PhysicsSoftBodyDescriptor>,
    /// Full snapshots remove native objects absent from `active_bodies` /
    /// `active_constraints`. Runtime simulation normally uses ordered incremental
    /// `sync_events` instead.
    pub is_full_snapshot: bool,
}

impl PhysicsPrepareContext {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        settings: PhysicsSettingsResource,
        delta_time_seconds: f64,
        active_bodies: Vec<PhysicsBodyDescriptor>,
        active_constraints: Vec<PhysicsConstraintDescriptor>,
        sync_events: Vec<PhysicsSyncEvent>,
        active_characters: Vec<PhysicsCharacterDescriptor>,
        active_vehicles: Vec<PhysicsVehicleDescriptor>,
        active_soft_bodies: Vec<PhysicsSoftBodyDescriptor>,
        is_full_snapshot: bool,
    ) -> Self {
        PhysicsPrepareContext {
            settings,
            delta_time_seconds,
            active_bodies,
            active_constraints,
            sync_events,
            active_characters,
            active_vehicles,
            active_soft_bodies,
            is_full_snapshot,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsPrepareResult {
    pub synchronized_bodies: i64,
    pub synchronized_constraints: i64,
    pub removed_bodies: i64,
    pub removed_constraints: i64,
    pub synchronized_vehicles: i64,
    pub removed_vehicles: i64,
    pub synchronized_soft_bodies: i64,
    pub removed_soft_bodies: i64,
    pub error: Option<PhysicsBackendError>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsStepContext {
    pub settings: PhysicsSettingsResource,
    pub step_delta_seconds: f64,
    pub step_index: i64,
    pub active_bodies: Vec<PhysicsBodyDescriptor>,
    pub active_constraints: Vec<PhysicsConstraintDescriptor>,
    pub active_characters: Vec<PhysicsCharacterDescriptor>,
    pub character_commands: BTreeMap<EntityID, CharacterCommand>,
    pub active_vehicles: Vec<PhysicsVehicleDescriptor>,
    pub vehicle_commands: BTreeMap<EntityID, VehicleCommand>,
    pub active_soft_bodies: Vec<PhysicsSoftBodyDescriptor>,
}

impl PhysicsStepContext {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        settings: PhysicsSettingsResource,
        step_delta_seconds: f64,
        step_index: i64,
        active_bodies: Vec<PhysicsBodyDescriptor>,
        active_constraints: Vec<PhysicsConstraintDescriptor>,
        active_characters: Vec<PhysicsCharacterDescriptor>,
        character_commands: BTreeMap<EntityID, CharacterCommand>,
        active_vehicles: Vec<PhysicsVehicleDescriptor>,
        vehicle_commands: BTreeMap<EntityID, VehicleCommand>,
        active_soft_bodies: Vec<PhysicsSoftBodyDescriptor>,
    ) -> Self {
        PhysicsStepContext {
            settings,
            step_delta_seconds,
            step_index,
            active_bodies,
            active_constraints,
            active_characters,
            character_commands,
            active_vehicles,
            vehicle_commands,
            active_soft_bodies,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsBodyWriteback {
    pub entity: EntityID,
    pub world_transform: Option<WorldTransform>,
    pub linear_velocity: Option<diffuse_math::simd::simd_compat::Float3>,
    pub angular_velocity: Option<diffuse_math::simd::simd_compat::Float3>,
    pub is_sleeping: Option<bool>,
}

impl PhysicsBodyWriteback {
    pub fn new(entity: EntityID) -> Self {
        PhysicsBodyWriteback {
            entity,
            world_transform: None,
            linear_velocity: None,
            angular_velocity: None,
            is_sleeping: None,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsStepResult {
    pub body_count: i64,
    pub constraint_count: i64,
    pub contact_count: i64,
    pub writebacks: Vec<PhysicsBodyWriteback>,
    pub contact_events: Vec<PhysicsContactEvent>,
    pub joint_break_events: Vec<PhysicsJointBreakEvent>,
    pub character_states: Vec<CharacterState>,
    pub vehicle_states: Vec<VehicleState>,
    pub soft_body_states: Vec<SoftBodyMeshState>,
    pub error: Option<PhysicsBackendError>,
}

impl PhysicsStepResult {
    pub fn with_error(error: PhysicsBackendError) -> Self {
        PhysicsStepResult {
            error: Some(error),
            ..PhysicsStepResult::default()
        }
    }

    /// The optional features this frame's descriptors depend on.
    pub fn required_capabilities(&self) -> PhysicsBackendCapabilities {
        let mut capabilities = PhysicsBackendCapabilities::new(0);
        if !self.character_states.is_empty() {
            capabilities.insert(PhysicsBackendCapabilities::CHARACTERS);
        }
        if !self.vehicle_states.is_empty() {
            capabilities.insert(PhysicsBackendCapabilities::VEHICLES);
        }
        if !self.soft_body_states.is_empty() {
            capabilities.insert(PhysicsBackendCapabilities::SOFT_BODIES);
        }
        capabilities
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_step_result_is_empty() {
        let result = PhysicsStepResult::default();
        assert_eq!(result.body_count, 0);
        assert!(result.writebacks.is_empty());
        assert!(result.error.is_none());
    }

    #[test]
    fn with_error_sets_only_the_error() {
        let result = PhysicsStepResult::with_error(PhysicsBackendError::new(
            crate::physics::physics_types::PhysicsBackendErrorCode::UpdateFailed,
            "boom",
        ));
        assert!(result.error.is_some());
        assert_eq!(result.body_count, 0);
    }

    #[test]
    fn required_capabilities_reflects_state_presence() {
        let mut result = PhysicsStepResult::default();
        assert!(result.required_capabilities().is_empty());

        result.character_states.push(CharacterState::at_position(
            EntityID::new(0, 0),
            diffuse_math::simd::simd_compat::Float3::ZERO,
        ));
        assert!(
            result
                .required_capabilities()
                .contains(PhysicsBackendCapabilities::CHARACTERS)
        );
        assert!(
            !result
                .required_capabilities()
                .contains(PhysicsBackendCapabilities::VEHICLES)
        );
    }

    #[test]
    fn writeback_defaults_to_no_updates() {
        let writeback = PhysicsBodyWriteback::new(EntityID::new(2, 0));
        assert!(writeback.world_transform.is_none());
        assert!(writeback.linear_velocity.is_none());
        assert!(writeback.is_sleeping.is_none());
    }

    #[test]
    fn prepare_result_defaults_are_zero() {
        let result = PhysicsPrepareResult::default();
        assert_eq!(result.synchronized_bodies, 0);
        assert_eq!(result.removed_soft_bodies, 0);
        assert!(result.error.is_none());
    }
}
