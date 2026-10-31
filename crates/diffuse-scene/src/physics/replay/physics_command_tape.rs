//! Recorded physics commands for deterministic replay.
//!
//! Ported from `Engine/Sources/SceneRuntime/Physics/Replay/PhysicsCommandTape.swift`.
//!
//! Every per-entity command list is stored sorted by `entity.rawValue`, and the
//! destruction list by `(entity.rawValue, original offset)`. Both orderings are
//! what makes a tape replay identically to the original run, so they live in the
//! constructors rather than in the caller.

use diffuse_math::simd::simd_compat::Float3;

use crate::entity_id::EntityID;
use crate::physics::character_controller::CharacterCommand;
use crate::physics::destruction::DestructionCommand;
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::vehicles::vehicle_state::VehicleCommand;

/// `PhysicsRecordedBodyCommand` — forces and impulses applied to one body.
#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsRecordedBodyCommand {
    pub entity: EntityID,
    pub force: Float3,
    pub torque: Float3,
    pub linear_impulse: Float3,
    pub angular_impulse: Float3,
    pub wake: bool,
}

impl PhysicsRecordedBodyCommand {
    pub fn new(
        entity: EntityID,
        force: Float3,
        torque: Float3,
        linear_impulse: Float3,
        angular_impulse: Float3,
        wake: bool,
    ) -> Self {
        PhysicsRecordedBodyCommand {
            entity,
            force,
            torque,
            linear_impulse,
            angular_impulse,
            wake,
        }
    }

    /// Swift's defaults: every vector zero, `wake` true.
    pub fn for_entity(entity: EntityID) -> Self {
        PhysicsRecordedBodyCommand::new(
            entity,
            Float3::ZERO,
            Float3::ZERO,
            Float3::ZERO,
            Float3::ZERO,
            true,
        )
    }
}

/// `PhysicsRecordedCharacterCommand`.
#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsRecordedCharacterCommand {
    pub entity: EntityID,
    pub command: CharacterCommand,
}

impl PhysicsRecordedCharacterCommand {
    pub fn new(entity: EntityID, command: CharacterCommand) -> Self {
        PhysicsRecordedCharacterCommand { entity, command }
    }
}

/// `PhysicsRecordedVehicleCommand`.
#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsRecordedVehicleCommand {
    pub entity: EntityID,
    pub command: VehicleCommand,
}

impl PhysicsRecordedVehicleCommand {
    pub fn new(entity: EntityID, command: VehicleCommand) -> Self {
        PhysicsRecordedVehicleCommand { entity, command }
    }
}

/// `PhysicsCommandFrame` — one recorded frame plus the hashes it must reproduce.
#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsCommandFrame {
    pub delta_time_seconds: f64,
    pub settings: PhysicsSettingsResource,
    pub body_commands: Vec<PhysicsRecordedBodyCommand>,
    pub character_commands: Vec<PhysicsRecordedCharacterCommand>,
    pub vehicle_commands: Vec<PhysicsRecordedVehicleCommand>,
    pub destruction_commands: Vec<DestructionCommand>,
    pub expected_simulated_step: i64,
    pub expected_state_hash: u64,
}

impl PhysicsCommandFrame {
    /// `deltaTimeSeconds` floors at zero; the three per-entity lists sort by entity
    /// and destruction keeps submission order within one entity.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        delta_time_seconds: f64,
        settings: PhysicsSettingsResource,
        mut body_commands: Vec<PhysicsRecordedBodyCommand>,
        mut character_commands: Vec<PhysicsRecordedCharacterCommand>,
        mut vehicle_commands: Vec<PhysicsRecordedVehicleCommand>,
        destruction_commands: Vec<DestructionCommand>,
        expected_simulated_step: i64,
        expected_state_hash: u64,
    ) -> Self {
        body_commands.sort_by_key(|command| command.entity.raw_value());
        character_commands.sort_by_key(|command| command.entity.raw_value());
        vehicle_commands.sort_by_key(|command| command.entity.raw_value());
        let mut indexed: Vec<(usize, DestructionCommand)> =
            destruction_commands.into_iter().enumerate().collect();
        indexed.sort_by_key(|(offset, command)| (command.entity.raw_value(), *offset));
        PhysicsCommandFrame {
            delta_time_seconds: delta_time_seconds.max(0.0),
            settings,
            body_commands,
            character_commands,
            vehicle_commands,
            destruction_commands: indexed.into_iter().map(|(_, command)| command).collect(),
            expected_simulated_step,
            expected_state_hash,
        }
    }
}

/// `PhysicsCommandTape`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsCommandTape {
    pub frames: Vec<PhysicsCommandFrame>,
}

impl PhysicsCommandTape {
    pub fn new(frames: Vec<PhysicsCommandFrame>) -> Self {
        PhysicsCommandTape { frames }
    }
}

/// `PhysicsCommandRecordingResource` — the live recorder state.
#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsCommandRecordingResource {
    pub is_recording: bool,
    pub max_frames: i64,
    pub frames: Vec<PhysicsCommandFrame>,
}

