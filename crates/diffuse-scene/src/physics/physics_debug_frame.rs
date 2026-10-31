//! Debug-draw descriptions of the physics world for one frame.
//!
//! Ported from `Engine/Sources/SceneRuntime/Physics/PhysicsDebugFrame.swift`.
//! These are renderer-facing value snapshots — nothing here owns engine handles.

use diffuse_math::simd::simd_compat::Float3;

use crate::entity_id::EntityID;
use crate::physics::character_controller::CharacterState;
use crate::physics::collider::{ColliderShape, ColliderShapeInstance, SpatialAABB};
use crate::physics::joints::physics_joint::Constraint;
use crate::physics::joints::physics_joint_configuration::{
    PhysicsJointConfiguration, PhysicsJointKind,
};
use crate::physics::physics_events::PhysicsContactEvent;
use crate::runtime_world::WorldTransform;

/// `PhysicsDebugBody`.
#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsDebugBody {
    pub entity: EntityID,
    pub shape: ColliderShape,
    pub shapes: Vec<ColliderShapeInstance>,
    pub world_transform: WorldTransform,
    pub bounds: SpatialAABB,
    pub motion_type: crate::physics::rigid_body::RigidBodyMotionType,
    pub is_trigger: bool,
    pub is_sleeping: bool,
}

impl PhysicsDebugBody {
    /// `shapes` defaults to a single instance built from `shape`, so a caller with
    /// no compound collider still gets one drawable child.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        entity: EntityID,
        shape: ColliderShape,
        shapes: Option<Vec<ColliderShapeInstance>>,
        world_transform: WorldTransform,
        bounds: SpatialAABB,
        motion_type: crate::physics::rigid_body::RigidBodyMotionType,
        is_trigger: bool,
        is_sleeping: bool,
    ) -> Self {
        PhysicsDebugBody {
            entity,
            shape: shape.clone(),
            shapes: shapes.unwrap_or_else(|| vec![ColliderShapeInstance::new(shape)]),
            world_transform,
            bounds,
            motion_type,
            is_trigger,
            is_sleeping,
        }
    }
}

/// `PhysicsDebugConstraint` — a flattened copy of a joint for the debug renderer.
#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsDebugConstraint {
    pub entity: EntityID,
    pub constraint_type: PhysicsJointKind,
    pub configuration: PhysicsJointConfiguration,
    pub entity_a: EntityID,
    pub entity_b: EntityID,
    pub pivot_a: Float3,
    pub pivot_b: Float3,
    pub axis_a: Float3,
    pub axis_b: Float3,
    pub minimum_limit: f32,
    pub maximum_limit: f32,
    pub break_force: f32,
    pub break_torque: f32,
    pub is_enabled: bool,
}

impl PhysicsDebugConstraint {
    /// `init(entity:constraint:)`.
    pub fn new(entity: EntityID, constraint: &Constraint) -> Self {
        PhysicsDebugConstraint {
            entity,
            constraint_type: constraint.constraint_type(),
            configuration: constraint.configuration,
            entity_a: constraint.entity_a,
            entity_b: constraint.entity_b,
            pivot_a: constraint.pivot_a,
            pivot_b: constraint.pivot_b,
            axis_a: constraint.axis_a(),
            axis_b: constraint.axis_b(),
            minimum_limit: constraint.min_limit(),
            maximum_limit: constraint.max_limit(),
            break_force: constraint.break_force,
            break_torque: constraint.break_torque,
            is_enabled: constraint.is_enabled,
        }
    }
}

/// A breakable edge of a destructible source, in world space.
#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsDebugDestructionConnection {
    pub source_entity: EntityID,
    pub connection_id: u32,
    pub fragment_a: u32,
    pub fragment_b: u32,
    pub world_point_a: Float3,
    pub world_point_b: Float3,
    pub is_broken: bool,
    pub is_source_fractured: bool,
}

impl PhysicsDebugDestructionConnection {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        source_entity: EntityID,
        connection_id: u32,
        fragment_a: u32,
        fragment_b: u32,
        world_point_a: Float3,
        world_point_b: Float3,
        is_broken: bool,
        is_source_fractured: bool,
    ) -> Self {
        PhysicsDebugDestructionConnection {
            source_entity,
            connection_id,
            fragment_a,
            fragment_b,
            world_point_a,
            world_point_b,
            is_broken,
            is_source_fractured,
        }
    }
}

/// `PhysicsDebugFrameResource`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsDebugFrameResource {
    pub bodies: Vec<PhysicsDebugBody>,
    pub constraints: Vec<PhysicsDebugConstraint>,
    pub contacts: Vec<PhysicsContactEvent>,
    pub characters: Vec<CharacterState>,
    pub destruction_connections: Vec<PhysicsDebugDestructionConnection>,
}

impl PhysicsDebugFrameResource {
    pub fn new(
        bodies: Vec<PhysicsDebugBody>,
        constraints: Vec<PhysicsDebugConstraint>,
        contacts: Vec<PhysicsContactEvent>,
        characters: Vec<CharacterState>,
        destruction_connections: Vec<PhysicsDebugDestructionConnection>,
    ) -> Self {
        PhysicsDebugFrameResource {
            bodies,
            constraints,
            contacts,
            characters,
            destruction_connections,
        }
    }

    /// `static let empty`.
    pub fn empty() -> Self {
        PhysicsDebugFrameResource::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::physics::rigid_body::RigidBodyMotionType;

    #[test]
    fn body_defaults_to_one_shape_instance_from_shape() {
        let shape = ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        };
        let body = PhysicsDebugBody::new(
            EntityID::new(1, 0),
            shape.clone(),
            None,
            WorldTransform::IDENTITY,
            SpatialAABB::new(Float3::ZERO, Float3::ZERO),
            RigidBodyMotionType::Static,
            false,
            false,
        );
        assert_eq!(body.shapes.len(), 1);
        assert_eq!(body.shapes[0].shape, shape);
        assert_eq!(body.shapes[0].local_scale, Float3::ONE);
    }

    #[test]
    fn body_keeps_supplied_shapes() {
        let shape = ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        };
        let supplied = vec![
            ColliderShapeInstance::new(shape.clone()),
            ColliderShapeInstance::new(shape.clone()),
        ];
        let body = PhysicsDebugBody::new(
            EntityID::new(1, 0),
            shape,
            Some(supplied.clone()),
            WorldTransform::IDENTITY,
            SpatialAABB::new(Float3::ZERO, Float3::ZERO),
            RigidBodyMotionType::Dynamic,
            true,
            true,
        );
        assert_eq!(body.shapes, supplied);
        assert!(body.is_trigger);
        assert!(body.is_sleeping);
    }

    #[test]
    fn empty_frame_is_all_empty() {
        let frame = PhysicsDebugFrameResource::empty();
        assert!(frame.bodies.is_empty());
        assert!(frame.constraints.is_empty());
        assert!(frame.contacts.is_empty());
        assert!(frame.characters.is_empty());
        assert!(frame.destruction_connections.is_empty());
    }
}
