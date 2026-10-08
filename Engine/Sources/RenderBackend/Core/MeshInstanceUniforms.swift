import SIMDCompat

/// Shared 160-byte GPU instance ABI for native and WGSL mesh passes.
struct MeshInstanceUniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var colorTint: SIMD4<Float>
    var material: SIMD4<Float> = .zero
}
