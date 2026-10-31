//! Collider shapes and authored collider state.

use diffuse_math::simd::simd_compat::{Float3, Float4, simd_max, simd_min};

use crate::entity_id::RuntimeComponent;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColliderShapeKind {
    Box,
    Sphere,
    Capsule,
    Cylinder,
    HeightField,
    Mesh,
    Convex,
}

impl ColliderShapeKind {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            ColliderShapeKind::Box => "box",
            ColliderShapeKind::Sphere => "sphere",
            ColliderShapeKind::Capsule => "capsule",
            ColliderShapeKind::Cylinder => "cylinder",
            ColliderShapeKind::HeightField => "heightField",
            ColliderShapeKind::Mesh => "mesh",
            ColliderShapeKind::Convex => "convex",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "box" => Some(ColliderShapeKind::Box),
            "sphere" => Some(ColliderShapeKind::Sphere),
            "capsule" => Some(ColliderShapeKind::Capsule),
            "cylinder" => Some(ColliderShapeKind::Cylinder),
            "heightField" => Some(ColliderShapeKind::HeightField),
            "mesh" => Some(ColliderShapeKind::Mesh),
            "convex" => Some(ColliderShapeKind::Convex),
            _ => None,
        }
    }

    pub const ALL: [ColliderShapeKind; 7] = [
        ColliderShapeKind::Box,
        ColliderShapeKind::Sphere,
        ColliderShapeKind::Capsule,
        ColliderShapeKind::Cylinder,
        ColliderShapeKind::HeightField,
        ColliderShapeKind::Mesh,
        ColliderShapeKind::Convex,
    ];
}

#[derive(Clone, Debug, PartialEq)]
pub enum ColliderShape {
    Box {
        half_extents: Float3,
        center: Float3,
    },
    Sphere {
        radius: f32,
        center: Float3,
    },
    Capsule {
        radius: f32,
        half_height: f32,
        center: Float3,
    },
    Cylinder {
        radius: f32,
        half_height: f32,
        center: Float3,
    },
    HeightField {
        resource_id: Option<String>,
        center: Float3,
    },
    Mesh {
        resource_id: Option<String>,
        center: Float3,
    },
    Convex {
        resource_id: Option<String>,
        center: Float3,
    },
}

impl ColliderShape {
    pub fn kind(&self) -> ColliderShapeKind {
        match self {
            ColliderShape::Box { .. } => ColliderShapeKind::Box,
            ColliderShape::Sphere { .. } => ColliderShapeKind::Sphere,
            ColliderShape::Capsule { .. } => ColliderShapeKind::Capsule,
            ColliderShape::Cylinder { .. } => ColliderShapeKind::Cylinder,
            ColliderShape::HeightField { .. } => ColliderShapeKind::HeightField,
            ColliderShape::Mesh { .. } => ColliderShapeKind::Mesh,
            ColliderShape::Convex { .. } => ColliderShapeKind::Convex,
        }
    }

    pub fn center(&self) -> Float3 {
        match self {
            ColliderShape::Box { center, .. }
            | ColliderShape::Sphere { center, .. }
            | ColliderShape::Capsule { center, .. }
            | ColliderShape::Cylinder { center, .. }
            | ColliderShape::HeightField { center, .. }
            | ColliderShape::Mesh { center, .. }
            | ColliderShape::Convex { center, .. } => *center,
        }
    }

    pub fn resource_id(&self) -> Option<&str> {
        match self {
            ColliderShape::Mesh { resource_id, .. }
            | ColliderShape::HeightField { resource_id, .. }
            | ColliderShape::Convex { resource_id, .. } => resource_id.as_deref(),
            _ => None,
        }
    }

