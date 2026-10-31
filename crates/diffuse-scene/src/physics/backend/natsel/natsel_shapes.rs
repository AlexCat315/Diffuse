//! Collider-shape creation and query filtering for the Natsel backend.
//!
//! Ported from `Engine/Sources/SceneRuntime/Physics/Backend/Natsel/NatselShapes.swift`.
//!
//! Every shape is placed by transforming its local geometry through the instance
//! transform and the body scale, so one code path covers authored offsets, rotations
//! and scaled bodies. Boxes and cylinders become convex hulls because Natsel has no
//! box or cylinder shape.

use diffuse_math::simd::simd_compat::{Float3, Float4, simd_abs};

use natsel::collision::hull_builder::create_hull;
use natsel::types::geometry::{Capsule, Sphere};
use natsel::types::ids::{BodyID, ShapeID};
use natsel::types::shape_def::ShapeDef;

use crate::physics::backend::physics_descriptors::PhysicsBodyDescriptor;
use crate::physics::collider::{Collider, ColliderShape, SpatialAABB};
use crate::physics::physics_types::{PhysicsBackendError, PhysicsBackendErrorCode};
use crate::physics::queries::physics_query_types::PhysicsQueryFilter;

use super::natsel_physics_backend::{NatselPhysicsBackend, ShapeOwner};

/// The centre of a bounds box — `(min + max) * 0.5`.
pub(crate) fn aabb_center(bounds: &SpatialAABB) -> Float3 {
    Float3::new(
        (bounds.min.x + bounds.max.x) * 0.5,
        (bounds.min.y + bounds.max.y) * 0.5,
        (bounds.min.z + bounds.max.z) * 0.5,
    )
}

/// Half the extent of a bounds box — `(max - min) * 0.5`.
pub(crate) fn aabb_half_extents(bounds: &SpatialAABB) -> Float3 {
    Float3::new(
        (bounds.max.x - bounds.min.x) * 0.5,
        (bounds.max.y - bounds.min.y) * 0.5,
        (bounds.max.z - bounds.min.z) * 0.5,
    )
}

/// `shapeFilter(_:)` — physical categories occupy bits 0...15.
pub(crate) fn shape_filter(collider: &Collider) -> natsel::types::shape_def::Filter {
    natsel::types::shape_def::Filter::new(
        1u64 << collider.layer_id.min(15),
        u64::from(collider.layer_mask),
        0,
    )
}

