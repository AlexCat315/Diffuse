//! Virtual character controller components and their state stream.

use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::entity_id::{EntityID, RuntimeComponent};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CharacterStance {
    Standing,
    Crouching,
}

impl CharacterStance {
    /// `UInt8`-backed and `Codable`, so it persists as its raw value.
    pub const fn raw_value(&self) -> u8 {
        match self {
            CharacterStance::Standing => 0,
            CharacterStance::Crouching => 1,
        }
    }

    pub const fn from_raw_value(value: u8) -> Option<Self> {
        match value {
            0 => Some(CharacterStance::Standing),
            1 => Some(CharacterStance::Crouching),
            _ => None,
        }
    }
}

impl serde::Serialize for CharacterStance {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u8(self.raw_value())
    }
}

impl<'de> serde::Deserialize<'de> for CharacterStance {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = u8::deserialize(deserializer)?;
        CharacterStance::from_raw_value(value)
            .ok_or_else(|| serde::de::Error::custom(format!("Unknown character stance: {value}")))
    }
}

/// Authored configuration for a backend-simulated virtual character.
/// Character entities do not require a `RigidBody` or `Collider`; this component
/// owns the capsule used by the character solver.
#[derive(Clone, Debug, PartialEq)]
pub struct CharacterController {
    pub radius: f32,
    pub standing_half_height: f32,
    pub crouching_half_height: f32,
    pub center: Float3,
    pub max_slope_degrees: f32,
    pub step_height: f32,
    pub skin_width: f32,
    pub mass: f32,
    pub max_strength: f32,
    pub gravity_scale: f32,
    pub layer_id: u16,
    pub layer_mask: u16,
}

impl CharacterController {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        radius: f32,
        standing_half_height: f32,
        crouching_half_height: f32,
        center: Float3,
        max_slope_degrees: f32,
        step_height: f32,
        skin_width: f32,
        mass: f32,
        max_strength: f32,
        gravity_scale: f32,
        layer_id: u16,
        layer_mask: u16,
    ) -> Self {
        let standing = standing_half_height.max(0.01);
        CharacterController {
            radius: radius.max(0.01),
            standing_half_height: standing,
            // Clamped against the *already clamped* standing height.
            crouching_half_height: crouching_half_height.max(0.01).min(standing),
            center,
            max_slope_degrees: max_slope_degrees.clamp(0.0, 89.9),
            step_height: step_height.max(0.0),
            skin_width: skin_width.max(0.001),
            mass: mass.max(0.01),
            max_strength: max_strength.max(0.0),
            gravity_scale,
            layer_id,
            layer_mask,
        }
    }
}

impl Default for CharacterController {
    fn default() -> Self {
        CharacterController::new(
            0.4,
            0.6,
            0.25,
            Float3::ZERO,
            50.0,
            0.4,
            0.02,
            70.0,
            100.0,
            1.0,
            0,
            u16::MAX,
        )
    }
}

impl RuntimeComponent for CharacterController {}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CharacterCommand {
    pub desired_velocity: Float3,
    pub jump_requested: bool,
    pub jump_speed: f32,
    pub stance: CharacterStance,
}

impl CharacterCommand {
    pub fn new(
        desired_velocity: Float3,
        jump_requested: bool,
        jump_speed: f32,
        stance: CharacterStance,
    ) -> Self {
        CharacterCommand {
            desired_velocity,
            jump_requested,
            jump_speed: jump_speed.max(0.0),
            stance,
        }
    }
}

