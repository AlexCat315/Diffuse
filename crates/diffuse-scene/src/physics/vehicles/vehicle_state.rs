//! Vehicle command inputs and per-frame state stream.

use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::entity_id::EntityID;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VehicleCommand {
    pub throttle: f32,
    pub steering: f32,
    pub brake: f32,
    pub hand_brake: f32,
    pub manual_gear: Option<i64>,
    pub clutch: f32,
}

impl VehicleCommand {
    pub fn new(
        throttle: f32,
        steering: f32,
        brake: f32,
        hand_brake: f32,
        manual_gear: Option<i64>,
        clutch: f32,
    ) -> Self {
        // Swift clamps each axis; throttle/steering are signed, the rest are 0...1.
        VehicleCommand {
            throttle: throttle.clamp(-1.0, 1.0),
            steering: steering.clamp(-1.0, 1.0),
            brake: brake.clamp(0.0, 1.0),
            hand_brake: hand_brake.clamp(0.0, 1.0),
            manual_gear,
            clutch: clutch.clamp(0.0, 1.0),
        }
    }
}

impl Default for VehicleCommand {
    fn default() -> Self {
        VehicleCommand {
            throttle: 0.0,
            steering: 0.0,
            brake: 0.0,
            hand_brake: 0.0,
            manual_gear: None,
            clutch: 1.0,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct VehicleCommandFrameResource {
    pub commands: std::collections::BTreeMap<EntityID, VehicleCommand>,
}

impl VehicleCommandFrameResource {
    pub fn new(commands: std::collections::BTreeMap<EntityID, VehicleCommand>) -> Self {
        VehicleCommandFrameResource { commands }
    }

    pub fn empty() -> Self {
        VehicleCommandFrameResource::default()
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VehicleWheelState {
    pub index: i64,
    pub world_position: Float3,
    pub world_rotation: Float4,
    pub angular_velocity: f32,
    pub rotation_angle: f32,
    pub steer_angle: f32,
    pub suspension_length: f32,
    pub has_contact: bool,
    pub contact_entity: Option<EntityID>,
    pub contact_position: Float3,
    pub contact_normal: Float3,
}

impl VehicleWheelState {
    /// Swift's defaults: identity rotation, no contact, zero vectors.
    pub fn new(index: i64) -> Self {
        VehicleWheelState {
            index,
            world_position: Float3::ZERO,
            world_rotation: Float4::new(0.0, 0.0, 0.0, 1.0),
            angular_velocity: 0.0,
            rotation_angle: 0.0,
            steer_angle: 0.0,
            suspension_length: 0.0,
            has_contact: false,
            contact_entity: None,
            contact_position: Float3::ZERO,
            contact_normal: Float3::ZERO,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct VehicleState {
    pub entity: EntityID,
    pub forward_speed: f32,
    pub engine_rpm: f32,
    pub current_gear: i64,
    pub clutch_friction: f32,
    pub wheels: Vec<VehicleWheelState>,
}

impl VehicleState {
    pub fn new(entity: EntityID) -> Self {
        VehicleState {
            entity,
            forward_speed: 0.0,
            engine_rpm: 0.0,
            current_gear: 0,
            clutch_friction: 0.0,
            wheels: Vec::new(),
        }
    }

    pub fn with_state(
        entity: EntityID,
        forward_speed: f32,
        engine_rpm: f32,
        current_gear: i64,
        clutch_friction: f32,
        wheels: Vec<VehicleWheelState>,
    ) -> Self {
        VehicleState {
            entity,
            forward_speed,
            engine_rpm,
            current_gear,
            clutch_friction,
            wheels,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct VehicleStateFrameResource {
    pub states: std::collections::BTreeMap<EntityID, VehicleState>,
}

impl VehicleStateFrameResource {
    pub fn new(states: std::collections::BTreeMap<EntityID, VehicleState>) -> Self {
        VehicleStateFrameResource { states }
    }

    pub fn empty() -> Self {
        VehicleStateFrameResource::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_clamps_signed_and_unsigned_axes() {
        let command = VehicleCommand::new(5.0, -5.0, 5.0, -5.0, Some(2), 5.0);
        assert_eq!(command.throttle, 1.0);
        assert_eq!(command.steering, -1.0);
        assert_eq!(command.brake, 1.0);
        assert_eq!(command.hand_brake, 0.0);
        assert_eq!(command.clutch, 1.0);
        assert_eq!(command.manual_gear, Some(2));
    }

    #[test]
    fn default_command_releases_clutch_and_has_no_gear() {
        let command = VehicleCommand::default();
        assert_eq!(command.clutch, 1.0);
        assert_eq!(command.manual_gear, None);
        assert_eq!(command.throttle, 0.0);
    }

    #[test]
    fn wheel_state_defaults_to_identity_rotation_and_no_contact() {
        let wheel = VehicleWheelState::new(3);
        assert_eq!(wheel.index, 3);
        assert_eq!(wheel.world_rotation, Float4::new(0.0, 0.0, 0.0, 1.0));
        assert!(!wheel.has_contact);
        assert_eq!(wheel.contact_entity, None);
    }

    #[test]
    fn state_defaults_are_zeroed() {
        let state = VehicleState::new(EntityID::new(4, 0));
        assert_eq!(state.current_gear, 0);
        assert_eq!(state.forward_speed, 0.0);
        assert!(state.wheels.is_empty());
    }

    #[test]
    fn frame_resources_start_empty() {
        assert!(VehicleStateFrameResource::empty().states.is_empty());
        assert!(VehicleCommandFrameResource::empty().commands.is_empty());
    }
}