/// `createShapes(_:body:)` — one Natsel shape per child instance, in authored order.
pub(crate) fn create_shapes(
    backend: &mut NatselPhysicsBackend,
    descriptor: &PhysicsBodyDescriptor,
    body: BodyID,
) -> Result<Vec<(u32, ShapeID)>, PhysicsBackendError> {
    let Some(collider) = descriptor.collider.clone() else {
        return Ok(Vec::new());
    };
    if collider.shapes.is_empty() {
        return Err(NatselPhysicsBackend::failure(
            PhysicsBackendErrorCode::InvalidShape,
            "A collider needs at least one shape",
        ));
    }
    let body_scale = NatselPhysicsBackend::scale(descriptor.world_transform.matrix);
    let mut result: Vec<(u32, ShapeID)> = Vec::new();

    for (child, instance) in collider.shapes.iter().enumerate() {
        let quaternion = diffuse_math::simd::simd_compat::Quatf::from_vector(normalize_quaternion(
            instance.local_rotation,
        ));
        let center = instance.shape.center();
        // Local point -> shape centre -> instance scale -> instance rotation ->
        // instance offset -> body scale.
        let point = |value: Float3| -> natsel::math::types::Vec3 {
            let local = Float3::new(
                instance.local_scale.x * (value.x + center.x),
                instance.local_scale.y * (value.y + center.y),
                instance.local_scale.z * (value.z + center.z),
            );
            let rotated = quaternion.act(local);
            NatselPhysicsBackend::nv(Float3::new(
                body_scale.x * (instance.local_position.x + rotated.x),
                body_scale.y * (instance.local_position.y + rotated.y),
                body_scale.z * (instance.local_position.z + rotated.z),
            ))
        };

        let mut base_material = natsel::types::shape_def::SurfaceMaterial::default_material();
        base_material.friction = collider.material.friction;
        base_material.restitution = collider.material.restitution;
        let mut def = ShapeDef {
            density: collider.material.density,
            base_material,
            filter: shape_filter(&collider),
            is_sensor: collider.is_trigger,
            enable_sensor_events: true,
            enable_contact_events: true,
            enable_hit_events: true,
            ..ShapeDef::default()
        };

        let id: ShapeID = match &instance.shape {
            ColliderShape::Box { half_extents, .. } => {
                let mut vertices = Vec::with_capacity(8);
                for x in [-1.0f32, 1.0] {
                    for y in [-1.0f32, 1.0] {
                        for z in [-1.0f32, 1.0] {
                            vertices.push(point(Float3::new(
                                half_extents.x * x,
                                half_extents.y * y,
                                half_extents.z * z,
                            )));
                        }
                    }
                }
                let Some(hull) = create_hull(&vertices, 128) else {
                    return Err(NatselPhysicsBackend::failure(
                        PhysicsBackendErrorCode::InvalidShape,
                        "Invalid box collider",
                    ));
                };
                backend.world.create_hull_shape(body, &def, &hull)
            }
            ColliderShape::Sphere { radius, .. } => {
                let scale = simd_abs(Float3::new(
                    body_scale.x * instance.local_scale.x,
                    body_scale.y * instance.local_scale.y,
                    body_scale.z * instance.local_scale.z,
                ));
                let largest = scale.x.max(scale.y).max(scale.z);
                backend.world.create_sphere_shape(
                    body,
                    &def,
                    Sphere::new(point(Float3::ZERO), (radius * largest).max(0.0001)),
                )
            }
            ColliderShape::Capsule {
                radius,
                half_height,
                ..
            } => {
                let scale = simd_abs(Float3::new(
                    body_scale.x * instance.local_scale.x,
                    body_scale.y * instance.local_scale.y,
                    body_scale.z * instance.local_scale.z,
                ));
                // A capsule's radius spans X/Z, so those two axes decide it.
                let largest = scale.x.max(scale.z);
                backend.world.create_capsule_shape(
                    body,
                    &def,
                    Capsule::new(
                        point(Float3::new(0.0, -*half_height, 0.0)),
                        point(Float3::new(0.0, *half_height, 0.0)),
                        (radius * largest).max(0.0001),
                    ),
                )
            }
            ColliderShape::Cylinder {
                radius,
                half_height,
                ..
            } => {
                // 32-gon approximation, matching Swift's fixed tessellation.
                let mut vertices = Vec::with_capacity(64);
                for index in 0..32 {
                    let angle = index as f32 * 2.0 * std::f32::consts::PI / 32.0;
                    let cos_sin = natsel::math::functions::compute_cos_sin(angle);
                    for y in [-*half_height, *half_height] {
                        vertices.push(point(Float3::new(
                            radius * cos_sin.cosine,
                            y,
                            radius * cos_sin.sine,
                        )));
                    }
                }
                let Some(hull) = create_hull(&vertices, 128) else {
                    return Err(NatselPhysicsBackend::failure(
                        PhysicsBackendErrorCode::InvalidShape,
                        "Invalid cylinder collider",
                    ));
                };
                backend.world.create_hull_shape(body, &def, &hull)
            }
            ColliderShape::Convex { .. } => {
                // An empty geometry means "collider not baked yet", not an error.
                if let Some(geometry) = &descriptor.mesh_geometry
                    && geometry.positions.is_empty()
                    && geometry.triangle_indices.is_empty()
                {
                    continue;
                }
                let Some(geometry) = &descriptor.mesh_geometry else {
                    return Err(NatselPhysicsBackend::failure(
                        PhysicsBackendErrorCode::InvalidShape,
                        "Convex collider requires valid geometry",
                    ));
                };
                let vertices: Vec<natsel::math::types::Vec3> = geometry
                    .positions
                    .iter()
                    .map(|position| point(*position))
                    .collect();
                let Some(hull) = create_hull(&vertices, 128) else {
                    return Err(NatselPhysicsBackend::failure(
                        PhysicsBackendErrorCode::InvalidShape,
                        "Convex collider requires valid geometry",
                    ));
                };
                backend.world.create_hull_shape(body, &def, &hull)
            }
            ColliderShape::Mesh { .. } | ColliderShape::HeightField { .. } => {
                if let Some(geometry) = &descriptor.mesh_geometry
                    && geometry.positions.is_empty()
                    && geometry.triangle_indices.is_empty()
                {
                    continue;
                }
                let Some(geometry) = &descriptor.mesh_geometry else {
                    return Err(NatselPhysicsBackend::failure(
                        PhysicsBackendErrorCode::InvalidShape,
                        "Triangle collider requires valid geometry",
                    ));
                };
                let vertices: Vec<natsel::math::types::Vec3> = geometry
                    .positions
                    .iter()
                    .map(|position| point(*position))
                    .collect();
                let indices: Vec<i32> = geometry
                    .triangle_indices
                    .iter()
                    .map(|index| *index as i32)
                    .collect();
                let Some(mesh) = natsel::collision::mesh::storage::TriangleMesh::new(
                    &vertices,
                    &indices,
                    None,
                    natsel::collision::mesh::build::MeshBuildOptions::default(),
                ) else {
                    return Err(NatselPhysicsBackend::failure(
                        PhysicsBackendErrorCode::InvalidShape,
                        "Triangle collider requires valid geometry",
                    ));
                };
                // A mesh shape needs one material slot per triangle group.
                def.materials = vec![def.base_material];
                backend.world.create_mesh_shape(
                    body,
                    &def,
                    mesh,
                    natsel::math::types::Vec3::new(1.0, 1.0, 1.0),
                )
            }
        };

        if id.is_null() {
            return Err(NatselPhysicsBackend::failure(
                PhysicsBackendErrorCode::InvalidShape,
                "Could not create Natsel collider",
            ));
        }
        result.push((child as u32, id));
    }
    Ok(result)
}

