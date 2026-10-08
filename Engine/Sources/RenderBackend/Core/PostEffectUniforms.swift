import SIMDCompat

/// Shared production tuning and binary uniform groups for both renderers.
enum PostEffectUniforms {
    static func frame(used: RenderDrawableSize, capacity: RenderDrawableSize) -> PostFrameUniforms {
        let width = Float(max(capacity.width,1)), height = Float(max(capacity.height,1))
        return PostFrameUniforms(uvScaleMax: SIMD4(Float(used.width)/width,Float(used.height)/height,
            max(Float(used.width)-0.5,0.5)/width,max(Float(used.height)-0.5,0.5)/height))
    }
    static func ssao(projection: simd_float4x4, size: RenderDrawableSize) -> SSAOUniforms {
        SSAOUniforms(projection: projection,invProjection: simd_inverse(projection),
            resolutionRadius: SIMD4(Float(size.width),Float(size.height),0.45,0),tuning: SIMD4(0.025,0.7,1.35,0))
    }
    static func ssr(projection: simd_float4x4, size: RenderDrawableSize) -> SSRUniforms {
        SSRUniforms(projection: projection,invProjection: simd_inverse(projection),
            resolutionIntensity: SIMD4(Float(size.width),Float(size.height),0.22,0),tracing: SIMD4(14,32,0.18,0.08))
    }
    static func taa(size: RenderDrawableSize, historyValid: Bool) -> TAAUniforms {
        TAAUniforms(params: SIMD4(0.12,1/Float(max(size.width,1)),1/Float(max(size.height,1)),historyValid ? 1 : 0))
    }
    static func bloom(size: RenderDrawableSize) -> BloomUniforms {
        BloomUniforms(params: SIMD4(1.05,0.75,1/Float(max(size.width,1)),1/Float(max(size.height,1))))
    }
}
