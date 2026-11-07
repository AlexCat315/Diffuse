//! Raycast, overlap, sweep and trigger queries for the Natsel backend.
//!
//! Ported from `Engine/Sources/SceneRuntime/Physics/Backend/Natsel/NatselQueries.swift`.
//!
//! All of these take `&self`: Natsel's query entry points (`cast_ray`, `overlap_shape`,
//! `cast_shape`) only read the broad phase and shape stores, so no `&mut` is needed and
//! nothing here touches the `unsafe` character alias.
//!
//! Result ordering is explicit and total, because the caller compares hit lists: ties
//! break on `entity.rawValue` then `subShapeID`, matching the Swift comparators.

use std::collections::BTreeSet;

use diffuse_math::simd::simd_compat::{Float3, Float4, simd_dot, simd_length};

use natsel::types::ids::ShapeID;
use natsel::types::queries::ShapeProxy;

use crate::entity_id::EntityID;
use crate::physics::queries::physics_query_types::PhysicsQueryFilter;
use crate::physics::queries::physics_query_types::{
    PhysicsOverlapHit, PhysicsOverlapShapeQuery, PhysicsQueryShape, PhysicsRaycastHit,
    PhysicsRaycastQuery, PhysicsSweepHit, PhysicsSweepShapeQuery,
};
use crate::physics::queries::trigger_detection::{
    TriggerEvent, TriggerEventKind, TriggerFrameResource,
};

use super::natsel_physics_backend::{NatselPhysicsBackend, Pair};
use super::natsel_shapes;

/// `raycastAll(_:filter:maxHits:)`.
pub(crate) fn raycast_all(
    backend: &NatselPhysicsBackend,
    query: &PhysicsRaycastQuery,
    filter: &PhysicsQueryFilter,
    max_hits: usize,
) -> Vec<PhysicsRaycastHit> {
    let length = simd_length(query.direction);
    // Each `!(x > 0)` is Swift's predicate: NaN and zero both bail out, and `<= 0`
    // would wrongly admit NaN.
    #[allow(clippy::neg_cmp_op_on_partial_ord)]
    let valid = length.is_finite() && length > 0.0 && query.max_distance > 0.0;
    if max_hits == 0 || !valid {
        return Vec::new();
    }
    let distance = query.max_distance.min(f32::MAX / 4.0);
    let translation = query.direction * (distance / length);
    let mut hits: Vec<PhysicsRaycastHit> = Vec::new();
    backend.world.cast_ray(
        NatselPhysicsBackend::np(query.origin),
        NatselPhysicsBackend::nv(translation),
        natsel::types::shape_def::QueryFilter::default_filter(),
        |id, point, normal, fraction, _material, _triangle, _child| {
            if !natsel_shapes::accepts(backend, id, filter) {
                return 1.0;
            }
            let Some(owner) = natsel_shapes::shape_owner(backend, id) else {
                return 1.0;
            };
            hits.push(PhysicsRaycastHit::new(
                owner.entity,
                owner.child,
                fraction * distance,
                NatselPhysicsBackend::sv_pos(point),
                NatselPhysicsBackend::sv(normal),
                natsel_shapes::bounds(backend, id),
                backend
                    .bodies
                    .get(&owner.entity)
                    .and_then(|record| record.descriptor.collider.as_ref())
                    .is_some_and(|collider| collider.is_trigger),
            ));
            1.0
        },
    );
    sort_raycast_hits(&mut hits);
    hits.truncate(max_hits);
    hits
}

fn sort_raycast_hits(hits: &mut [PhysicsRaycastHit]) {
    hits.sort_by(|lhs, rhs| {
        if lhs.distance != rhs.distance {
            lhs.distance
                .partial_cmp(&rhs.distance)
                .unwrap_or(std::cmp::Ordering::Equal)
        } else if lhs.entity != rhs.entity {
            lhs.entity.raw_value().cmp(&rhs.entity.raw_value())
        } else {
            lhs.sub_shape_id.cmp(&rhs.sub_shape_id)
        }
    });
}

