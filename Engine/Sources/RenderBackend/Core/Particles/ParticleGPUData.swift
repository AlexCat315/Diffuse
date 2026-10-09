import SceneRuntime
import SIMDCompat

/// GPU mirror of `RenderParticle`. `position_size` packs world position (xyz) and
/// size (w); layout matches `ParticleInstance` in `particles.wgsl`.
struct GPUParticleInstance {
    var positionSize: SIMD4<Float>
    /// x: billboard rotation, y: `RenderParticleShape.rawValue`,
    /// z/w: ribbon V offset/scale.
    var rotation: SIMD4<Float>
    var color: SIMD4<Float>
    var uvRect: SIMD4<Float>
    var axisStretch: SIMD4<Float>
    var ribbonColor: SIMD4<Float>
    /// x/y: ribbon start/end width. z/w reserved.
    var ribbonParams: SIMD4<Float>
}

/// Non-indexed indirect draw arguments. Layout matches native and WebGPU's
/// DrawIndirectArgs: vertexCount, instanceCount, firstVertex, firstInstance.
struct GPUParticleIndirectDrawArgs {
    var vertexCount: UInt32
    var instanceCount: UInt32
    var firstVertex: UInt32
    var firstInstance: UInt32
}

/// Uniforms for GPU particle culling and compaction.
struct GPUParticleCullUniforms {
    var viewProj: simd_float4x4
    /// x: batch count.
    var params: SIMD4<UInt32>
}

/// Per-render-batch source and destination ranges for GPU culling. The culling
/// shader preserves order inside each batch by compacting visible instances
/// into the range beginning at `outputStart`.
struct GPUParticleCullBatch {
    var sourceStart: UInt32
    var sourceCount: UInt32
    var outputStart: UInt32
    var _padding: UInt32 = 0
}

/// Per-frame billboard uniforms; layout matches `ParticleUniforms` in the shader.
struct ParticleUniforms {
    var viewProj: simd_float4x4
    var cameraRight: SIMD4<Float>
    var cameraUp: SIMD4<Float>
    var cameraForward: SIMD4<Float>
}

extension GPUParticleInstance {
    var isFinite: Bool {
        Self.finite(positionSize) && Self.finite(rotation) && Self.finite(color) && Self.finite(uvRect)
            && Self.finite(axisStretch) && Self.finite(ribbonColor) && Self.finite(ribbonParams)
    }
    private static func finite(_ value: SIMD4<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
    }
    init(particle: RenderParticle) {
        positionSize = SIMD4(particle.position,particle.size)
        rotation = SIMD4(particle.rotation,Float(particle.shape.rawValue),particle.textureVOffset,particle.textureVScale)
        color = particle.color; uvRect = particle.uvRect
        axisStretch = SIMD4(particle.alignmentAxis,particle.stretch)
        ribbonColor = particle.endColor
        ribbonParams = SIMD4(particle.startSize,particle.endSize,0,0)
    }
}
