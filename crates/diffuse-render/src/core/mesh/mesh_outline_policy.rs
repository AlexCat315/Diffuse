//! Whether a mesh can take an inverted-hull outline.

use diffuse_math::simd::simd_compat::Float3;

pub enum MeshOutlinePolicy {}

impl MeshOutlinePolicy {
    /// Inverted hulls have no silhouette on zero-thickness surfaces, so a mesh
    /// whose smallest extent is effectively zero is excluded. A mesh without
    /// bounds is included (Swift's `guard let bounds else { return true }`).
    pub fn includes(bounds: Option<(Float3, Float3)>) -> bool {
        let Some((min, max)) = bounds else {
            return true;
        };
        let extent = max - min;
        extent.x.min(extent.y).min(extent.z) > 1e-7
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mesh_without_bounds_is_included() {
        assert!(MeshOutlinePolicy::includes(None));
    }

    #[test]
    fn a_flat_surface_is_excluded() {
        let flat = (Float3::new(0.0, 0.0, 0.0), Float3::new(1.0, 0.0, 1.0));
        assert!(!MeshOutlinePolicy::includes(Some(flat)));
    }

    #[test]
    fn a_volume_is_included() {
        let volume = (Float3::new(0.0, 0.0, 0.0), Float3::new(1.0, 1.0, 1.0));
        assert!(MeshOutlinePolicy::includes(Some(volume)));
    }

    #[test]
    fn the_threshold_is_the_smallest_extent() {
        // Width and depth are large; only the tiny height disqualifies it.
        let sliver = (Float3::new(0.0, 0.0, 0.0), Float3::new(10.0, 1e-8, 10.0));
        assert!(!MeshOutlinePolicy::includes(Some(sliver)));
    }
}