/// `simd_normalize` for the instance rotation. A zero or non-finite quaternion falls
/// back to identity so a defaulted field cannot inject NaN into every shape.
fn normalize_quaternion(value: Float4) -> Float4 {
    let length =
        (value.x * value.x + value.y * value.y + value.z * value.z + value.w * value.w).sqrt();
    if length > 0.0 && length.is_finite() {
        Float4::new(
            value.x / length,
            value.y / length,
            value.z / length,
            value.w / length,
        )
    } else {
        Float4::new(0.0, 0.0, 0.0, 1.0)
    }
}

/// `bounds(_:)` — the shape's world AABB.
pub(crate) fn bounds(backend: &NatselPhysicsBackend, shape: ShapeID) -> SpatialAABB {
    let aabb = backend.world.shape_world_aabb(shape);
    // `WorldAABB` bounds are world-space `Pos` (f64), unlike the f32 `AABB`.
    SpatialAABB::new(
        NatselPhysicsBackend::sv_pos(aabb.lower_bound),
        NatselPhysicsBackend::sv_pos(aabb.upper_bound),
    )
}

/// `accepts(_:_:)` — entity exclusions plus the trigger and layer rules.
pub(crate) fn accepts(
    backend: &NatselPhysicsBackend,
    shape: ShapeID,
    filter: &PhysicsQueryFilter,
) -> bool {
    let Some(owner) = shape_owner(backend, shape) else {
        return false;
    };
    if filter.ignored_entities.contains(&owner.entity)
        || filter.exclude_entity == Some(owner.entity)
    {
        return false;
    }
    let (layer_id, layer_mask) = if let Some(collider) = backend
        .bodies
        .get(&owner.entity)
        .and_then(|record| record.descriptor.collider.as_ref())
    {
        if !filter.include_triggers && collider.is_trigger {
            return false;
        }
        (collider.layer_id, collider.layer_mask)
    } else if let Some(controller) = backend
        .characters
        .get(&owner.entity)
        .map(|record| record.descriptor.controller.clone())
    {
        (controller.layer_id, controller.layer_mask)
    } else if let Some(soft) = backend
        .soft_bodies
        .get(&owner.entity)
        .map(|record| record.descriptor.soft_body.clone())
    {
        (soft.layer_id, soft.layer_mask)
    } else {
        return false;
    };
    // The query's mask must include this layer...
    if filter.layer_mask & (1u16 << layer_id.min(15)) == 0 {
        return false;
    }
    // ...and when the query names a layer, this collider's mask must include it.
    if let Some(layer) = filter.layer_id {
        return layer_mask & (1u16 << layer.min(15)) != 0;
    }
    true
}