fn sort_overlap_hits(hits: &mut [PhysicsOverlapHit]) {
    hits.sort_by(|lhs, rhs| {
        if lhs.entity != rhs.entity {
            lhs.entity.raw_value().cmp(&rhs.entity.raw_value())
        } else {
            lhs.sub_shape_id.cmp(&rhs.sub_shape_id)
        }
    });
}

fn sort_sweep_hits(hits: &mut [PhysicsSweepHit]) {
    hits.sort_by(|lhs, rhs| {
        if lhs.fraction != rhs.fraction {
            lhs.fraction
                .partial_cmp(&rhs.fraction)
                .unwrap_or(std::cmp::Ordering::Equal)
        } else if lhs.entity != rhs.entity {
            lhs.entity.raw_value().cmp(&rhs.entity.raw_value())
        } else {
            lhs.sub_shape_id.cmp(&rhs.sub_shape_id)
        }
    });
}

/// `overlapShape(_:filter:)`.
pub(crate) fn overlap_shape(
    backend: &NatselPhysicsBackend,
    query: &PhysicsOverlapShapeQuery,
    filter: &PhysicsQueryFilter,
) -> Vec<PhysicsOverlapHit> {
    if query.max_results == 0 {
        return Vec::new();
    }
    let (points, radius) = query_points(query.shape, query.rotation);
    let proxy = shape_proxy(&points, radius);
    // Natsel's overlap callback is `Fn`, so hits are gathered through a `RefCell`
    // rather than a captured `&mut`.
    let hits: std::cell::RefCell<Vec<PhysicsOverlapHit>> = std::cell::RefCell::new(Vec::new());
    backend.world.overlap_shape(
        NatselPhysicsBackend::np(query.position),
        proxy,
        natsel::types::shape_def::QueryFilter::default_filter(),
        |id| {
            if natsel_shapes::accepts(backend, id, filter)
                && let Some(owner) = natsel_shapes::shape_owner(backend, id)
            {
                hits.borrow_mut().push(PhysicsOverlapHit::new(
                    owner.entity,
                    owner.child,
                    natsel_shapes::bounds(backend, id),
                    backend
                        .bodies
                        .get(&owner.entity)
                        .and_then(|record| record.descriptor.collider.as_ref())
                        .is_some_and(|collider| collider.is_trigger),
                ));
            }
            true
        },
    );
    let mut hits = hits.into_inner();
    sort_overlap_hits(&mut hits);
    hits.truncate(query.max_results);
    hits
}

