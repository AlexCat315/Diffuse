//! Physics query request/response vocabulary.

use std::collections::BTreeSet;

use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::entity_id::EntityID;
use crate::physics::collider::SpatialAABB;

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsQueryFilter {
    /// Legacy single-entity exclusion. New code can use `ignored_entities` for
    /// self hierarchies and other multi-body exclusions.
    pub exclude_entity: Option<EntityID>,
    pub ignored_entities: BTreeSet<EntityID>,
    pub include_triggers: bool,
    pub layer_id: Option<u16>,
    pub layer_mask: u16,
}

impl PhysicsQueryFilter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_options(
        exclude_entity: Option<EntityID>,
        ignored_entities: BTreeSet<EntityID>,
        include_triggers: bool,
        layer_id: Option<u16>,
        layer_mask: u16,
    ) -> Self {
        PhysicsQueryFilter {
            exclude_entity,
            ignored_entities,
            include_triggers,
            layer_id,
            layer_mask,
        }
    }

    /// The union of the legacy exclusion and the ignored set.
    pub fn excluded_entities(&self) -> BTreeSet<EntityID> {
        let mut excluded = self.ignored_entities.clone();
        if let Some(entity) = self.exclude_entity {
            excluded.insert(entity);
        }
        excluded
    }
}

impl Default for PhysicsQueryFilter {
    fn default() -> Self {
        PhysicsQueryFilter {
            exclude_entity: None,
            ignored_entities: BTreeSet::new(),
            include_triggers: false,
            layer_id: None,
            layer_mask: u16::MAX,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsRaycastQuery {
    pub origin: Float3,
    pub direction: Float3,
    pub max_distance: f32,
}

impl PhysicsRaycastQuery {
    pub fn new(origin: Float3, direction: Float3) -> Self {
        PhysicsRaycastQuery {
            origin,
            direction,
            max_distance: f32::MAX,
        }
    }

    pub fn with_distance(origin: Float3, direction: Float3, max_distance: f32) -> Self {
        PhysicsRaycastQuery {
            origin,
            direction,
            max_distance,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsRaycastHit {
    pub entity: EntityID,
    pub sub_shape_id: u32,
    pub distance: f32,
    pub position: Float3,
    pub normal: Float3,
    pub bounds: SpatialAABB,
    pub is_trigger: bool,
}

impl PhysicsRaycastHit {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        entity: EntityID,
        sub_shape_id: u32,
        distance: f32,
        position: Float3,
        normal: Float3,
        bounds: SpatialAABB,
        is_trigger: bool,
    ) -> Self {
        PhysicsRaycastHit {
            entity,
            sub_shape_id,
            distance,
            position,
            normal,
            bounds,
            is_trigger,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsOverlapAABBQuery {
    pub bounds: SpatialAABB,
    /// Stop collecting hits after this many results. `usize::MAX` collects all.
    /// When set, sort order is not guaranteed.
    pub max_results: usize,
}

impl PhysicsOverlapAABBQuery {
    pub fn new(bounds: SpatialAABB) -> Self {
        PhysicsOverlapAABBQuery {
            bounds,
            max_results: usize::MAX,
        }
    }

    pub fn with_max_results(bounds: SpatialAABB, max_results: i64) -> Self {
        PhysicsOverlapAABBQuery {
            bounds,
            max_results: max_results.max(0) as usize,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsOverlapHit {
    pub entity: EntityID,
    pub sub_shape_id: u32,
    pub bounds: SpatialAABB,
    pub is_trigger: bool,
}

impl PhysicsOverlapHit {
    pub fn new(entity: EntityID, sub_shape_id: u32, bounds: SpatialAABB, is_trigger: bool) -> Self {
        PhysicsOverlapHit {
            entity,
            sub_shape_id,
            bounds,
            is_trigger,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PhysicsQueryShape {
    Box { half_extents: Float3 },
    Sphere { radius: f32 },
    Capsule { radius: f32, half_height: f32 },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsOverlapShapeQuery {
    pub shape: PhysicsQueryShape,
    pub position: Float3,
    /// Quaternion stored as `(x, y, z, w)`. Capsules are aligned to local Y before
    /// rotation.
    pub rotation: Float4,
    /// Stop collecting hits after this many results. `usize::MAX` collects all.
    pub max_results: usize,
}

impl PhysicsOverlapShapeQuery {
    pub fn new(shape: PhysicsQueryShape, position: Float3) -> Self {
        PhysicsOverlapShapeQuery {
            shape,
            position,
            rotation: Float4::new(0.0, 0.0, 0.0, 1.0),
            max_results: usize::MAX,
        }
    }

    pub fn with_rotation(shape: PhysicsQueryShape, position: Float3, rotation: Float4) -> Self {
        PhysicsOverlapShapeQuery {
            shape,
            position,
            rotation,
            max_results: usize::MAX,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsSweepAABBQuery {
    pub bounds: SpatialAABB,
    pub translation: Float3,
}

impl PhysicsSweepAABBQuery {
    pub fn new(bounds: SpatialAABB, translation: Float3) -> Self {
        PhysicsSweepAABBQuery {
            bounds,
            translation,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsSweepShapeQuery {
    pub shape: PhysicsQueryShape,
    pub position: Float3,
    /// Quaternion stored as `(x, y, z, w)`. Capsules are aligned to local Y before
    /// rotation.
    pub rotation: Float4,
    pub translation: Float3,
}

impl PhysicsSweepShapeQuery {
    pub fn new(shape: PhysicsQueryShape, position: Float3, translation: Float3) -> Self {
        PhysicsSweepShapeQuery {
            shape,
            position,
            rotation: Float4::new(0.0, 0.0, 0.0, 1.0),
            translation,
        }
    }

    pub fn with_rotation(
        shape: PhysicsQueryShape,
        position: Float3,
        rotation: Float4,
        translation: Float3,
    ) -> Self {
        PhysicsSweepShapeQuery {
            shape,
            position,
            rotation,
            translation,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsSweepHit {
    pub entity: EntityID,
    pub sub_shape_id: u32,
    pub fraction: f32,
    pub distance: f32,
    pub position: Float3,
    pub normal: Float3,
    pub bounds: SpatialAABB,
    pub is_trigger: bool,
}

impl PhysicsSweepHit {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        entity: EntityID,
        sub_shape_id: u32,
        fraction: f32,
        distance: f32,
        position: Float3,
        normal: Float3,
        bounds: SpatialAABB,
        is_trigger: bool,
    ) -> Self {
        PhysicsSweepHit {
            entity,
            sub_shape_id,
            fraction,
            distance,
            position,
            normal,
            bounds,
            is_trigger,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhysicsQueryResultMode {
    Nearest,
    All,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsQueryOptions {
    pub filter: PhysicsQueryFilter,
    pub result_mode: PhysicsQueryResultMode,
    pub max_hits: usize,
}

impl PhysicsQueryOptions {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_options(
        filter: PhysicsQueryFilter,
        result_mode: PhysicsQueryResultMode,
        max_hits: i64,
    ) -> Self {
        PhysicsQueryOptions {
            filter,
            result_mode,
            max_hits: max_hits.max(0) as usize,
        }
    }
}

impl Default for PhysicsQueryOptions {
    fn default() -> Self {
        PhysicsQueryOptions {
            filter: PhysicsQueryFilter::default(),
            result_mode: PhysicsQueryResultMode::Nearest,
            max_hits: usize::MAX,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsHit {
    pub entity: EntityID,
    pub sub_shape_id: u32,
    pub distance: f32,
    pub fraction: f32,
    pub position: Float3,
    pub normal: Float3,
    pub bounds: SpatialAABB,
    pub is_trigger: bool,
}

impl PhysicsHit {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        entity: EntityID,
        sub_shape_id: u32,
        distance: f32,
        fraction: f32,
        position: Float3,
        normal: Float3,
        bounds: SpatialAABB,
        is_trigger: bool,
    ) -> Self {
        PhysicsHit {
            entity,
            sub_shape_id,
            distance,
            fraction,
            position,
            normal,
            bounds,
            is_trigger,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bounds() -> SpatialAABB {
        SpatialAABB::new(Float3::ZERO, Float3::splat(1.0))
    }

    #[test]
    fn filter_excluded_entities_unions_legacy_and_ignored() {
        let ignored = EntityID::new(3, 0);
        let legacy = EntityID::new(7, 0);
        let filter = PhysicsQueryFilter::with_options(
            Some(legacy),
            [ignored].into_iter().collect(),
            false,
            None,
            u16::MAX,
        );
        let excluded = filter.excluded_entities();
        assert!(excluded.contains(&ignored));
        assert!(excluded.contains(&legacy));
        assert_eq!(excluded.len(), 2);
    }

    #[test]
    fn filter_without_legacy_exclusion_returns_ignored_only() {
        let ignored = EntityID::new(1, 0);
        let filter = PhysicsQueryFilter::with_options(
            None,
            [ignored].into_iter().collect(),
            true,
            Some(2),
            u16::MAX,
        );
        let excluded = filter.excluded_entities();
        assert_eq!(excluded.len(), 1);
        assert!(filter.include_triggers);
        assert_eq!(filter.layer_id, Some(2));
    }

    #[test]
    fn default_layer_mask_is_max() {
        assert_eq!(PhysicsQueryFilter::default().layer_mask, u16::MAX);
        assert_eq!(PhysicsQueryOptions::default().max_hits, usize::MAX);
    }

    #[test]
    fn max_results_clamps_negative_to_zero() {
        let query = PhysicsOverlapAABBQuery::with_max_results(bounds(), -5);
        assert_eq!(query.max_results, 0);
        assert_eq!(
            PhysicsOverlapAABBQuery::new(bounds()).max_results,
            usize::MAX
        );
    }

    #[test]
    fn rotate_default_is_identity_quaternion() {
        let query =
            PhysicsOverlapShapeQuery::new(PhysicsQueryShape::Sphere { radius: 1.0 }, Float3::ZERO);
        assert_eq!(query.rotation, Float4::new(0.0, 0.0, 0.0, 1.0));
    }

    #[test]
    fn raycast_default_distance_is_greatest_finite_magnitude() {
        let query = PhysicsRaycastQuery::new(Float3::ZERO, Float3::new(0.0, 0.0, 1.0));
        assert_eq!(query.max_distance, f32::MAX);
    }
}
