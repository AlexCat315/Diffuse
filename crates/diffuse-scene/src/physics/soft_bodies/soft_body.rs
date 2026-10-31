//! Deformable soft-body components and their state stream.

use diffuse_math::simd::simd_compat::Float3;

use crate::entity_id::{EntityID, RuntimeComponent};
use crate::physics::soft_bodies::cloth::ClothBendType;

/// An arbitrary triangle surface used as soft-body topology.
///
/// Geometry remains in `MeshColliderGeometryResource`, keyed by `resource_id`, so
/// scenes and prefabs serialize only a stable asset reference and constraint
/// configuration instead of duplicating large vertex/index arrays.
#[derive(Clone, Debug, PartialEq)]
pub struct SoftBodyMesh {
    pub resource_id: Option<String>,
    pub fixed_vertex_indices: Vec<i64>,
    pub compliance: f32,
    pub shear_compliance: f32,
    pub bend_compliance: f32,
    pub volume_compliance: f32,
    pub bend_type: ClothBendType,
}

impl SoftBodyMesh {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        resource_id: Option<String>,
        fixed_vertex_indices: Vec<i64>,
        compliance: f32,
        shear_compliance: f32,
        bend_compliance: f32,
        volume_compliance: f32,
        bend_type: ClothBendType,
    ) -> Self {
        // Swift trims whitespace and treats an empty result as `nil`.
        let resource_id = resource_id.and_then(|value| {
            let trimmed = value.trim_matches(|c: char| c.is_whitespace()).to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        });
        let mut fixed: Vec<i64> = fixed_vertex_indices
            .into_iter()
            .filter(|index| *index >= 0)
            .collect();
        fixed.sort_unstable();
        fixed.dedup();
        SoftBodyMesh {
            resource_id,
            fixed_vertex_indices: fixed,
            compliance: compliance.max(0.0),
            shear_compliance: shear_compliance.max(0.0),
            bend_compliance: bend_compliance.max(0.0),
            volume_compliance: volume_compliance.max(0.0),
            bend_type,
        }
    }
}

impl Default for SoftBodyMesh {
    fn default() -> Self {
        SoftBodyMesh::new(
            None,
            Vec::new(),
            1.0e-5,
            1.0e-5,
            1.0e-5,
            1.0e-6,
            ClothBendType::Dihedral,
        )
    }
}

impl RuntimeComponent for SoftBodyMesh {}

/// Simulation and collision settings shared by deformable assets.
#[derive(Clone, Debug, PartialEq)]
pub struct SoftBody {
    pub vertex_mass: f32,
    pub pressure: f32,
    pub linear_damping: f32,
    pub friction: f32,
    pub restitution: f32,
    pub gravity_scale: f32,
    pub vertex_radius: f32,
    pub solver_iterations: i64,
    pub max_linear_velocity: f32,
    pub layer_id: u16,
    pub layer_mask: u16,
    pub allow_sleep: bool,
    pub faces_double_sided: bool,
    pub self_collision: bool,
    pub is_enabled: bool,
}

impl SoftBody {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        vertex_mass: f32,
        pressure: f32,
        linear_damping: f32,
        friction: f32,
        restitution: f32,
        gravity_scale: f32,
        vertex_radius: f32,
        solver_iterations: i64,
        max_linear_velocity: f32,
        layer_id: u16,
        layer_mask: u16,
        allow_sleep: bool,
        faces_double_sided: bool,
        self_collision: bool,
        is_enabled: bool,
    ) -> Self {
        SoftBody {
            vertex_mass: vertex_mass.max(0.000_1),
            pressure: pressure.max(0.0),
            linear_damping: linear_damping.max(0.0),
            friction: friction.max(0.0),
            restitution: restitution.clamp(0.0, 1.0),
            gravity_scale,
            vertex_radius: vertex_radius.max(0.0),
            solver_iterations: solver_iterations.clamp(1, 128),
            max_linear_velocity: max_linear_velocity.max(0.0),
            layer_id,
            layer_mask,
            allow_sleep,
            faces_double_sided,
            self_collision,
            is_enabled,
        }
    }
}