impl Default for CharacterCommand {
    fn default() -> Self {
        CharacterCommand {
            desired_velocity: Float3::ZERO,
            jump_requested: false,
            jump_speed: 8.0,
            stance: CharacterStance::Standing,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CharacterCommandFrameResource {
    pub commands: std::collections::BTreeMap<EntityID, CharacterCommand>,
}

impl CharacterCommandFrameResource {
    pub fn new(commands: std::collections::BTreeMap<EntityID, CharacterCommand>) -> Self {
        CharacterCommandFrameResource { commands }
    }

    pub fn empty() -> Self {
        CharacterCommandFrameResource::default()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CharacterGroundState {
    OnGround,
    OnSteepGround,
    NotSupported,
    InAir,
}

impl CharacterGroundState {
    pub const fn raw_value(&self) -> u8 {
        match self {
            CharacterGroundState::OnGround => 0,
            CharacterGroundState::OnSteepGround => 1,
            CharacterGroundState::NotSupported => 2,
            CharacterGroundState::InAir => 3,
        }
    }

    pub const fn from_raw_value(value: u8) -> Option<Self> {
        match value {
            0 => Some(CharacterGroundState::OnGround),
            1 => Some(CharacterGroundState::OnSteepGround),
            2 => Some(CharacterGroundState::NotSupported),
            3 => Some(CharacterGroundState::InAir),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CharacterState {
    pub entity: EntityID,
    pub position: Float3,
    pub rotation: Float4,
    pub linear_velocity: Float3,
    pub ground_state: CharacterGroundState,
    pub ground_normal: Float3,
    pub ground_velocity: Float3,
    pub ground_entity: Option<EntityID>,
    pub stance: CharacterStance,
}

impl CharacterState {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        entity: EntityID,
        position: Float3,
        rotation: Float4,
        linear_velocity: Float3,
        ground_state: CharacterGroundState,
        ground_normal: Float3,
        ground_velocity: Float3,
        ground_entity: Option<EntityID>,
        stance: CharacterStance,
    ) -> Self {
        CharacterState {
            entity,
            position,
            rotation,
            linear_velocity,
            ground_state,
            ground_normal,
            ground_velocity,
            ground_entity,
            stance,
        }
    }

    /// Convenience matching Swift's defaults (identity rotation, in air, standing).
    pub fn at_position(entity: EntityID, position: Float3) -> Self {
        CharacterState {
            entity,
            position,
            rotation: Float4::new(0.0, 0.0, 0.0, 1.0),
            linear_velocity: Float3::ZERO,
            ground_state: CharacterGroundState::InAir,
            ground_normal: Float3::ZERO,
            ground_velocity: Float3::ZERO,
            ground_entity: None,
            stance: CharacterStance::Standing,
        }
    }

    pub fn is_grounded(&self) -> bool {
        self.ground_state == CharacterGroundState::OnGround
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CharacterStateFrameResource {
    pub states: std::collections::BTreeMap<EntityID, CharacterState>,
}

impl CharacterStateFrameResource {
    pub fn new(states: std::collections::BTreeMap<EntityID, CharacterState>) -> Self {
        CharacterStateFrameResource { states }
    }

    pub fn empty() -> Self {
        CharacterStateFrameResource::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crouching_clamps_against_clamped_standing_height() {
        // standing clamps 0.0 -> 0.01, then crouching clamps to standing's clamped value.
        let controller = CharacterController::new(
            0.5,
            0.0,
            5.0,
            Float3::ZERO,
            50.0,
            0.4,
            0.02,
            70.0,
            100.0,
            1.0,
            0,
            0,
        );
        assert_eq!(controller.standing_half_height, 0.01);
        assert_eq!(controller.crouching_half_height, 0.01);
    }

    #[test]
    fn default_controller_matches_swift() {
        let controller = CharacterController::default();
        assert_eq!(controller.radius, 0.4);
        assert_eq!(controller.standing_half_height, 0.6);
        assert_eq!(controller.crouching_half_height, 0.25);
        assert_eq!(controller.max_slope_degrees, 50.0);
        assert_eq!(controller.mass, 70.0);
        assert_eq!(controller.layer_mask, u16::MAX);
    }

    #[test]
    fn slope_clamps_at_eighty_nine_point_nine() {
        let controller = CharacterController::new(
            0.4,
            0.6,
            0.25,
            Float3::ZERO,
            200.0,
            0.4,
            0.02,
            70.0,
            100.0,
            1.0,
            0,
            0,
        );
        assert_eq!(controller.max_slope_degrees, 89.9);
    }

    #[test]
    fn command_clamps_jump_speed_to_zero() {
        let clamped = CharacterCommand::new(Float3::ZERO, true, -2.0, CharacterStance::Standing);
        assert_eq!(clamped.jump_speed, 0.0);
        assert_eq!(CharacterCommand::default().jump_speed, 8.0);
    }

    #[test]
    fn stance_and_ground_state_round_trip() {
        assert_eq!(
            CharacterStance::from_raw_value(0),
            Some(CharacterStance::Standing)
        );
        assert_eq!(CharacterStance::Crouching.raw_value(), 1);
        assert_eq!(
            CharacterGroundState::from_raw_value(3),
            Some(CharacterGroundState::InAir)
        );
        assert_eq!(CharacterGroundState::OnSteepGround.raw_value(), 1);
    }

    #[test]
    fn grounded_helper_reflects_ground_state() {
        let mut state = CharacterState::at_position(EntityID::new(0, 0), Float3::ZERO);
        assert!(!state.is_grounded());
        state.ground_state = CharacterGroundState::OnGround;
        assert!(state.is_grounded());
    }
}