/// `shapeOwner(_:)` — the explicit owner table, else the character whose inner body
/// carries the shape.
pub(crate) fn shape_owner(backend: &NatselPhysicsBackend, shape: ShapeID) -> Option<ShapeOwner> {
    if let Some(owner) = backend
        .owners
        .get(&super::natsel_physics_backend::ShapeIdKey::of(shape))
    {
        return Some(*owner);
    }
    let body = backend.world.shape_body(shape);
    backend
        .characters
        .iter()
        .find(|(_, record)| record.character.inner_body_id() == body)
        .map(|(entity, _)| ShapeOwner {
            entity: *entity,
            child: 0,
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entity_id::EntityID;
    use crate::runtime_world::{LocalTransform, WorldTransform};

    #[test]
    fn aabb_helpers_report_centre_and_half_extent() {
        let bounds = SpatialAABB::new(Float3::new(0.0, 0.0, 0.0), Float3::new(4.0, 2.0, 8.0));
        assert_eq!(aabb_center(&bounds), Float3::new(2.0, 1.0, 4.0));
        assert_eq!(aabb_half_extents(&bounds), Float3::new(2.0, 1.0, 4.0));
    }

    #[test]
    fn shape_filter_clamps_layer_to_fifteen() {
        let mut collider = Collider::with_shape(ColliderShape::Sphere {
            radius: 1.0,
            center: Float3::ZERO,
        });
        collider.layer_id = 40;
        collider.layer_mask = 0b1010;
        let filter = shape_filter(&collider);
        assert_eq!(filter.category_bits, 1u64 << 15);
        assert_eq!(filter.mask_bits, 0b1010);
    }

    #[test]
    fn normalize_quaternion_falls_back_to_identity() {
        assert_eq!(
            normalize_quaternion(Float4::new(0.0, 0.0, 0.0, 0.0)),
            Float4::new(0.0, 0.0, 0.0, 1.0)
        );
        let normalized = normalize_quaternion(Float4::new(0.0, 2.0, 0.0, 0.0));
        assert!((normalized.y - 1.0).abs() < 1e-6);
    }

    #[test]
    fn empty_collider_shape_list_is_rejected() {
        let mut backend = NatselPhysicsBackend::new();
        let mut collider = Collider::with_shape(ColliderShape::Sphere {
            radius: 1.0,
            center: Float3::ZERO,
        });
        collider.shapes.clear();
        let descriptor = PhysicsBodyDescriptor::new(
            EntityID::new(1, 0),
            LocalTransform::IDENTITY,
            WorldTransform::IDENTITY,
            None,
            Some(collider),
            None,
        );
        let body = backend
            .world
            .create_body(&natsel::types::body_def::BodyDef::default());
        let error = create_shapes(&mut backend, &descriptor, body).unwrap_err();
        assert_eq!(error.code, PhysicsBackendErrorCode::InvalidShape);
        backend.world.destroy_body(body);
    }
}
