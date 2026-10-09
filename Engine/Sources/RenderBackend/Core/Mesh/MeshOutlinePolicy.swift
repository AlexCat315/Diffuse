import SIMDCompat

enum MeshOutlinePolicy {
    /// Inverted hulls have no silhouette on zero-thickness surfaces.
    static func includes(bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?) -> Bool {
        guard let bounds else { return true }
        let extent = bounds.max-bounds.min
        return min(extent.x,min(extent.y,extent.z)) > 1e-7
    }
}
