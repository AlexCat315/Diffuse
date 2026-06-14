import RHIWGPU
import SceneRuntime
import SIMDCompat

/// GPU mirror of `RenderParticle`. `position_size` packs world position (xyz) and
/// size (w); layout matches `ParticleInstance` in `particles.wgsl` (two vec4s).
private struct GPUParticleInstance {
    var positionSize: SIMD4<Float>
    var color: SIMD4<Float>
}

/// Per-frame billboard uniforms; layout matches `ParticleUniforms` in the shader.
private struct ParticleUniforms {
    var viewProj: simd_float4x4
    var cameraRight: SIMD4<Float>
    var cameraUp: SIMD4<Float>
}

extension WGPURenderer {
    func ensureParticlePipeline(hdr: Bool) throws -> GPURenderPipeline {
        if hdr, let particlePipelineHDR { return particlePipelineHDR }
        if !hdr, let particlePipelineLDR { return particlePipelineLDR }
        guard backend.rawDevice != nil else {
            throw WGPUBackendError.initFailed("device not ready")
        }

        let module = try backend.createShaderModule(
            wgsl: try Self.loadShaderSource(named: "particles"),
            label: "particles"
        )

        // No explicit layout: the bind group layout is reflected from the WGSL
        // (uniform at binding 0, read-only storage at binding 1).
        let pipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                pipelineLayout: nil,
                colorFormat: hdr ? hdrFormat : format,
                cullMode: .none,
                blend: .alphaBlending,
                depthStencil: GPUDepthStencilPipelineState(
                    format: depthFormat,
                    depthWriteEnabled: false,
                    depthCompare: .lessEqual
                )
            )
        )

        if hdr { particlePipelineHDR = pipeline } else { particlePipelineLDR = pipeline }
        return pipeline
    }

    /// Draws all `scene.particles` as one instanced billboard batch. Particles
    /// are already world-space and back-to-front sorted by the extractor, so the
    /// pass loads the existing color + depth (test only, no depth write) and
    /// alpha-composites on top.
    func encodeParticlePass(
        encoder: GPUCommandEncoder,
        colorView: GPUTextureView,
        depthView: GPUTextureView,
        pipeline: GPURenderPipeline,
        scene: RenderScene,
        viewProj: simd_float4x4
    ) throws -> Int {
        let particles = scene.particles
        guard !particles.isEmpty else { return 0 }

        // Camera basis for screen-aligned billboards.
        let forward = simd_normalize(scene.camera.target - scene.camera.eye)
        var right = simd_cross(forward, scene.camera.up)
        let rightLength = simd_length(right)
        right = rightLength > 1e-5 ? right / rightLength : SIMD3<Float>(1, 0, 0)
        let up = simd_cross(right, forward)

        var instances = [GPUParticleInstance]()
        instances.reserveCapacity(particles.count)
        for particle in particles {
            instances.append(
                GPUParticleInstance(
                    positionSize: SIMD4<Float>(particle.position, particle.size),
                    color: particle.color
                )
            )
        }

        try ensureParticleStorageCapacity(count: instances.count)
        guard let particleStorageBuffer else { return 0 }
        let instanceStride = MemoryLayout<GPUParticleInstance>.stride
        instances.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(particleStorageBuffer, data: base, size: raw.count)
            }
        }

        let uniformStride = UInt64(MemoryLayout<ParticleUniforms>.stride)
        if particleUniformBuffer == nil {
            particleUniformBuffer = try backend.createBuffer(size: uniformStride, usage: [.uniform, .copyDst])
        }
        guard let particleUniformBuffer else { return 0 }
        var uniforms = ParticleUniforms(
            viewProj: viewProj,
            cameraRight: SIMD4<Float>(right, 0),
            cameraUp: SIMD4<Float>(up, 0)
        )
        writeUniform(&uniforms, buffer: particleUniformBuffer)

        let bindGroup = try makeBindGroup(
            pipeline: pipeline,
            entries: [
                GPUBindGroupEntry(binding: 0, buffer: particleUniformBuffer, offset: 0, size: uniformStride),
                GPUBindGroupEntry(binding: 1, buffer: particleStorageBuffer, offset: 0,
                                  size: UInt64(instances.count * instanceStride))
            ]
        )

        let pass = try encoder.beginRenderPass(
            colorView: colorView,
            loadOp: .load,
            storeOp: .store,
            clearColor: .clear,
            depthView: depthView,
            depthLoadOp: .load,
            depthStoreOp: .store,
            depthClearValue: 1.0
        )
        applyUsedRegion(pass)
        pass.setPipeline(pipeline)
        pass.setBindGroup(bindGroup, index: 0)
        pass.draw(vertexCount: 6, instanceCount: UInt32(instances.count))
        pass.end()
        return 1
    }

    /// Grows the particle storage buffer (doubling, min 256) when more particles
    /// arrive than it can hold. Never shrinks.
    private func ensureParticleStorageCapacity(count: Int) throws {
        guard count > particleStorageCapacity || particleStorageBuffer == nil else { return }
        let newCapacity = max(count, max(particleStorageCapacity * 2, 256))
        particleStorageBuffer = try backend.createBuffer(
            size: UInt64(newCapacity * MemoryLayout<GPUParticleInstance>.stride),
            usage: [.storage, .copyDst]
        )
        particleStorageCapacity = newCapacity
    }
}
