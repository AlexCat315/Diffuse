//! Camera frustum visibility and distance LOD selection.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Mesh/MeshVisibilityPlan.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_math::bounds::bounds_3d::Bounds3D;
use diffuse_math::geometry::frustum_3d::Frustum3D;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, simd_distance};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::rendering::render_scene::RenderDeformableMesh;
use diffuse_scene::rendering::render_scene::RenderScene;

use crate::core::render_settings::RenderSettings;

/// A mesh-bounds lookup shared with the shadow planner: `None` means the mesh
/// has no known bounds.
pub type MeshBoundsLookup<'a> = dyn Fn(i64) -> Option<(Float3, Float3)> + 'a;

/// A mesh-existence lookup for LOD slots.
pub type MeshExistsLookup<'a> = dyn Fn(i64) -> bool + 'a;

/// Camera visibility is separate from shadow visibility: offscreen objects can
/// still cast shadows into the camera view. Unknown/skinned bounds stay visible.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeshVisibilityPlan {
    pub visible_indices: Vec<usize>,
    pub mesh_indices: BTreeMap<usize, i64>,
    pub culled_count: usize,
    pub lod_count: usize,
}

impl MeshVisibilityPlan {
    #[allow(clippy::too_many_arguments)]
    pub fn make(
        scene: &RenderScene,
        view_projection: Float4x4,
        settings: &RenderSettings,
        skinned_entities: &BTreeSet<EntityID>,
        mesh_bounds: &MeshBoundsLookup<'_>,
        mesh_exists: &MeshExistsLookup<'_>,
    ) -> Self {
        let frustum = Frustum3D::from_view_projection(view_projection);
        // Swift's `Dictionary(..., uniquingKeysWith: { first, _ in first })`
        // keeps the first valid deformable per entity.
        let mut deformables: BTreeMap<EntityID, &RenderDeformableMesh> = BTreeMap::new();
        for mesh in &scene.deformable_meshes {
            if mesh.is_valid() && !deformables.contains_key(&mesh.entity) {
                deformables.insert(mesh.entity, mesh);
            }
        }
        let mut result = MeshVisibilityPlan::default();
        for (index, instance) in scene.instances.iter().enumerate() {
            let dynamic = instance
                .entity
                .and_then(|entity| deformables.get(&entity).copied());
            let skinned = instance
                .entity
                .is_some_and(|entity| skinned_entities.contains(&entity));
            let mut bounds: Option<Bounds3D> = None;
            if let Some(dynamic) = dynamic {
                bounds = Some(Bounds3D::from_points(dynamic.positions.iter().copied()));
            } else if !skinned {
                let mut slots = vec![instance.mesh_index()];
                slots.extend(
                    instance
                        .mesh
                        .levels_of_detail
                        .iter()
                        .filter(|lod| mesh_exists(lod.mesh_index))
                        .map(|lod| lod.mesh_index),
                );
                let mut combined = Bounds3D::EMPTY;
                let mut known = true;
                for slot in &slots {
                    let Some(local) = mesh_bounds(*slot) else {
                        known = false;
                        break;
                    };
                    let center = (local.0 + local.1) * 0.5;
                    let half = (local.1 - local.0) * 0.5;
                    let transformed =
                        instance.transform * Float4::new(center.x, center.y, center.z, 1.0);
                    let a = instance.transform.columns[0];
                    let b = instance.transform.columns[1];
                    let c = instance.transform.columns[2];
                    let extent = Float3::new(
                        a.x.abs() * half.x + b.x.abs() * half.y + c.x.abs() * half.z,
                        a.y.abs() * half.x + b.y.abs() * half.y + c.y.abs() * half.z,
                        a.z.abs() * half.x + b.z.abs() * half.y + c.z.abs() * half.z,
                    );
                    let world_center = Float3::new(transformed.x, transformed.y, transformed.z);
                    combined =
                        combined.union(Bounds3D::new(world_center - extent, world_center + extent));
                }
                if known {
                    bounds = Some(combined);
                }
            }
            if settings.visibility.frustum_culling
                && let Some(bounds) = bounds
                && !frustum.intersects(bounds)
            {
                result.culled_count += 1;
                continue;
            }
            let mut mesh_index = instance.mesh_index();
            if settings.visibility.distance_lod && dynamic.is_none() && !skinned {
                let t = instance.transform.columns[3];
                let distance = simd_distance(scene.camera.eye, Float3::new(t.x, t.y, t.z));
                let mut lods: Vec<_> = instance.mesh.levels_of_detail.iter().collect();
                lods.sort_by(|lhs, rhs| {
                    lhs.minimum_distance
                        .partial_cmp(&rhs.minimum_distance)
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
                for lod in lods {
                    if lod.minimum_distance.is_finite()
                        && distance >= lod.minimum_distance
                        && mesh_exists(lod.mesh_index)
                    {
                        mesh_index = lod.mesh_index;
                    }
                }
            }
            if mesh_index != instance.mesh_index() {
                result.lod_count += 1;
            }
            result.visible_indices.push(index);
            result.mesh_indices.insert(index, mesh_index);
        }
        result
    }
}