impl Default for SoftBody {
    fn default() -> Self {
        SoftBody::new(
            1.0,
            0.0,
            0.1,
            0.2,
            0.0,
            1.0,
            0.02,
            5,
            500.0,
            0,
            u16::MAX,
            true,
            true,
            false,
            true,
        )
    }
}

impl RuntimeComponent for SoftBody {}

/// Deformed vertices are streamed independently from ordinary ECS transforms.
#[derive(Clone, Debug, PartialEq)]
pub struct SoftBodyMeshState {
    pub entity: EntityID,
    pub positions: Vec<Float3>,
    pub triangle_indices: Vec<u32>,
    pub is_sleeping: bool,
}

impl SoftBodyMeshState {
    pub fn new(entity: EntityID) -> Self {
        SoftBodyMeshState {
            entity,
            positions: Vec::new(),
            triangle_indices: Vec::new(),
            is_sleeping: false,
        }
    }

    pub fn with_state(
        entity: EntityID,
        positions: Vec<Float3>,
        triangle_indices: Vec<u32>,
        is_sleeping: bool,
    ) -> Self {
        SoftBodyMeshState {
            entity,
            positions,
            triangle_indices,
            is_sleeping,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SoftBodyStateFrameResource {
    pub states: std::collections::BTreeMap<EntityID, SoftBodyMeshState>,
    pub vertex_count: i64,
}

impl SoftBodyStateFrameResource {
    /// `vertexCount` is derived from the states, never supplied by the caller.
    pub fn new(states: std::collections::BTreeMap<EntityID, SoftBodyMeshState>) -> Self {
        let vertex_count = states
            .values()
            .map(|state| state.positions.len() as i64)
            .sum();
        SoftBodyStateFrameResource {
            states,
            vertex_count,
        }
    }

    pub fn empty() -> Self {
        SoftBodyStateFrameResource::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mesh_resource_id_trims_and_empties_to_none() {
        let mesh = SoftBodyMesh::new(
            Some("   ".to_string()),
            Vec::new(),
            0.0,
            0.0,
            0.0,
            0.0,
            ClothBendType::None,
        );
        assert_eq!(mesh.resource_id, None);

        let trimmed = SoftBodyMesh::new(
            Some("  bodyA ".to_string()),
            Vec::new(),
            0.0,
            0.0,
            0.0,
            0.0,
            ClothBendType::None,
        );
        assert_eq!(trimmed.resource_id.as_deref(), Some("bodyA"));
    }

    #[test]
    fn mesh_indices_filter_negatives_dedupe_and_sort() {
        let mesh = SoftBodyMesh::new(
            None,
            vec![4, 2, 4, -1, 2],
            0.0,
            0.0,
            0.0,
            0.0,
            ClothBendType::None,
        );
        assert_eq!(mesh.fixed_vertex_indices, vec![2, 4]);
    }

    #[test]
    fn mesh_default_bend_type_is_dihedral() {
        assert_eq!(SoftBodyMesh::default().bend_type, ClothBendType::Dihedral);
    }

    #[test]
    fn soft_body_clamps_solver_iterations() {
        let low = SoftBody::new(
            0.0, -1.0, -1.0, -1.0, 5.0, 1.0, -1.0, 0, -1.0, 0, 0, true, true, false, true,
        );
        assert_eq!(low.solver_iterations, 1);
        assert_eq!(low.vertex_mass, 0.000_1);
        assert_eq!(low.restitution, 1.0);

        let high = SoftBody::new(
            1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 9_999, 1.0, 0, 0, true, true, false, true,
        );
        assert_eq!(high.solver_iterations, 128);
    }

    #[test]
    fn state_frame_derives_vertex_count() {
        let mut states = std::collections::BTreeMap::new();
        states.insert(
            EntityID::new(0, 0),
            SoftBodyMeshState::with_state(
                EntityID::new(0, 0),
                vec![Float3::ZERO, Float3::ZERO, Float3::ZERO],
                vec![0, 1, 2],
                false,
            ),
        );
        states.insert(
            EntityID::new(1, 0),
            SoftBodyMeshState::with_state(
                EntityID::new(1, 0),
                vec![Float3::ZERO],
                Vec::new(),
                true,
            ),
        );
        let frame = SoftBodyStateFrameResource::new(states);
        assert_eq!(frame.vertex_count, 4);
    }
}
