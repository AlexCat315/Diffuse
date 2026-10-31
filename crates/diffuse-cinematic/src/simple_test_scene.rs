//! `SimpleTestScene` — a ground plane plus a sphere for end-to-end validation.

use diffuse_math::simd::simd_compat::{Float3, simd_dot, simd_normalize};

use crate::path_tracer::{HitResult, Ray, SceneGeometry};

pub struct SimpleTestScene {
    sphere_radius: f32,
    sphere_center: Float3,
}

impl SimpleTestScene {
    /// Swift defaults: radius 0.5, centre (0, 1, 0).
    pub fn new(sphere_radius: f32, sphere_center: Float3) -> Self {
        SimpleTestScene {
            sphere_radius,
            sphere_center,
        }
    }

    pub fn with_defaults() -> Self {
        SimpleTestScene {
            sphere_radius: 0.5,
            sphere_center: Float3::new(0.0, 1.0, 0.0),
        }
    }

    fn intersect_sphere(&self, ray: &Ray) -> Option<HitResult> {
        let oc = ray.origin - self.sphere_center;
        let a = simd_dot(ray.direction, ray.direction);
        let b = 2.0 * simd_dot(oc, ray.direction);
        let c = simd_dot(oc, oc) - self.sphere_radius * self.sphere_radius;
        let discriminant = b * b - 4.0 * a * c;
        if discriminant <= 0.0 {
            return None;
        }

        let sqrt_d = discriminant.sqrt();
        let t1 = (-b - sqrt_d) / (2.0 * a);
        let t2 = (-b + sqrt_d) / (2.0 * a);
        let t = if t1 > 0.001 {
            t1
        } else if t2 > 0.001 {
            t2
        } else {
            -1.0
        };
        if t <= 0.001 {
            return None;
        }

        let position = ray.point_at(t);
        let normal = simd_normalize(position - self.sphere_center);
        Some(HitResult {
            t,
            position,
            normal,
            albedo: Float3::new(0.7, 0.3, 0.3), // red sphere
            emission: Float3::ZERO,
            roughness: 0.4,
            metallic: 0.1,
        })
    }

    fn intersect_ground(&self, ray: &Ray) -> Option<HitResult> {
        if ray.direction.y.abs() <= 1e-8 {
            return None;
        }
        let t = -ray.origin.y / ray.direction.y;
        if t <= 0.001 {
            return None;
        }

        let position = ray.point_at(t);
        // Checkerboard pattern.
        let checker = ((position.x * 2.0).floor() as i64 + (position.z * 2.0).floor() as i64) & 1;
        let albedo = if checker == 0 {
            Float3::new(0.8, 0.8, 0.8)
        } else {
            Float3::new(0.2, 0.2, 0.2)
        };

        Some(HitResult {
            t,
            position,
            normal: Float3::new(0.0, 1.0, 0.0),
            albedo,
            emission: Float3::ZERO,
            roughness: 0.9,
            metallic: 0.0,
        })
    }
}

impl Default for SimpleTestScene {
    fn default() -> Self {
        Self::with_defaults()
    }
}

impl SceneGeometry for SimpleTestScene {
    fn intersect(&self, ray: &Ray) -> Option<HitResult> {
        let mut closest = self.intersect_sphere(ray);
        if let Some(ground) = self.intersect_ground(ray) {
            match &closest {
                Some(current) if current.t <= ground.t => {}
                _ => closest = Some(ground),
            }
        }
        closest
    }

    fn bounds(&self) -> (Float3, Float3) {
        let r = self.sphere_radius;
        let c = self.sphere_center;
        (
            Float3::new(c.x - r, 0.0, c.z - r),
            Float3::new(c.x + r, c.y + r, c.z + r),
        )
    }
}
