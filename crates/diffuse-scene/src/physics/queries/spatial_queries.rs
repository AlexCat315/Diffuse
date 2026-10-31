//! Spatial query vocabulary and the world's spatial index.
//!
//! `SpatialAABB` lives in [`crate::physics::collider`] and is re-used here rather
//! than redefined: the index, the mesh resources and every scene-level query
//! share that one bounds type.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float2, Float3, simd_max, simd_min};

use crate::physics::collider::SpatialAABB;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeshColliderBoundsResource {
    pub bounds_by_resource_id: BTreeMap<String, SpatialAABB>,
    pub default_bounds: Option<SpatialAABB>,
}

impl MeshColliderBoundsResource {
    pub fn new(
        bounds_by_resource_id: BTreeMap<String, SpatialAABB>,
        default_bounds: Option<SpatialAABB>,
    ) -> Self {
        MeshColliderBoundsResource {
            bounds_by_resource_id,
            default_bounds,
        }
    }

    /// A named lookup wins; otherwise the default applies.
    pub fn bounds_for(&self, resource_id: Option<&str>) -> Option<&SpatialAABB> {
        if let Some(bounds) = resource_id.and_then(|id| self.bounds_by_resource_id.get(id)) {
            return Some(bounds);
        }
        self.default_bounds.as_ref()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct MeshColliderGeometry {
    pub revision: u64,
    pub positions: Vec<Float3>,
    pub triangle_indices: Vec<u32>,
    /// Four indices per tetrahedron. Empty for a surface-only mesh.
    pub tetrahedron_indices: Vec<u32>,
    pub texture_coordinates: Vec<Float2>,
    pub local_bounds: SpatialAABB,
}

impl MeshColliderGeometry {
    /// `texture_coordinates` is kept only when it matches `positions` element-wise;
    /// otherwise it is dropped, and `local_bounds` defaults to the computed bounds.
    pub fn new(
        positions: Vec<Float3>,
        triangle_indices: Vec<u32>,
        tetrahedron_indices: Vec<u32>,
        texture_coordinates: Vec<Float2>,
        local_bounds: Option<SpatialAABB>,
        revision: u64,
    ) -> Self {
        let texture_coordinates = if texture_coordinates.len() == positions.len() {
            texture_coordinates
        } else {
            Vec::new()
        };
        let local_bounds = local_bounds.unwrap_or_else(|| Self::compute_bounds(&positions));
        MeshColliderGeometry {
            revision,
            positions,
            triangle_indices,
            tetrahedron_indices,
            texture_coordinates,
            local_bounds,
        }
    }

    pub fn triangle_count(&self) -> usize {
        self.triangle_indices.len() / 3
    }

    pub fn tetrahedron_count(&self) -> usize {
        self.tetrahedron_indices.len() / 4
    }

    /// An empty position list yields a zero-sized box at the origin.
    fn compute_bounds(positions: &[Float3]) -> SpatialAABB {
        let Some((first, rest)) = positions.split_first() else {
            return SpatialAABB::new(Float3::ZERO, Float3::ZERO);
        };
        let mut minimum = *first;
        let mut maximum = *first;
        for position in rest {
            minimum = simd_min(minimum, *position);
            maximum = simd_max(maximum, *position);
        }
        SpatialAABB::new(minimum, maximum)
    }
}

impl Default for MeshColliderGeometry {
    fn default() -> Self {
        MeshColliderGeometry::new(Vec::new(), Vec::new(), Vec::new(), Vec::new(), None, 0)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct MeshColliderGeometryResource {
    pub geometry_by_resource_id: BTreeMap<String, MeshColliderGeometry>,
    pub default_geometry: Option<MeshColliderGeometry>,
}

impl MeshColliderGeometryResource {
    pub fn new(
        geometry_by_resource_id: BTreeMap<String, MeshColliderGeometry>,
        default_geometry: Option<MeshColliderGeometry>,
    ) -> Self {
        MeshColliderGeometryResource {
            geometry_by_resource_id,
            default_geometry,
        }
    }

    /// A named lookup wins; otherwise the default applies.
    pub fn geometry_for(&self, resource_id: Option<&str>) -> Option<&MeshColliderGeometry> {
        if let Some(geometry) = resource_id.and_then(|id| self.geometry_by_resource_id.get(id)) {
            return Some(geometry);
        }
        self.default_geometry.as_ref()
    }
}

/// Traversal counters a spatial query reports back to its caller.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SpatialQueryStats {
    pub node_visits: i64,
    pub leaf_tests: i64,
    pub narrow_phase_tests: i64,
}

impl SpatialQueryStats {
    pub fn new(node_visits: i64, leaf_tests: i64, narrow_phase_tests: i64) -> Self {
        SpatialQueryStats {
            node_visits,
            leaf_tests,
            narrow_phase_tests,
        }
    }
}

/// A reusable traversal buffer handle.
///
/// Swift declared an empty `final class` so callers could thread one scratch
/// object through many queries; Rust only needs the handle to exist, and the
/// query wrappers take it by reference so the call site keeps ownership.
#[derive(Clone, Debug, Default)]
pub struct SpatialQueryScratch;

impl SpatialQueryScratch {
    pub fn new() -> Self {
        SpatialQueryScratch
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_lookup_prefers_named_then_default() {
        let named = SpatialAABB::new(Float3::ZERO, Float3::splat(1.0));
        let default = SpatialAABB::new(Float3::ZERO, Float3::splat(2.0));
        let mut by_id = BTreeMap::new();
        by_id.insert("a".to_string(), named);
        let resource = MeshColliderBoundsResource::new(by_id, Some(default));
        assert_eq!(resource.bounds_for(Some("a")), Some(&named));
        assert_eq!(resource.bounds_for(Some("missing")), Some(&default));
        assert_eq!(resource.bounds_for(None), Some(&default));
    }

    #[test]
    fn geometry_lookup_prefers_named_then_default() {
        let named = MeshColliderGeometry::default();
        let mut by_id = BTreeMap::new();
        by_id.insert("mesh".to_string(), named.clone());
        let resource = MeshColliderGeometryResource::new(by_id, None);
        assert_eq!(resource.geometry_for(Some("mesh")), Some(&named));
        assert_eq!(resource.geometry_for(Some("other")), None);
    }

    #[test]
    fn empty_geometry_has_zero_bounds() {
        let geometry = MeshColliderGeometry::default();
        assert_eq!(
            geometry.local_bounds,
            SpatialAABB::new(Float3::ZERO, Float3::ZERO)
        );
        assert_eq!(geometry.triangle_count(), 0);
        assert_eq!(geometry.tetrahedron_count(), 0);
    }

    #[test]
    fn bounds_are_computed_from_positions() {
        let geometry = MeshColliderGeometry::new(
            vec![
                Float3::new(-1.0, 0.0, 2.0),
                Float3::new(1.0, -3.0, 2.0),
                Float3::new(0.0, 5.0, -2.0),
            ],
            vec![0, 1, 2],
            Vec::new(),
            Vec::new(),
            None,
            9,
        );
        assert_eq!(geometry.revision, 9);
        assert_eq!(
            geometry.local_bounds,
            SpatialAABB::new(Float3::new(-1.0, -3.0, -2.0), Float3::new(1.0, 5.0, 2.0))
        );
        assert_eq!(geometry.triangle_count(), 1);
    }

    #[test]
    fn mismatched_texture_coordinates_are_dropped() {
        let positions = vec![Float3::ZERO, Float3::ZERO];
        let dropped = MeshColliderGeometry::new(
            positions.clone(),
            Vec::new(),
            Vec::new(),
            vec![Float2::new(0.0, 0.0)],
            None,
            0,
        );
        assert!(dropped.texture_coordinates.is_empty());

        let kept = MeshColliderGeometry::new(
            positions,
            Vec::new(),
            Vec::new(),
            vec![Float2::new(0.0, 0.0), Float2::new(1.0, 1.0)],
            None,
            0,
        );
        assert_eq!(kept.texture_coordinates.len(), 2);
    }

    #[test]
    fn tetrahedron_count_divides_by_four() {
        let geometry = MeshColliderGeometry::new(
            Vec::new(),
            Vec::new(),
            vec![0, 1, 2, 3, 4, 5, 6, 7],
            Vec::new(),
            None,
            0,
        );
        assert_eq!(geometry.tetrahedron_count(), 2);
    }
}

/// Replace a mesh-backed collider shape with its bounding box when the mesh
/// geometry is unavailable but its bounds are known.
///
/// Swift used this when building a physics snapshot: a mesh/heightfield/convex
/// collider whose geometry has not been loaded falls back to the cached local
/// bounds as a box, so the body still participates in collision. When the geometry
/// *is* available the shape is returned unchanged (the backend uses the mesh).
pub fn resolved_collider_shape(
    shape: &crate::physics::collider::ColliderShape,
    mesh_geometry: Option<&MeshColliderGeometry>,
    mesh_bounds: Option<&MeshColliderBoundsResource>,
) -> crate::physics::collider::ColliderShape {
    use crate::physics::collider::ColliderShape;

    if mesh_geometry.is_some() {
        return shape.clone();
    }
    let (resource_id, center) = match shape {
        ColliderShape::HeightField {
            resource_id,
            center,
        }
        | ColliderShape::Mesh {
            resource_id,
            center,
        }
        | ColliderShape::Convex {
            resource_id,
            center,
        } => (resource_id.clone(), *center),
        _ => return shape.clone(),
    };
    let Some(bounds) = mesh_bounds.and_then(|bounds| bounds.bounds_for(resource_id.as_deref()))
    else {
        return shape.clone();
    };
    let half_extents = bounds.half_extents();
    ColliderShape::Box {
        half_extents,
        center: center + bounds.center(),
    }
}

#[cfg(test)]
mod resolved_collider_shape_tests {
    use super::*;
    use crate::physics::collider::ColliderShape;
    use diffuse_math::simd::simd_compat::Float3;

    fn bounds(min: Float3, max: Float3) -> MeshColliderBoundsResource {
        MeshColliderBoundsResource {
            bounds_by_resource_id: std::collections::BTreeMap::new(),
            default_bounds: Some(SpatialAABB::new(min, max)),
        }
    }

    #[test]
    fn a_mesh_shape_falls_back_to_its_cached_bounds() {
        let shape = ColliderShape::Mesh {
            resource_id: Some("hero".to_string()),
            center: Float3::ZERO,
        };
        let resolved = resolved_collider_shape(
            &shape,
            None,
            Some(&bounds(
                Float3::new(-1.0, -2.0, -3.0),
                Float3::new(1.0, 2.0, 3.0),
            )),
        );
        match resolved {
            ColliderShape::Box {
                half_extents,
                center,
            } => {
                assert_eq!(half_extents, Float3::new(1.0, 2.0, 3.0));
                assert_eq!(center, Float3::ZERO);
            }
            other => panic!("expected a box fallback, got {other:?}"),
        }
    }

    #[test]
    fn a_loaded_geometry_leaves_the_shape_untouched() {
        let shape = ColliderShape::Mesh {
            resource_id: Some("hero".to_string()),
            center: Float3::ZERO,
        };
        let geometry = MeshColliderGeometry {
            revision: 1,
            positions: Vec::new(),
            triangle_indices: Vec::new(),
            tetrahedron_indices: Vec::new(),
            texture_coordinates: Vec::new(),
            local_bounds: SpatialAABB::new(Float3::ZERO, Float3::ZERO),
        };
        let resolved = resolved_collider_shape(&shape, Some(&geometry), None);
        assert_eq!(
            resolved, shape,
            "a mesh with geometry must keep its mesh shape"
        );
    }

    #[test]
    fn a_primitive_shape_is_never_rewritten() {
        let shape = ColliderShape::Sphere {
            radius: 2.0,
            center: Float3::ZERO,
        };
        let resolved = resolved_collider_shape(&shape, None, None);
        assert_eq!(resolved, shape);
    }

    #[test]
    fn a_mesh_without_bounds_stays_a_mesh() {
        let shape = ColliderShape::Mesh {
            resource_id: None,
            center: Float3::ZERO,
        };
        let resolved = resolved_collider_shape(&shape, None, None);
        assert_eq!(resolved, shape);
    }
}

/// One collider as it appears in the spatial index.
///
/// `shape` and `mesh_geometry` both come from the collider: the geometry is `Some`
/// only when the mesh resource is loaded, and the index records it so a query can
/// use exact geometry without re-resolving the resource.
#[derive(Clone, Debug, PartialEq)]
pub struct SpatialIndexEntry {
    pub entity: crate::entity_id::EntityID,
    pub shape: crate::physics::collider::ColliderShape,
    pub mesh_geometry: Option<MeshColliderGeometry>,
    pub world_transform: crate::runtime_world::WorldTransform,
    pub bounds: SpatialAABB,
    pub is_trigger: bool,
    pub layer_id: u16,
    pub layer_mask: u16,
}

/// The world's spatial index, rebuilt when the physics revision changes.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SpatialIndexResource {
    pub entries: Vec<SpatialIndexEntry>,
    pub source_revision: u64,
}

impl SpatialIndexResource {
    pub fn new(entries: Vec<SpatialIndexEntry>, source_revision: u64) -> Self {
        SpatialIndexResource {
            entries,
            source_revision,
        }
    }

    /// Entries whose layer mask admits `layer`, excluding triggers unless asked.
    pub fn candidates(&self, layer: u16, include_triggers: bool) -> Vec<&SpatialIndexEntry> {
        self.entries
            .iter()
            .filter(|entry| entry.layer_mask & layer != 0)
            .filter(|entry| include_triggers || !entry.is_trigger)
            .collect()
    }
}

/// A scene-level ray. `max_distance` defaults to the greatest finite magnitude,
/// as Swift's `.greatestFiniteMagnitude` did.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneRaycastQuery {
    pub origin: Float3,
    pub direction: Float3,
    pub max_distance: f32,
    pub include_triggers: bool,
}

impl SceneRaycastQuery {
    pub fn new(origin: Float3, direction: Float3) -> Self {
        SceneRaycastQuery {
            origin,
            direction,
            max_distance: f32::MAX,
            include_triggers: false,
        }
    }

    pub fn with_options(
        origin: Float3,
        direction: Float3,
        max_distance: f32,
        include_triggers: bool,
    ) -> Self {
        SceneRaycastQuery {
            origin,
            direction,
            max_distance,
            include_triggers,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneRaycastHit {
    pub entity: crate::entity_id::EntityID,
    pub distance: f32,
    pub position: Float3,
    pub normal: Float3,
    pub bounds: SpatialAABB,
    pub is_trigger: bool,
}

impl SceneRaycastHit {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        entity: crate::entity_id::EntityID,
        distance: f32,
        position: Float3,
        normal: Float3,
        bounds: SpatialAABB,
        is_trigger: bool,
    ) -> Self {
        SceneRaycastHit {
            entity,
            distance,
            position,
            normal,
            bounds,
            is_trigger,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneOverlapQuery {
    pub bounds: SpatialAABB,
    pub include_triggers: bool,
}

impl SceneOverlapQuery {
    pub fn new(bounds: SpatialAABB) -> Self {
        SceneOverlapQuery {
            bounds,
            include_triggers: false,
        }
    }

    pub fn with_include_triggers(bounds: SpatialAABB, include_triggers: bool) -> Self {
        SceneOverlapQuery {
            bounds,
            include_triggers,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneOverlapHit {
    pub entity: crate::entity_id::EntityID,
    pub bounds: SpatialAABB,
    pub is_trigger: bool,
}

impl SceneOverlapHit {
    pub fn new(entity: crate::entity_id::EntityID, bounds: SpatialAABB, is_trigger: bool) -> Self {
        SceneOverlapHit {
            entity,
            bounds,
            is_trigger,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneSweepQuery {
    pub bounds: SpatialAABB,
    pub translation: Float3,
    pub include_triggers: bool,
}

impl SceneSweepQuery {
    pub fn new(bounds: SpatialAABB, translation: Float3) -> Self {
        SceneSweepQuery {
            bounds,
            translation,
            include_triggers: false,
        }
    }

    pub fn with_include_triggers(
        bounds: SpatialAABB,
        translation: Float3,
        include_triggers: bool,
    ) -> Self {
        SceneSweepQuery {
            bounds,
            translation,
            include_triggers,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneSweepHit {
    pub entity: crate::entity_id::EntityID,
    pub fraction: f32,
    pub distance: f32,
    pub position: Float3,
    pub normal: Float3,
    pub bounds: SpatialAABB,
    pub is_trigger: bool,
}

impl SceneSweepHit {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        entity: crate::entity_id::EntityID,
        fraction: f32,
        distance: f32,
        position: Float3,
        normal: Float3,
        bounds: SpatialAABB,
        is_trigger: bool,
    ) -> Self {
        SceneSweepHit {
            entity,
            fraction,
            distance,
            position,
            normal,
            bounds,
            is_trigger,
        }
    }
}

#[cfg(test)]
mod spatial_index_tests {
    use super::*;

    #[test]
    fn an_empty_index_has_no_candidates() {
        let index = SpatialIndexResource::default();
        assert!(index.candidates(1, false).is_empty());
    }
}

/// Build the world's spatial index.
///
/// A collider with no world transform is skipped: it has no position to index.
/// The bounds are the shape's **world-space** AABB, computed by transforming the
/// shape's local corners (or, for sphere/capsule, by scaling the radius by the
/// matrix's largest basis length) — never by transforming the local AABB corners for
/// spheres, which would over-estimate a rotated ellipsoid.
pub fn build_spatial_index_resource(
    world: &crate::runtime_world::RuntimeWorld,
    job_system: &diffuse_kernel::job_system::JobSystem,
) -> (
    SpatialIndexResource,
    diffuse_kernel::job_system::JobDispatchReport,
) {
    let entities = world.entities();
    let colliders = world.component_snapshot::<crate::physics::collider::Collider>();
    let world_transforms = world.world_transform_snapshot_matching(&entities);
    let mesh_bounds = world.resource::<MeshColliderBoundsResource>();
    let mesh_geometries = world.resource::<MeshColliderGeometryResource>();

    let (entries, report) = job_system.parallel_compact_map(&entities, None, |entity| {
        let collider = colliders.get(entity)?;
        let world_transform = world_transforms.get(entity).copied()?;

        let shape = collider.shape();
        let mesh_geometry = mesh_collider_geometry(&shape, mesh_geometries.as_ref());
        let resolved_shape = resolved_collider_shape(&shape, mesh_geometry, mesh_bounds.as_ref());
        let bounds = collider_bounds(&resolved_shape, &world_transform, mesh_geometry)?;

        Some(SpatialIndexEntry {
            entity: *entity,
            shape: resolved_shape,
            mesh_geometry: mesh_geometry.cloned(),
            world_transform,
            bounds,
            is_trigger: collider.is_trigger,
            layer_id: collider.layer_id,
            layer_mask: collider.layer_mask,
        })
    });

    (SpatialIndexResource::new(entries, world.revision()), report)
}

/// The mesh resource backing a mesh-like shape, if loaded.
fn mesh_collider_geometry<'a>(
    shape: &crate::physics::collider::ColliderShape,
    resource: Option<&'a MeshColliderGeometryResource>,
) -> Option<&'a MeshColliderGeometry> {
    resource.and_then(|resource| resource.geometry_for(shape.resource_id()))
}

/// World-space AABB of a collider shape.
fn collider_bounds(
    shape: &crate::physics::collider::ColliderShape,
    world_transform: &crate::runtime_world::WorldTransform,
    mesh_geometry: Option<&MeshColliderGeometry>,
) -> Option<SpatialAABB> {
    use crate::physics::collider::ColliderShape;
    use diffuse_math::simd::simd_compat::{Float3, simd_max, simd_min};

    let matrix = world_transform.matrix;
    match shape {
        ColliderShape::Box {
            half_extents,
            center,
        } => transformed_bounds(&box_corners(*center, *half_extents), &matrix),
        ColliderShape::Sphere { radius, center } => {
            let world_center = transform_point(*center, &matrix);
            let scaled_radius = radius * max_scale_component(&matrix);
            let radius_vector = Float3::splat(scaled_radius);
            Some(SpatialAABB::new(
                world_center - radius_vector,
                world_center + radius_vector,
            ))
        }
        ColliderShape::Capsule {
            radius,
            half_height,
            center,
        } => {
            // The capsule's axis is local +Y; only the two cap centres need
            // transforming, then the radius is added as a world-space box.
            let top = transform_point(*center + Float3::new(0.0, *half_height, 0.0), &matrix);
            let bottom = transform_point(*center + Float3::new(0.0, -*half_height, 0.0), &matrix);
            let scaled_radius = radius * max_scale_component(&matrix);
            let radius_vector = Float3::splat(scaled_radius);
            Some(SpatialAABB::new(
                simd_min(top, bottom) - radius_vector,
                simd_max(top, bottom) + radius_vector,
            ))
        }
        ColliderShape::Cylinder {
            radius,
            half_height,
            center,
        } => transformed_bounds(
            &box_corners(*center, Float3::new(*radius, *half_height, *radius)),
            &matrix,
        ),
        ColliderShape::HeightField { center, .. }
        | ColliderShape::Mesh { center, .. }
        | ColliderShape::Convex { center, .. } => {
            // A mesh without loaded geometry falls back to a half-unit box, matching
            // Swift: a collider whose resource is missing still occupies space.
            let local_bounds = mesh_geometry
                .map(|geometry| geometry.local_bounds)
                .unwrap_or_else(|| {
                    SpatialAABB::from_center_half_extents(Float3::ZERO, Float3::splat(0.5))
                });
            let mesh_center = *center + local_bounds.center();
            transformed_bounds(
                &box_corners(mesh_center, local_bounds.half_extents()),
                &matrix,
            )
        }
    }
}

fn box_corners(
    center: diffuse_math::simd::simd_compat::Float3,
    half_extents: diffuse_math::simd::simd_compat::Float3,
) -> [diffuse_math::simd::simd_compat::Float3; 8] {
    use diffuse_math::simd::simd_compat::Float3;
    let h = half_extents;
    [
        center + Float3::new(h.x, h.y, h.z),
        center + Float3::new(h.x, h.y, -h.z),
        center + Float3::new(h.x, -h.y, h.z),
        center + Float3::new(h.x, -h.y, -h.z),
        center + Float3::new(-h.x, h.y, h.z),
        center + Float3::new(-h.x, h.y, -h.z),
        center + Float3::new(-h.x, -h.y, h.z),
        center + Float3::new(-h.x, -h.y, -h.z),
    ]
}

fn transformed_bounds(
    corners: &[diffuse_math::simd::simd_compat::Float3],
    matrix: &diffuse_math::simd::simd_compat::Float4x4,
) -> Option<SpatialAABB> {
    use diffuse_math::simd::simd_compat::{simd_max, simd_min};
    let first = transform_point(*corners.first()?, matrix);
    let mut minimum = first;
    let mut maximum = first;
    for corner in &corners[1..] {
        let transformed = transform_point(*corner, matrix);
        minimum = simd_min(minimum, transformed);
        maximum = simd_max(maximum, transformed);
    }
    Some(SpatialAABB::new(minimum, maximum))
}

fn transform_point(
    point: diffuse_math::simd::simd_compat::Float3,
    matrix: &diffuse_math::simd::simd_compat::Float4x4,
) -> diffuse_math::simd::simd_compat::Float3 {
    use diffuse_math::simd::simd_compat::{Float3, Float4};
    let transformed = *matrix * Float4::new(point.x, point.y, point.z, 1.0);
    Float3::new(transformed.x, transformed.y, transformed.z)
}

fn max_scale_component(matrix: &diffuse_math::simd::simd_compat::Float4x4) -> f32 {
    use diffuse_math::simd::simd_compat::{Float3, simd_length};
    let column_length = |column: &diffuse_math::simd::simd_compat::Float4| {
        simd_length(Float3::new(column.x, column.y, column.z))
    };
    column_length(&matrix.columns[0])
        .max(column_length(&matrix.columns[1]))
        .max(column_length(&matrix.columns[2]))
}

#[cfg(test)]
mod spatial_index_build_tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;
    use crate::entity_id::EntityID;
    use crate::physics::collider::{Collider, ColliderShape};
    use crate::runtime_world::{LocalTransform, RuntimeWorld};
    use diffuse_math::simd::simd_compat::Float3;

    fn world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    #[test]
    fn an_entity_without_a_collider_is_not_indexed() {
        let mut world = world();
        world.create_entity();
        let (index, _) =
            build_spatial_index_resource(&world, &diffuse_kernel::job_system::JobSystem::new(1, 1));
        assert!(index.entries.is_empty());
    }

    #[test]
    fn a_box_collider_produces_its_world_bounds() {
        let mut world = world();
        let entity: EntityID = world.create_entity();
        world.set_component(
            Collider::with_shape(ColliderShape::Box {
                half_extents: Float3::splat(1.0),
                center: Float3::ZERO,
            }),
            entity,
        );
        world.set_local_transform(LocalTransform::IDENTITY, entity);
        world.propagate_transforms_default();

        let (index, _) =
            build_spatial_index_resource(&world, &diffuse_kernel::job_system::JobSystem::new(1, 1));
        assert_eq!(index.entries.len(), 1);
        let bounds = index.entries[0].bounds;
        assert!((bounds.min.x + 1.0).abs() < 1e-5);
        assert!((bounds.max.x - 1.0).abs() < 1e-5);
    }

    #[test]
    fn a_sphere_bounds_scale_with_the_matrix() {
        let mut world = world();
        let entity: EntityID = world.create_entity();
        world.set_component(
            Collider::with_shape(ColliderShape::Sphere {
                radius: 2.0,
                center: Float3::ZERO,
            }),
            entity,
        );
        let mut matrix = diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4;
        matrix.set_column(
            0,
            diffuse_math::simd::simd_compat::Float4::new(3.0, 0.0, 0.0, 0.0),
        );
        world.set_local_transform(LocalTransform::new(matrix), entity);
        // The spatial index reads `WorldTransform`, which only reflects a local edit
        // after propagation — exactly as the schedule guarantees it happens before
        // `spatialIndexUpdate`.
        world.propagate_transforms_default();

        let (index, _) =
            build_spatial_index_resource(&world, &diffuse_kernel::job_system::JobSystem::new(1, 1));
        // radius 2 * largest basis length 3 = 6.
        assert!((index.entries[0].bounds.max.x - 6.0).abs() < 1e-4);
    }

    #[test]
    fn the_index_records_the_world_revision() {
        let world = world();
        let (index, _) =
            build_spatial_index_resource(&world, &diffuse_kernel::job_system::JobSystem::new(1, 1));
        assert_eq!(index.source_revision, world.revision());
    }
}
