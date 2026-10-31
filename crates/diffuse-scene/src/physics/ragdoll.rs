//! Ragdoll rig mapping and simulation state.

use diffuse_math::simd::simd_compat::{Float4x4, MATRIX_IDENTITY_FLOAT4X4};

use crate::entity_id::{EntityID, RuntimeComponent};
use crate::physics::rigid_body::RigidBodyMotionType;
use crate::runtime_world::WorldTransform;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RagdollMode {
    Animated,
    Simulated,
    Blended,
}

impl RagdollMode {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            RagdollMode::Animated => "animated",
            RagdollMode::Simulated => "simulated",
            RagdollMode::Blended => "blended",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "animated" => Some(RagdollMode::Animated),
            "simulated" => Some(RagdollMode::Simulated),
            "blended" => Some(RagdollMode::Blended),
            _ => None,
        }
    }
}

/// Maps one rendered skin palette entry to a physics-body entity.
/// `body_from_palette` converts the palette-space bone transform to the desired
/// rigid-body transform.
#[derive(Clone, Debug, PartialEq)]
pub struct RagdollBoneMapping {
    pub bone_name: String,
    pub palette_index: i64,
    pub body_entity: EntityID,
    pub joint_entity: Option<EntityID>,
    pub body_from_palette: Float4x4,
    pub simulated_motion_type: RigidBodyMotionType,
    pub is_simulation_enabled: bool,
    pub blend_weight: f32,
}

impl RagdollBoneMapping {
    /// Swift's defaults: identity palette transform, dynamic body, enabled, weight 1.
    pub fn new(bone_name: impl Into<String>, palette_index: i64, body_entity: EntityID) -> Self {
        RagdollBoneMapping {
            bone_name: bone_name.into(),
            palette_index: palette_index.max(0),
            body_entity,
            joint_entity: None,
            body_from_palette: MATRIX_IDENTITY_FLOAT4X4,
            simulated_motion_type: RigidBodyMotionType::Dynamic,
            is_simulation_enabled: true,
            blend_weight: 1.0,
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn with_mapping(
        bone_name: impl Into<String>,
        palette_index: i64,
        body_entity: EntityID,
        joint_entity: Option<EntityID>,
        body_from_palette: Float4x4,
        simulated_motion_type: RigidBodyMotionType,
        is_simulation_enabled: bool,
        blend_weight: f32,
    ) -> Self {
        RagdollBoneMapping {
            bone_name: bone_name.into(),
            palette_index: palette_index.max(0),
            body_entity,
            joint_entity,
            body_from_palette,
            simulated_motion_type,
            is_simulation_enabled,
            blend_weight: blend_weight.clamp(0.0, 1.0),
        }
    }
}

/// Authored ragdoll mapping stored on the skinned-mesh/root entity.
#[derive(Clone, Debug, PartialEq)]
pub struct Ragdoll {
    pub mode: RagdollMode,
    pub blend_weight: f32,
    pub is_enabled: bool,
    pub bones: Vec<RagdollBoneMapping>,
}

impl Ragdoll {
    pub fn new(
        mode: RagdollMode,
        blend_weight: f32,
        is_enabled: bool,
        bones: Vec<RagdollBoneMapping>,
    ) -> Self {
        // Stable ordering: palette index, then body entity raw value.
        let mut bones = bones;
        bones.sort_by(|lhs, rhs| {
            if lhs.palette_index != rhs.palette_index {
                return lhs.palette_index.cmp(&rhs.palette_index);
            }
            lhs.body_entity
                .raw_value()
                .cmp(&rhs.body_entity.raw_value())
        });
        Ragdoll {
            mode,
            blend_weight: blend_weight.clamp(0.0, 1.0),
            is_enabled,
            bones,
        }
    }
}

impl Default for Ragdoll {
    fn default() -> Self {
        Ragdoll {
            mode: RagdollMode::Animated,
            blend_weight: 1.0,
            is_enabled: true,
            bones: Vec::new(),
        }
    }
}

impl RuntimeComponent for Ragdoll {}

#[derive(Clone, Debug, PartialEq)]
pub struct RagdollBoneState {
    pub bone_name: String,
    pub palette_index: i64,
    pub body_entity: EntityID,
    pub world_transform: WorldTransform,
    pub is_simulated: bool,
}

impl RagdollBoneState {
    pub fn new(
        bone_name: impl Into<String>,
        palette_index: i64,
        body_entity: EntityID,
        world_transform: WorldTransform,
        is_simulated: bool,
    ) -> Self {
        RagdollBoneState {
            bone_name: bone_name.into(),
            palette_index,
            body_entity,
            world_transform,
            is_simulated,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RagdollState {
    pub entity: EntityID,
    pub mode: RagdollMode,
    pub bones: Vec<RagdollBoneState>,
}

impl RagdollState {
    pub fn new(entity: EntityID, mode: RagdollMode, bones: Vec<RagdollBoneState>) -> Self {
        RagdollState {
            entity,
            mode,
            bones,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RagdollStateFrameResource {
    pub states: std::collections::BTreeMap<EntityID, RagdollState>,
}

impl RagdollStateFrameResource {
    pub fn new(states: std::collections::BTreeMap<EntityID, RagdollState>) -> Self {
        RagdollStateFrameResource { states }
    }

    pub fn empty() -> Self {
        RagdollStateFrameResource::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mapping(palette_index: i64, body: u32) -> RagdollBoneMapping {
        RagdollBoneMapping::new("bone", palette_index, EntityID::new(body, 0))
    }

    #[test]
    fn bone_mapping_clamps_index_and_weight() {
        let value = RagdollBoneMapping::with_mapping(
            "bone",
            -3,
            EntityID::new(0, 0),
            None,
            MATRIX_IDENTITY_FLOAT4X4,
            RigidBodyMotionType::Dynamic,
            true,
            5.0,
        );
        assert_eq!(value.palette_index, 0);
        assert_eq!(value.blend_weight, 1.0);
    }

    #[test]
    fn ragdoll_sorts_bones_by_palette_then_entity() {
        let ragdoll = Ragdoll::new(
            RagdollMode::Simulated,
            0.5,
            true,
            vec![mapping(2, 1), mapping(1, 9), mapping(1, 3)],
        );
        assert_eq!(ragdoll.bones[0].palette_index, 1);
        assert_eq!(ragdoll.bones[0].body_entity, EntityID::new(3, 0));
        assert_eq!(ragdoll.bones[1].body_entity, EntityID::new(9, 0));
        assert_eq!(ragdoll.bones[2].palette_index, 2);
    }

    #[test]
    fn ragdoll_clamps_blend_weight() {
        let ragdoll = Ragdoll::new(RagdollMode::Blended, 9.0, true, Vec::new());
        assert_eq!(ragdoll.blend_weight, 1.0);
        let negative = Ragdoll::new(RagdollMode::Blended, -9.0, true, Vec::new());
        assert_eq!(negative.blend_weight, 0.0);
    }

    #[test]
    fn default_ragdoll_is_animated_and_enabled() {
        let ragdoll = Ragdoll::default();
        assert_eq!(ragdoll.mode, RagdollMode::Animated);
        assert!(ragdoll.is_enabled);
        assert_eq!(ragdoll.blend_weight, 1.0);
    }

    #[test]
    fn mode_round_trips() {
        for mode in [
            RagdollMode::Animated,
            RagdollMode::Simulated,
            RagdollMode::Blended,
        ] {
            assert_eq!(RagdollMode::from_raw_value(mode.raw_value()), Some(mode));
        }
        assert_eq!(RagdollMode::from_raw_value("Animated"), None);
    }
}