impl PhysicsCommandRecordingResource {
    /// The frame cap floors at 1, and supplied frames are truncated to it.
    pub fn new(is_recording: bool, max_frames: i64, frames: Vec<PhysicsCommandFrame>) -> Self {
        let max_frames = max_frames.max(1);
        PhysicsCommandRecordingResource {
            is_recording,
            max_frames,
            frames: frames.into_iter().take(max_frames as usize).collect(),
        }
    }

    /// `static let inactive` — not recording, 36,000-frame cap, no frames.
    pub fn inactive() -> Self {
        PhysicsCommandRecordingResource::new(false, 36_000, Vec::new())
    }
}

impl Default for PhysicsCommandRecordingResource {
    fn default() -> Self {
        PhysicsCommandRecordingResource::inactive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::physics::character_controller::CharacterStance;

    fn settings() -> PhysicsSettingsResource {
        PhysicsSettingsResource::default()
    }

    fn frame(destruction: Vec<DestructionCommand>) -> PhysicsCommandFrame {
        PhysicsCommandFrame::new(
            0.25,
            settings(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            destruction,
            3,
            42,
        )
    }

    #[test]
    fn recording_resource_floors_cap_at_one_and_truncates() {
        let frames = vec![frame(Vec::new()), frame(Vec::new()), frame(Vec::new())];
        let recording = PhysicsCommandRecordingResource::new(true, 0, frames);
        assert_eq!(recording.max_frames, 1);
        assert_eq!(recording.frames.len(), 1);
        assert!(recording.is_recording);
    }

    #[test]
    fn inactive_recording_is_not_recording_with_thirty_six_thousand_cap() {
        let recording = PhysicsCommandRecordingResource::inactive();
        assert!(!recording.is_recording);
        assert_eq!(recording.max_frames, 36_000);
        assert!(recording.frames.is_empty());
        assert_eq!(recording, PhysicsCommandRecordingResource::default());
    }

    #[test]
    fn body_and_character_commands_sort_by_entity() {
        let high = EntityID::new(9, 0);
        let low = EntityID::new(2, 0);
        let frame = PhysicsCommandFrame::new(
            0.5,
            settings(),
            vec![
                PhysicsRecordedBodyCommand::for_entity(high),
                PhysicsRecordedBodyCommand::for_entity(low),
            ],
            vec![
                PhysicsRecordedCharacterCommand::new(high, CharacterCommand::default()),
                PhysicsRecordedCharacterCommand::new(low, CharacterCommand::default()),
            ],
            vec![
                PhysicsRecordedVehicleCommand::new(high, VehicleCommand::default()),
                PhysicsRecordedVehicleCommand::new(low, VehicleCommand::default()),
            ],
            Vec::new(),
            1,
            2,
        );
        assert_eq!(
            frame
                .body_commands
                .iter()
                .map(|command| command.entity)
                .collect::<Vec<_>>(),
            vec![low, high]
        );
        assert_eq!(
            frame.character_commands[0].entity, low,
            "character commands sort by entity"
        );
        assert_eq!(
            frame.vehicle_commands[0].entity, low,
            "vehicle commands sort by entity"
        );
    }

    #[test]
    fn destruction_commands_keep_submission_order_within_one_entity() {
        let entity = EntityID::new(4, 0);
        let frame = frame(vec![
            DestructionCommand::new(entity, 10.0, Float3::ZERO, None, false),
            DestructionCommand::new(entity, 20.0, Float3::ZERO, None, true),
        ]);
        assert_eq!(frame.destruction_commands.len(), 2);
        assert_eq!(frame.destruction_commands[0].damage, 10.0);
        assert!(!frame.destruction_commands[0].force_fracture);
        assert_eq!(frame.destruction_commands[1].damage, 20.0);
        assert!(frame.destruction_commands[1].force_fracture);
    }

    #[test]
    fn destruction_commands_sort_by_entity_first() {
        let frame = frame(vec![
            DestructionCommand::new(EntityID::new(7, 0), 1.0, Float3::ZERO, None, false),
            DestructionCommand::new(EntityID::new(3, 0), 2.0, Float3::ZERO, None, false),
        ]);
        assert_eq!(
            frame
                .destruction_commands
                .iter()
                .map(|command| command.entity)
                .collect::<Vec<_>>(),
            vec![EntityID::new(3, 0), EntityID::new(7, 0)]
        );
    }

    #[test]
    fn frame_floors_delta_time_and_keeps_hashes() {
        let frame = PhysicsCommandFrame::new(
            -2.0,
            settings(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            Vec::new(),
            7,
            u64::MAX,
        );
        assert_eq!(frame.delta_time_seconds, 0.0);
        assert_eq!(frame.expected_simulated_step, 7);
        assert_eq!(frame.expected_state_hash, u64::MAX);
    }

    #[test]
    fn character_stance_default_is_standing() {
        // Guards the command payload defaults used by recorded tapes.
        assert_eq!(
            CharacterCommand::default().stance,
            CharacterStance::Standing
        );
    }
}
