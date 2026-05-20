import SIMDCompat

struct SkyboxUniforms {
    var invViewProj: simd_float4x4
    var skyTint: SIMD4<Float>
    var horizonTint: SIMD4<Float>
    var groundTint: SIMD4<Float>
}

struct TonemapUniforms {
    var params: SIMD4<Float>
}

struct BloomUniforms {
    var params: SIMD4<Float>
}

struct TAAUniforms {
    var params: SIMD4<Float>
}

struct SSAOUniforms {
    var projection: simd_float4x4
    var invProjection: simd_float4x4
    var resolutionRadius: SIMD4<Float>
    var tuning: SIMD4<Float>
}

struct SSRUniforms {
    var projection: simd_float4x4
    var invProjection: simd_float4x4
    var resolutionIntensity: SIMD4<Float>
    var tracing: SIMD4<Float>
}

struct StylizedCharacterUniforms {
    var toonThresholds: SIMD4<Float>
    var toonLevels: SIMD4<Float>
    var inkWashColor: SIMD4<Float>
    var params: SIMD4<Float>
}