/// `sweepShapeAll(_:filter:maxHits:)`.
pub(crate) fn sweep_shape_all(
    backend: &NatselPhysicsBackend,
    query: &PhysicsSweepShapeQuery,
    filter: &PhysicsQueryFilter,
    max_hits: usize,
) -> Vec<PhysicsSweepHit> {
    if max_hits == 0 {
        return Vec::new();
    }
    let distance = simd_length(query.translation);
    if !distance.is_finite() {
        return Vec::new();
    }
    if distance == 0.0 {
        // A zero-length sweep is a plain overlap, reported at fraction 0.
        let overlap = overlap_shape(
            backend,
            &{
                let mut overlap = PhysicsOverlapShapeQuery::new(query.shape, query.position);
                overlap.rotation = query.rotation;
                overlap.max_results = max_hits;
                overlap
            },
            filter,
        );
        return overlap
            .into_iter()
            .map(|hit| {
                PhysicsSweepHit::new(
                    hit.entity,
                    hit.sub_shape_id,
                    0.0,
                    0.0,
                    query.position,
                    Float3::ZERO,
                    hit.bounds,
                    hit.is_trigger,
                )
            })
            .collect();
    }
    let (points, radius) = query_points(query.shape, query.rotation);
    let proxy = shape_proxy(&points, radius);
    // Natsel's cast callback is `Fn`, so hits are gathered through a `RefCell`.
    let hits: std::cell::RefCell<Vec<PhysicsSweepHit>> = std::cell::RefCell::new(Vec::new());
    let input = natsel::types::queries::ShapeCastInput {
        proxy,
        translation: NatselPhysicsBackend::nv(query.translation),
        can_encroach: true,
        ..natsel::types::queries::ShapeCastInput::default()
    };
    backend.world.cast_shape(
        NatselPhysicsBackend::np(query.position),
        proxy,
        NatselPhysicsBackend::nv(query.translation),
        &natsel::types::shape_def::QueryFilter::default_filter(),
        Some(&|id, point, normal, fraction| {
            if !natsel_shapes::accepts(backend, id, filter) {
                return 1.0;
            }
            let Some(owner) = natsel_shapes::shape_owner(backend, id) else {
                return 1.0;
            };
            // The native cast keeps a solver separation. Project the moving proxy's
            // support point onto the returned contact plane to report geometric
            // travel, which is what the query contract requires.
            let plane_normal = NatselPhysicsBackend::sv(normal);
            let approach = simd_dot(plane_normal, query.translation);
            let mut geometric_fraction = fraction;
            if approach < -f32::EPSILON && !points.is_empty() {
                let support = points
                    .iter()
                    .map(|candidate| simd_dot(plane_normal, NatselPhysicsBackend::sv(*candidate)))
                    .fold(f32::MAX, f32::min);
                let gap = simd_dot(
                    plane_normal,
                    query.position + query.translation * fraction
                        - NatselPhysicsBackend::sv_pos(point),
                ) + support
                    - radius;
                geometric_fraction = (fraction - gap / approach).max(0.0);
                if geometric_fraction > 1.0 + 4.0 * f32::EPSILON {
                    return 1.0;
                }
                geometric_fraction = geometric_fraction.min(1.0);
            }
            hits.borrow_mut().push(PhysicsSweepHit::new(
                owner.entity,
                owner.child,
                geometric_fraction,
                distance * geometric_fraction,
                query.position + query.translation * geometric_fraction,
                plane_normal,
                natsel_shapes::bounds(backend, id),
                backend
                    .bodies
                    .get(&owner.entity)
                    .and_then(|record| record.descriptor.collider.as_ref())
                    .is_some_and(|collider| collider.is_trigger),
            ));
            1.0
        }),
    );
    let _ = input;
    let mut hits = hits.into_inner();
    sort_sweep_hits(&mut hits);
    hits.truncate(max_hits);
    hits
}

/// `withQueryProxy`'s point/radius pair, rotated into world space by the caller's
/// quaternion.
fn query_points(
    shape: PhysicsQueryShape,
    rotation: Float4,
) -> (Vec<natsel::math::types::Vec3>, f32) {
    let quaternion = NatselPhysicsBackend::sq(NatselPhysicsBackend::nq(rotation));
    let quaternion = diffuse_math::simd::simd_compat::Quatf::from_vector(quaternion);
    let (mut points, radius): (Vec<Float3>, f32) = match shape {
        PhysicsQueryShape::Sphere { radius } => (vec![Float3::ZERO], radius.max(0.0)),
        PhysicsQueryShape::Capsule {
            radius,
            half_height,
        } => (
            vec![
                Float3::new(0.0, -half_height, 0.0),
                Float3::new(0.0, half_height, 0.0),
            ],
            radius.max(0.0),
        ),
        PhysicsQueryShape::Box { half_extents } => {
            let mut points = Vec::with_capacity(8);
            for x in [-1.0f32, 1.0] {
                for y in [-1.0f32, 1.0] {
                    for z in [-1.0f32, 1.0] {
                        points.push(Float3::new(
                            half_extents.x * x,
                            half_extents.y * y,
                            half_extents.z * z,
                        ));
                    }
                }
            }
            (points, 0.0)
        }
    };
    for point in points.iter_mut() {
        let rotated = quaternion.act(*point);
        *point = Float3::new(rotated.x, rotated.y, rotated.z);
    }
    (
        points.into_iter().map(NatselPhysicsBackend::nv).collect(),
        radius,
    )
}

fn shape_proxy(points: &[natsel::math::types::Vec3], radius: f32) -> ShapeProxy {
    ShapeProxy::new(
        if points.is_empty() {
            None
        } else {
            Some(points.as_ptr())
        },
        points.len() as i32,
        radius,
    )
}