    pub fn replacing_center(&self, center: Float3) -> ColliderShape {
        match self {
            ColliderShape::Box { half_extents, .. } => ColliderShape::Box {
                half_extents: *half_extents,
                center,
            },
            ColliderShape::Sphere { radius, .. } => ColliderShape::Sphere {
                radius: *radius,
                center,
            },
            ColliderShape::Capsule {
                radius,
                half_height,
                ..
            } => ColliderShape::Capsule {
                radius: *radius,
                half_height: *half_height,
                center,
            },
            ColliderShape::Cylinder {
                radius,
                half_height,
                ..
            } => ColliderShape::Cylinder {
                radius: *radius,
                half_height: *half_height,
                center,
            },
            ColliderShape::HeightField { resource_id, .. } => ColliderShape::HeightField {
                resource_id: resource_id.clone(),
                center,
            },
            ColliderShape::Mesh { resource_id, .. } => ColliderShape::Mesh {
                resource_id: resource_id.clone(),
                center,
            },
            ColliderShape::Convex { resource_id, .. } => ColliderShape::Convex {
                resource_id: resource_id.clone(),
                center,
            },
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ColliderShapeInstance {
    pub shape: ColliderShape,
    pub local_position: Float3,
    /// Quaternion encoded as `(x, y, z, w)`.
    pub local_rotation: Float4,
    pub local_scale: Float3,
}

impl ColliderShapeInstance {
    pub fn new(shape: ColliderShape) -> Self {
        ColliderShapeInstance {
            shape,
            local_position: Float3::ZERO,
            local_rotation: Float4::new(0.0, 0.0, 0.0, 1.0),
            local_scale: Float3::ONE,
        }
    }

    pub fn with_transform(
        shape: ColliderShape,
        local_position: Float3,
        local_rotation: Float4,
        local_scale: Float3,
    ) -> Self {
        ColliderShapeInstance {
            shape,
            local_position,
            local_rotation,
            local_scale,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsMaterial {
    pub friction: f32,
    pub restitution: f32,
    pub density: f32,
}

impl PhysicsMaterial {
    pub fn new(friction: f32, restitution: f32, density: f32) -> Self {
        PhysicsMaterial {
            friction: friction.max(0.0),
            // Swift `max(0, min(restitution, 1))`.
            restitution: restitution.clamp(0.0, 1.0),
            density: density.max(0.0),
        }
    }
}

impl Default for PhysicsMaterial {
    fn default() -> Self {
        PhysicsMaterial {
            friction: 0.6,
            restitution: 0.0,
            density: 1.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Collider {
    pub shapes: Vec<ColliderShapeInstance>,
    pub is_trigger: bool,
    pub layer_id: u16,
    pub layer_mask: u16,
    pub material: PhysicsMaterial,
}

impl Collider {
    /// Compatibility access to the first child shape.
    pub fn shape(&self) -> ColliderShape {
        self.shapes.first().map_or_else(
            || ColliderShape::Box {
                half_extents: Float3::splat(0.5),
                center: Float3::ZERO,
            },
            |instance| instance.shape.clone(),
        )
    }

    /// Writing replaces the first shape, creating one when the list is empty.
    pub fn set_shape(&mut self, shape: ColliderShape) {
        if self.shapes.is_empty() {
            self.shapes = vec![ColliderShapeInstance::new(shape)];
        } else {
            self.shapes[0].shape = shape;
        }
    }

    pub fn with_shape(shape: ColliderShape) -> Self {
        Collider {
            shapes: vec![ColliderShapeInstance::new(shape)],
            is_trigger: false,
            layer_id: 0,
            layer_mask: u16::MAX,
            material: PhysicsMaterial::default(),
        }
    }

    pub fn with_shapes(shapes: Vec<ColliderShapeInstance>) -> Self {
        Collider {
            shapes,
            is_trigger: false,
            layer_id: 0,
            layer_mask: u16::MAX,
            material: PhysicsMaterial::default(),
        }
    }
}

impl RuntimeComponent for Collider {}

/// Axis-aligned bounds used by the spatial index and debug drawing.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpatialAABB {
    pub min: Float3,
    pub max: Float3,
}

impl SpatialAABB {
    pub fn new(min: Float3, max: Float3) -> Self {
        SpatialAABB { min, max }
    }

    pub fn from_center_half_extents(center: Float3, half_extents: Float3) -> Self {
        SpatialAABB {
            min: center - half_extents,
            max: center + half_extents,
        }
    }

    pub fn center(&self) -> Float3 {
        (self.min + self.max) * 0.5
    }

    pub fn half_extents(&self) -> Float3 {
        (self.max - self.min) * 0.5
    }

    pub fn is_valid(&self) -> bool {
        self.min.x <= self.max.x && self.min.y <= self.max.y && self.min.z <= self.max.z
    }

    pub fn surface_area(&self) -> f32 {
        let extents = self.max - self.min;
        2.0 * (extents.x * extents.y + extents.y * extents.z + extents.z * extents.x)
    }

    pub fn intersects(&self, other: &SpatialAABB) -> bool {
        self.min.x <= other.max.x
            && self.max.x >= other.min.x
            && self.min.y <= other.max.y
            && self.max.y >= other.min.y
            && self.min.z <= other.max.z
            && self.max.z >= other.min.z
    }

    pub fn merged(&self, other: &SpatialAABB) -> SpatialAABB {
        SpatialAABB {
            min: simd_min(self.min, other.min),
            max: simd_max(self.max, other.max),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shape_kind_round_trips_raw_values() {
        for kind in ColliderShapeKind::ALL {
            assert_eq!(
                ColliderShapeKind::from_raw_value(kind.raw_value()),
                Some(kind)
            );
        }
        assert_eq!(ColliderShapeKind::HeightField.raw_value(), "heightField");
    }

    #[test]
    fn collider_first_shape_accessor_defaults_to_unit_box() {
        let collider = Collider::with_shapes(Vec::new());
        assert_eq!(
            collider.shape(),
            ColliderShape::Box {
                half_extents: Float3::splat(0.5),
                center: Float3::ZERO,
            }
        );
    }

    #[test]
    fn setting_shape_on_empty_collider_appends() {
        let mut collider = Collider::with_shapes(Vec::new());
        collider.set_shape(ColliderShape::Sphere {
            radius: 2.0,
            center: Float3::ZERO,
        });
        assert_eq!(collider.shapes.len(), 1);
        assert_eq!(collider.shape().kind(), ColliderShapeKind::Sphere);
    }

    #[test]
    fn material_clamps_restitution_into_unit_range() {
        let material = PhysicsMaterial::new(-1.0, 5.0, -2.0);
        assert_eq!(material.friction, 0.0);
        assert_eq!(material.restitution, 1.0);
        assert_eq!(material.density, 0.0);
    }

    #[test]
    fn aabb_intersection_and_surface_area() {
        let a = SpatialAABB::new(Float3::ZERO, Float3::splat(2.0));
        let b = SpatialAABB::new(Float3::splat(1.0), Float3::splat(3.0));
        let c = SpatialAABB::new(Float3::splat(5.0), Float3::splat(6.0));
        assert!(a.intersects(&b));
        assert!(!a.intersects(&c));
        assert_eq!(a.surface_area(), 24.0);
        assert_eq!(a.center(), Float3::splat(1.0));
    }
}
