//! Runtime descriptors handed to a physics backend.
//!
//! These are the persistence boundary: engine handles never escape into scene
//! documents or ECS components.

use crate::entity_id::EntityID;
use crate::physics::character_controller::CharacterController;
use crate::physics::collider::Collider;
use crate::physics::joints::physics_joint::Constraint;
use crate::physics::queries::spatial_queries::MeshColliderGeometry;
use crate::physics::rigid_body::RigidBody;
use crate::physics::soft_bodies::cloth::Cloth;
use crate::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};
use crate::physics::vehicles::vehicle::Vehicle;
use crate::runtime_world::{LocalTransform, WorldTransform};

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsBodyDescriptor {
    pub entity: EntityID,
    pub local_transform: LocalTransform,
    pub world_transform: WorldTransform,
    pub rigid_body: Option<RigidBody>,
    pub collider: Option<Collider>,
    pub mesh_geometry: Option<MeshColliderGeometry>,
}

impl PhysicsBodyDescriptor {
    pub fn new(
        entity: EntityID,
        local_transform: LocalTransform,
        world_transform: WorldTransform,
        rigid_body: Option<RigidBody>,
        collider: Option<Collider>,
        mesh_geometry: Option<MeshColliderGeometry>,
    ) -> Self {
        PhysicsBodyDescriptor {
            entity,
            local_transform,
            world_transform,
            rigid_body,
            collider,
            mesh_geometry,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsConstraintDescriptor {
    pub entity: EntityID,
    pub world_transform: WorldTransform,
    pub constraint: Constraint,
}

impl PhysicsConstraintDescriptor {
    pub fn new(entity: EntityID, world_transform: WorldTransform, constraint: Constraint) -> Self {
        PhysicsConstraintDescriptor {
            entity,
            world_transform,
            constraint,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsCharacterDescriptor {
    pub entity: EntityID,
    pub world_transform: WorldTransform,
    pub controller: CharacterController,
}

impl PhysicsCharacterDescriptor {
    pub fn new(
        entity: EntityID,
        world_transform: WorldTransform,
        controller: CharacterController,
    ) -> Self {
        PhysicsCharacterDescriptor {
            entity,
            world_transform,
            controller,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsVehicleDescriptor {
    pub entity: EntityID,
    pub vehicle: Vehicle,
}

impl PhysicsVehicleDescriptor {
    pub fn new(entity: EntityID, vehicle: Vehicle) -> Self {
        PhysicsVehicleDescriptor { entity, vehicle }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum PhysicsSoftBodyTopology {
    Cloth(Cloth),
    SurfaceMesh(SoftBodyMesh, Option<MeshColliderGeometry>),
    Invalid,
}

impl PhysicsSoftBodyTopology {
    pub fn vertex_count(&self) -> i64 {
        match self {
            PhysicsSoftBodyTopology::Cloth(cloth) => cloth.vertex_count(),
            PhysicsSoftBodyTopology::SurfaceMesh(_, geometry) => geometry
                .as_ref()
                .map_or(0, |geometry| geometry.positions.len() as i64),
            PhysicsSoftBodyTopology::Invalid => 0,
        }
    }

    pub fn triangle_indices(&self) -> Vec<u32> {
        match self {
            PhysicsSoftBodyTopology::Cloth(cloth) => cloth.triangle_indices(),
            PhysicsSoftBodyTopology::SurfaceMesh(_, geometry) => geometry
                .as_ref()
                .map_or_else(Vec::new, |geometry| geometry.triangle_indices.clone()),
            PhysicsSoftBodyTopology::Invalid => Vec::new(),
        }
    }

    pub fn fixed_vertex_indices(&self) -> Vec<i64> {
        match self {
            PhysicsSoftBodyTopology::Cloth(cloth) => cloth.fixed_vertex_indices.clone(),
            PhysicsSoftBodyTopology::SurfaceMesh(mesh, _) => mesh.fixed_vertex_indices.clone(),
            PhysicsSoftBodyTopology::Invalid => Vec::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsSoftBodyDescriptor {
    pub entity: EntityID,
    pub world_transform: WorldTransform,
    pub soft_body: SoftBody,
    pub topology: PhysicsSoftBodyTopology,
}

impl PhysicsSoftBodyDescriptor {
    pub fn new(
        entity: EntityID,
        world_transform: WorldTransform,
        soft_body: SoftBody,
        topology: PhysicsSoftBodyTopology,
    ) -> Self {
        PhysicsSoftBodyDescriptor {
            entity,
            world_transform,
            soft_body,
            topology,
        }
    }

    /// Convenience initializer for cloth-backed soft bodies.
    pub fn from_cloth(
        entity: EntityID,
        world_transform: WorldTransform,
        soft_body: SoftBody,
        cloth: Cloth,
    ) -> Self {
        PhysicsSoftBodyDescriptor::new(
            entity,
            world_transform,
            soft_body,
            PhysicsSoftBodyTopology::Cloth(cloth),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::physics::collider::ColliderShape;
    use crate::physics::joints::physics_joint::PhysicsJoint;
    use crate::physics::joints::physics_joint_configuration::PhysicsJointConfiguration;
    use crate::physics::soft_bodies::cloth::ClothBendType;
    use diffuse_math::simd::simd_compat::Float3;

    fn transforms() -> (LocalTransform, WorldTransform) {
        (LocalTransform::IDENTITY, WorldTransform::IDENTITY)
    }

    #[test]
    fn body_descriptor_keeps_optional_components() {
        let (local, world) = transforms();
        let descriptor = PhysicsBodyDescriptor::new(
            EntityID::new(1, 0),
            local,
            world,
            Some(RigidBody::default()),
            Some(Collider::with_shape(ColliderShape::Sphere {
                radius: 1.0,
                center: Float3::ZERO,
            })),
            None,
        );
        assert!(descriptor.rigid_body.is_some());
        assert!(descriptor.collider.is_some());
        assert!(descriptor.mesh_geometry.is_none());
    }

    #[test]
    fn constraint_descriptor_wraps_constraint() {
        let (_, world) = transforms();
        let joint = PhysicsJoint::new(
            PhysicsJointConfiguration::Point,
            EntityID::new(0, 0),
            EntityID::new(1, 0),
            Float3::ZERO,
            Float3::ZERO,
            true,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
        );
        let descriptor = PhysicsConstraintDescriptor::new(EntityID::new(2, 0), world, joint);
        assert_eq!(
            descriptor.constraint.constraint_type(),
            crate::physics::joints::physics_joint_configuration::PhysicsJointKind::PointToPoint
        );
    }

    #[test]
    fn cloth_topology_reports_grid_counts() {
        let cloth = Cloth::new(3, 3, 0.2, vec![0, 1, 2], 0.0, 0.0, 0.0, ClothBendType::None);
        let topology = PhysicsSoftBodyTopology::Cloth(cloth);
        assert_eq!(topology.vertex_count(), 9);
        // (3-1) * (3-1) * 6 = 24
        assert_eq!(topology.triangle_indices().len(), 24);
        assert_eq!(topology.fixed_vertex_indices(), vec![0, 1, 2]);
    }

    #[test]
    fn surface_mesh_topology_uses_geometry_counts() {
        let geometry = MeshColliderGeometry::new(
            vec![Float3::ZERO, Float3::ZERO, Float3::ZERO],
            vec![0, 1, 2],
            Vec::new(),
            Vec::new(),
            None,
            1,
        );
        let mesh = SoftBodyMesh::new(None, vec![4], 0.0, 0.0, 0.0, 0.0, ClothBendType::Dihedral);
        let topology = PhysicsSoftBodyTopology::SurfaceMesh(mesh, Some(geometry));
        assert_eq!(topology.vertex_count(), 3);
        assert_eq!(topology.triangle_indices(), vec![0, 1, 2]);
        assert_eq!(topology.fixed_vertex_indices(), vec![4]);
    }

    #[test]
    fn surface_mesh_without_geometry_reports_zero() {
        let mesh = SoftBodyMesh::new(
            None,
            Vec::new(),
            0.0,
            0.0,
            0.0,
            0.0,
            ClothBendType::Dihedral,
        );
        let topology = PhysicsSoftBodyTopology::SurfaceMesh(mesh, None);
        assert_eq!(topology.vertex_count(), 0);
        assert!(topology.triangle_indices().is_empty());
    }

    #[test]
    fn invalid_topology_reports_nothing() {
        let topology = PhysicsSoftBodyTopology::Invalid;
        assert_eq!(topology.vertex_count(), 0);
        assert!(topology.triangle_indices().is_empty());
        assert!(topology.fixed_vertex_indices().is_empty());
    }

    #[test]
    fn from_cloth_wraps_topology() {
        let (_, world) = transforms();
        let descriptor = PhysicsSoftBodyDescriptor::from_cloth(
            EntityID::new(0, 0),
            world,
            SoftBody::default(),
            Cloth::default(),
        );
        assert!(matches!(
            descriptor.topology,
            PhysicsSoftBodyTopology::Cloth(_)
        ));
    }

    #[test]
    fn vehicle_descriptor_wraps_vehicle() {
        let descriptor = PhysicsVehicleDescriptor::new(EntityID::new(0, 0), Vehicle::wheeled());
        assert_eq!(descriptor.vehicle.wheels.len(), 4);
    }
}