/// `detectTriggerFrame(maxEventCount:)`.
pub(crate) fn detect_trigger_frame(
    backend: &mut NatselPhysicsBackend,
    max_event_count: usize,
) -> TriggerFrameResource {
    if max_event_count == 0 {
        return TriggerFrameResource::default();
    }
    let mut current: BTreeSet<Pair> = BTreeSet::new();
    let mut trigger_entities: Vec<EntityID> = backend
        .bodies
        .iter()
        .filter(|(_, record)| {
            record
                .descriptor
                .collider
                .as_ref()
                .is_some_and(|collider| collider.is_trigger)
        })
        .map(|(entity, _)| *entity)
        .collect();
    trigger_entities.sort_by_key(|entity| entity.raw_value());

    for entity in trigger_entities {
        let Some(record) = backend.bodies.get(&entity) else {
            continue;
        };
        let Some(collider) = record.descriptor.collider.clone() else {
            continue;
        };
        if !collider.is_trigger {
            continue;
        }
        let box_aabb = backend.world.body_world_aabb(record.id);
        let bounds = crate::physics::collider::SpatialAABB::new(
            NatselPhysicsBackend::sv_pos(box_aabb.lower_bound),
            NatselPhysicsBackend::sv_pos(box_aabb.upper_bound),
        );
        let candidates = overlap_shape(
            backend,
            &PhysicsOverlapShapeQuery::new(
                PhysicsQueryShape::Box {
                    half_extents: natsel_shapes::aabb_half_extents(&bounds),
                },
                natsel_shapes::aabb_center(&bounds),
            ),
            &PhysicsQueryFilter::with_options(
                Some(entity),
                BTreeSet::new(),
                true,
                Some(collider.layer_id),
                collider.layer_mask,
            ),
        );
        let mut other_entities: Vec<EntityID> = candidates.iter().map(|hit| hit.entity).collect();
        other_entities.sort_by_key(|other| other.raw_value());
        other_entities.dedup();
        for other_entity in other_entities {
            let Some(trigger_body) = backend.bodies.get(&entity).map(|record| record.id) else {
                continue;
            };
            let other = backend
                .bodies
                .get(&other_entity)
                .map(|record| (record.id, record.shapes.clone()))
                .or_else(|| {
                    backend
                        .characters
                        .get(&other_entity)
                        .map(|record| (record.character.inner_body_id(), Vec::new()))
                })
                .or_else(|| {
                    backend
                        .soft_query_surfaces
                        .get(&other_entity)
                        .map(|surface| (surface.body, vec![surface.shape]))
                });
            let Some((other_id, _other_shapes)) = other else {
                continue;
            };
            let pose = backend.world.body_transform(trigger_body);
            let other_pose = backend.world.body_transform(other_id);
            let mut overlap = false;
            for shape in backend
                .bodies
                .get(&entity)
                .map(|record| record.shapes.clone())
                .unwrap_or_default()
            {
                overlap = with_fixture_proxy(backend, shape, pose, |proxy| {
                    backend.world.body_overlap_shape(
                        other_id,
                        pose.p,
                        proxy,
                        &natsel::types::shape_def::QueryFilter::default_filter(),
                        other_pose,
                    )
                })
                .unwrap_or(false);
                if overlap {
                    break;
                }
            }
            // Mesh fixtures cannot be query proxies; try the convex side in reverse.
            if !overlap {
                for shape in backend
                    .bodies
                    .get(&other_entity)
                    .map(|record| record.shapes.clone())
                    .unwrap_or_default()
                {
                    overlap = with_fixture_proxy(backend, shape, other_pose, |proxy| {
                        backend.world.body_overlap_shape(
                            trigger_body,
                            other_pose.p,
                            proxy,
                            &natsel::types::shape_def::QueryFilter::default_filter(),
                            pose,
                        )
                    })
                    .unwrap_or(false);
                    if overlap {
                        break;
                    }
                }
            }
            if overlap {
                current.insert(Pair::ordered(entity, other_entity));
            }
        }
    }

    let enters: Vec<Pair> = current
        .difference(&backend.trigger_pairs)
        .copied()
        .take(max_event_count)
        .collect();
    let exits: Vec<Pair> = backend
        .trigger_pairs
        .difference(&current)
        .copied()
        .take(max_event_count)
        .collect();
    let active: Vec<Pair> = current.iter().copied().take(max_event_count).collect();
    // Swift `triggerPairs = current` before returning: without this, exits are
    // computed against an empty set forever and a leaving body never emits Exit.
    backend.trigger_pairs = current;
    TriggerFrameResource::new(
        enters
            .into_iter()
            .map(|pair| TriggerEvent::new(pair.a, pair.b, TriggerEventKind::Enter))
            .collect(),
        exits
            .into_iter()
            .map(|pair| TriggerEvent::new(pair.a, pair.b, TriggerEventKind::Exit))
            .collect(),
        active
            .into_iter()
            .map(|pair| TriggerEvent::new(pair.a, pair.b, TriggerEventKind::Active))
            .collect(),
    )
}

/// `withFixtureProxy` — run `body` with the fixture's support points and radius.
fn with_fixture_proxy<R>(
    backend: &NatselPhysicsBackend,
    shape: ShapeID,
    pose: natsel::math::types::WorldTransform,
    body: impl FnOnce(ShapeProxy) -> R,
) -> Option<R> {
    let (mut points, radius) = if let Some(sphere) = backend.world.shape_sphere(shape) {
        (vec![sphere.center], sphere.radius)
    } else if let Some(capsule) = backend.world.shape_capsule(shape) {
        (vec![capsule.center1, capsule.center2], capsule.radius)
    } else {
        let hull = backend.world.shape_hull(shape)?;
        (hull.vertex_positions(), 0.0)
    };
    for point in points.iter_mut() {
        *point = natsel::math::functions::rotate_vector(pose.q, *point);
    }
    let proxy = shape_proxy(&points, radius);
    Some(body(proxy))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_length_ray_returns_nothing() {
        let backend = NatselPhysicsBackend::new();
        let query = PhysicsRaycastQuery::new(Float3::ZERO, Float3::ZERO);
        assert!(raycast_all(&backend, &query, &PhysicsQueryFilter::new(), 4).is_empty());
    }

    #[test]
    fn zero_max_hits_returns_nothing() {
        let backend = NatselPhysicsBackend::new();
        let query = PhysicsRaycastQuery::new(Float3::ZERO, Float3::new(1.0, 0.0, 0.0));
        assert!(raycast_all(&backend, &query, &PhysicsQueryFilter::new(), 0).is_empty());
    }

    #[test]
    fn non_finite_direction_returns_nothing() {
        let backend = NatselPhysicsBackend::new();
        let query = PhysicsRaycastQuery::new(Float3::ZERO, Float3::new(f32::NAN, 0.0, 0.0));
        assert!(raycast_all(&backend, &query, &PhysicsQueryFilter::new(), 4).is_empty());
    }

    #[test]
    fn box_query_proxy_has_eight_corners_and_no_radius() {
        let (points, radius) = query_points(
            PhysicsQueryShape::Box {
                half_extents: Float3::new(1.0, 2.0, 3.0),
            },
            Float4::new(0.0, 0.0, 0.0, 1.0),
        );
        assert_eq!(points.len(), 8);
        assert_eq!(radius, 0.0);
    }

    #[test]
    fn sphere_query_proxy_has_unit_radius_floor_and_one_point() {
        let (points, radius) = query_points(
            PhysicsQueryShape::Sphere { radius: -2.0 },
            Float4::new(0.0, 0.0, 0.0, 1.0),
        );
        assert_eq!(points.len(), 1);
        // A negative radius floors at zero rather than flipping the proxy.
        assert_eq!(radius, 0.0);
    }

    #[test]
    fn trigger_frame_with_zero_budget_is_empty() {
        let mut backend = NatselPhysicsBackend::new();
        let frame = detect_trigger_frame(&mut backend, 0);
        assert!(frame.enters.is_empty());
        assert!(frame.exits.is_empty());
        assert!(frame.active.is_empty());
    }
}
