import AssetPipeline
import Foundation
import Logging
import RHIWGPU
import SceneRuntime
import SIMDCompat

/// GPU mirror of `RenderParticle`. `position_size` packs world position (xyz) and
/// size (w); layout matches `ParticleInstance` in `particles.wgsl`.
private struct GPUParticleInstance {
    var positionSize: SIMD4<Float>
    var rotation: SIMD4<Float>
    var color: SIMD4<Float>
    var uvRect: SIMD4<Float>
    var axisStretch: SIMD4<Float>
}

/// Per-frame billboard uniforms; layout matches `ParticleUniforms` in the shader.
private struct ParticleUniforms {
    var viewProj: simd_float4x4
    var cameraRight: SIMD4<Float>
    var cameraUp: SIMD4<Float>
    var cameraForward: SIMD4<Float>
}

/// Layout matches `ParticleSimUniforms` in `particle_simulate.wgsl`.
private struct GPUParticleSimulationUniforms {
    /// x: delta time, y: particle count, z: elapsed time.
    var time: SIMD4<Float>
    /// xyz: acceleration.
    var gravity: SIMD4<Float>
    /// xyz: vector-field bias direction, w: strength.
    var vectorFieldDirectionStrength: SIMD4<Float>
    /// x: scale, y: scroll speed.
    var vectorFieldParams: SIMD4<Float>
}

/// Layout matches `ParticleSimToInstanceUniforms` in `particle_sim_to_instance.wgsl`.
private struct GPUParticleSimulationInstanceUniforms {
    var worldTransform: simd_float4x4
    /// x: particle count, y: base render instance.
    var params: SIMD4<Float>
    var uvRect: SIMD4<Float>
}

/// Layout matches `ParticleSimState` in `particle_simulate.wgsl`.
private struct GPUParticleSimulationState {
    var positionLifetime: SIMD4<Float>
    var velocityAge: SIMD4<Float>
    var sizeRotation: SIMD4<Float>
    var color: SIMD4<Float>
}

extension WGPURenderer {
    func ensureParticlePipeline(hdr: Bool,
                                blendMode: ParticleBlendMode = .alpha) throws -> GPURenderPipeline {
        switch blendMode {
        case .alpha:
            if hdr, let particlePipelineHDR { return particlePipelineHDR }
            if !hdr, let particlePipelineLDR { return particlePipelineLDR }
        case .additive:
            if hdr, let additiveParticlePipelineHDR { return additiveParticlePipelineHDR }
            if !hdr, let additiveParticlePipelineLDR { return additiveParticlePipelineLDR }
        }
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
                blend: blendMode == .additive ? .additiveBlending : .alphaBlending,
                depthStencil: GPUDepthStencilPipelineState(
                    format: depthFormat,
                    depthWriteEnabled: false,
                    depthCompare: .lessEqual
                )
            )
        )

        switch blendMode {
        case .alpha:
            if hdr { particlePipelineHDR = pipeline } else { particlePipelineLDR = pipeline }
        case .additive:
            if hdr { additiveParticlePipelineHDR = pipeline } else { additiveParticlePipelineLDR = pipeline }
        }
        return pipeline
    }

    func ensureParticleSimulationResources(for plan: ParticleGPUSimulationPlan) throws
        -> GPUParticleSimulationResources? {
        guard plan.usesGPU else { return nil }
        guard backend.rawDevice != nil else {
            throw WGPUBackendError.initFailed("device not ready")
        }

        let capacity = max(1, plan.particleCapacity)
        let workgroupSize = min(
            max(1, plan.workgroupSize),
            ParticleGPUSimulationPlan.maximumWorkgroupSize
        )
        if let resources = particleSimulationResources,
           resources.capacity >= capacity,
           resources.workgroupSize == workgroupSize {
            return resources
        }

        let bindGroupLayout = try backend.createBindGroupLayout(entries: [
            GPUBindGroupLayoutEntry(binding: 0,
                                    visibility: .compute,
                                    type: .uniformBuffer),
            GPUBindGroupLayoutEntry(binding: 1,
                                    visibility: .compute,
                                    type: .storageBuffer),
        ])
        let pipelineLayout = try backend.createPipelineLayout(bindGroupLayouts: [bindGroupLayout])
        let shaderSource = try Self
            .loadComputeShaderSource(named: "particle_simulate")
            .replacingOccurrences(
                of: "@workgroup_size(64)",
                with: "@workgroup_size(\(workgroupSize))"
            )
        let module = try backend.createShaderModule(wgsl: shaderSource,
                                                    label: "particle_simulate")
        let pipeline = try backend.createComputePipeline(shaderModule: module,
                                                        entryPoint: "main",
                                                        layout: pipelineLayout)
        let instanceBindGroupLayout = try backend.createBindGroupLayout(entries: [
            GPUBindGroupLayoutEntry(binding: 0,
                                    visibility: .compute,
                                    type: .uniformBuffer),
            GPUBindGroupLayoutEntry(binding: 1,
                                    visibility: .compute,
                                    type: .readOnlyStorageBuffer),
            GPUBindGroupLayoutEntry(binding: 2,
                                    visibility: .compute,
                                    type: .storageBuffer),
        ])
        let instancePipelineLayout = try backend.createPipelineLayout(bindGroupLayouts: [instanceBindGroupLayout])
        let instanceShaderSource = try Self
            .loadComputeShaderSource(named: "particle_sim_to_instance")
            .replacingOccurrences(
                of: "@workgroup_size(64)",
                with: "@workgroup_size(\(workgroupSize))"
            )
        let instanceModule = try backend.createShaderModule(wgsl: instanceShaderSource,
                                                            label: "particle_sim_to_instance")
        let instancePipeline = try backend.createComputePipeline(shaderModule: instanceModule,
                                                                entryPoint: "main",
                                                                layout: instancePipelineLayout)
        let uniformSize = UInt64(MemoryLayout<GPUParticleSimulationUniforms>.stride)
        let instanceUniformSize = UInt64(MemoryLayout<GPUParticleSimulationInstanceUniforms>.stride)
        let stateStride = UInt64(MemoryLayout<GPUParticleSimulationState>.stride)
        let uniformBuffer = try backend.createBuffer(size: uniformSize,
                                                     usage: [.uniform, .copyDst])
        let instanceUniformBuffer = try backend.createBuffer(size: instanceUniformSize,
                                                             usage: [.uniform, .copyDst])
        let stateBuffer = try backend.createBuffer(size: UInt64(capacity) * stateStride,
                                                   usage: [.storage, .copyDst, .copySrc])
        let bindGroup = try backend.createBindGroup(
            layout: bindGroupLayout,
            entries: [
                GPUBindGroupEntry(binding: 0,
                                  buffer: uniformBuffer,
                                  offset: 0,
                                  size: uniformSize),
                GPUBindGroupEntry(binding: 1,
                                  buffer: stateBuffer,
                                  offset: 0,
                                  size: UInt64(capacity) * stateStride),
            ]
        )
        let resources = GPUParticleSimulationResources(bindGroupLayout: bindGroupLayout,
                                                       pipelineLayout: pipelineLayout,
                                                       pipeline: pipeline,
                                                       uniformBuffer: uniformBuffer,
                                                       stateBuffer: stateBuffer,
                                                       bindGroup: bindGroup,
                                                       instanceBindGroupLayout: instanceBindGroupLayout,
                                                       instancePipelineLayout: instancePipelineLayout,
                                                       instancePipeline: instancePipeline,
                                                       instanceUniformBuffer: instanceUniformBuffer,
                                                       capacity: capacity,
                                                       workgroupSize: workgroupSize)
        particleSimulationResources = resources
        return resources
    }

    @discardableResult
    func encodeParticleSimulationPass(encoder: GPUCommandEncoder,
                                      plan: ParticleGPUSimulationPlan,
                                      particles: [Particle],
                                      deltaTime: Float,
                                      gravity: SIMD3<Float>,
                                      vectorFieldDirection: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                                      vectorFieldStrength: Float = 0,
                                      vectorFieldScale: Float = 1,
                                      vectorFieldScrollSpeed: Float = 0,
                                      elapsedTime: Float = 0) throws -> GPUParticleSimulationResources? {
        guard let resources = try ensureParticleSimulationResources(for: plan) else { return nil }
        let count = min(particles.count, resources.capacity, max(0, plan.particleCapacity))
        guard count > 0 else { return resources }

        var states = [GPUParticleSimulationState]()
        states.reserveCapacity(count)
        for particle in particles.prefix(count) {
            states.append(
                GPUParticleSimulationState(
                    positionLifetime: SIMD4<Float>(particle.position, particle.lifetime),
                    velocityAge: SIMD4<Float>(particle.velocity, particle.age),
                    sizeRotation: SIMD4<Float>(
                        particle.size,
                        particle.rotation,
                        particle.angularVelocity,
                        particle.sizeScale
                    ),
                    color: particle.color
                )
            )
        }
        states.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(resources.stateBuffer, data: base, size: raw.count)
            }
        }

        var uniforms = GPUParticleSimulationUniforms(
            time: SIMD4<Float>(
                max(0, deltaTime),
                Float(count),
                max(0, elapsedTime),
                0
            ),
            gravity: SIMD4<Float>(gravity, 0),
            vectorFieldDirectionStrength: SIMD4<Float>(
                vectorFieldDirection,
                max(0, vectorFieldStrength)
            ),
            vectorFieldParams: SIMD4<Float>(
                max(0.0001, vectorFieldScale),
                vectorFieldScrollSpeed,
                0,
                0
            )
        )
        writeUniform(&uniforms, buffer: resources.uniformBuffer)

        let pass = try encoder.beginComputePass()
        pass.setPipeline(resources.pipeline)
        pass.setBindGroup(resources.bindGroup, index: 0)
        let groups = UInt32(max(1, Int(ceil(Float(count) / Float(resources.workgroupSize)))))
        pass.dispatch(x: groups)
        pass.end()
        return resources
    }

    func encodeParticleSimulationPrePass(
        encoder: GPUCommandEncoder,
        scene: RenderScene,
        deltaTime: Float,
        elapsedTime: Float
    ) throws -> GPUParticleSimulationEncodeReport {
        var report = GPUParticleSimulationEncodeReport()
        gpuParticleRenderBatches.removeAll(keepingCapacity: true)
        gpuParticleRenderInstanceCount = 0
        for batch in scene.particleSimulationBatches {
            let particleCount = min(batch.particles.count,
                                    max(0, batch.plan.particleCapacity))
            guard particleCount > 0 else { continue }
            let resources = try encodeParticleSimulationPass(
                encoder: encoder,
                plan: batch.plan,
                particles: batch.particles,
                deltaTime: deltaTime,
                gravity: batch.gravity,
                vectorFieldDirection: batch.vectorFieldDirection,
                vectorFieldStrength: batch.vectorFieldStrength,
                vectorFieldScale: batch.vectorFieldScale,
                vectorFieldScrollSpeed: batch.vectorFieldScrollSpeed,
                elapsedTime: elapsedTime
            )
            guard resources != nil else { continue }
            let workgroupSize = min(
                max(1, batch.plan.workgroupSize),
                ParticleGPUSimulationPlan.maximumWorkgroupSize
            )
            let dispatchGroups = Int(ceil(Float(particleCount) / Float(workgroupSize)))
            let renderedInstances: Int
            if batch.renderOnGPU, let resources {
                renderedInstances = try encodeParticleSimulationInstancePass(
                    encoder: encoder,
                    resources: resources,
                    batch: batch,
                    particleCount: particleCount,
                    workgroupSize: workgroupSize
                )
            } else {
                renderedInstances = 0
            }
            report.include(batchParticleCount: particleCount,
                           dispatchWorkgroups: dispatchGroups,
                           renderInstanceCount: renderedInstances)
        }
        return report
    }

    private func encodeParticleSimulationInstancePass(
        encoder: GPUCommandEncoder,
        resources: GPUParticleSimulationResources,
        batch: RenderParticleSimulationBatch,
        particleCount: Int,
        workgroupSize: Int
    ) throws -> Int {
        guard particleCount > 0 else { return 0 }
        let baseInstance = gpuParticleRenderInstanceCount
        let requiredInstanceCount = baseInstance + particleCount
        try ensureParticleStorageCapacity(count: requiredInstanceCount)
        guard let particleStorageBuffer else { return 0 }

        var uniforms = GPUParticleSimulationInstanceUniforms(
            worldTransform: batch.worldTransform,
            params: SIMD4<Float>(Float(particleCount), Float(baseInstance), 0, 0),
            uvRect: batch.uvRect
        )
        writeUniform(&uniforms, buffer: resources.instanceUniformBuffer)

        let stateStride = UInt64(MemoryLayout<GPUParticleSimulationState>.stride)
        let instanceStride = UInt64(MemoryLayout<GPUParticleInstance>.stride)
        let bindGroup = try backend.createBindGroup(
            layout: resources.instanceBindGroupLayout,
            entries: [
                GPUBindGroupEntry(
                    binding: 0,
                    buffer: resources.instanceUniformBuffer,
                    offset: 0,
                    size: UInt64(MemoryLayout<GPUParticleSimulationInstanceUniforms>.stride)
                ),
                GPUBindGroupEntry(
                    binding: 1,
                    buffer: resources.stateBuffer,
                    offset: 0,
                    size: UInt64(particleCount) * stateStride
                ),
                GPUBindGroupEntry(
                    binding: 2,
                    buffer: particleStorageBuffer,
                    offset: 0,
                    size: UInt64(requiredInstanceCount) * instanceStride
                ),
            ]
        )
        let pass = try encoder.beginComputePass()
        pass.setPipeline(resources.instancePipeline)
        pass.setBindGroup(bindGroup, index: 0)
        let groups = UInt32(max(1, Int(ceil(Float(particleCount) / Float(workgroupSize)))))
        pass.dispatch(x: groups)
        pass.end()

        gpuParticleRenderBatches.append(
            ParticleRenderBatch(
                key: ParticleRenderBatchKey(blendMode: batch.blendMode,
                                            texturePath: batch.texturePath),
                start: baseInstance,
                count: particleCount
            )
        )
        gpuParticleRenderInstanceCount = requiredInstanceCount
        return particleCount
    }

    /// Draws `scene.particles` as contiguous instanced billboard batches.
    /// Particles are already world-space and back-to-front sorted by the extractor;
    /// batching must preserve that order so alpha compositing remains correct.
    func encodeParticlePass(
        encoder: GPUCommandEncoder,
        colorView: GPUTextureView,
        depthView: GPUTextureView,
        pipeline: GPURenderPipeline,
        scene: RenderScene,
        viewProj: simd_float4x4,
        hdr: Bool
    ) throws -> Int {
        guard !scene.particles.isEmpty || gpuParticleRenderInstanceCount > 0 else { return 0 }

        // Camera basis for screen-aligned billboards.
        let forward = simd_normalize(scene.camera.target - scene.camera.eye)
        var right = simd_cross(forward, scene.camera.up)
        let rightLength = simd_length(right)
        right = rightLength > 1e-5 ? right / rightLength : SIMD3<Float>(1, 0, 0)
        let up = simd_cross(right, forward)

        let renderBatches: [ParticleRenderBatch]
        let storageSize: UInt64
        if scene.particles.isEmpty {
            guard let particleStorageBuffer else { return 0 }
            _ = particleStorageBuffer
            renderBatches = gpuParticleRenderBatches
            storageSize = UInt64(gpuParticleRenderInstanceCount * MemoryLayout<GPUParticleInstance>.stride)
        } else {
            var instances = [GPUParticleInstance]()
            instances.reserveCapacity(scene.particles.count)
            for particle in scene.particles {
                instances.append(
                    GPUParticleInstance(
                        positionSize: SIMD4<Float>(particle.position, particle.size),
                        rotation: SIMD4<Float>(particle.rotation, 0, 0, 0),
                        color: particle.color,
                        uvRect: particle.uvRect,
                        axisStretch: SIMD4<Float>(particle.alignmentAxis, particle.stretch)
                    )
                )
            }
            renderBatches = ParticleRenderBatchPlan(particles: scene.particles).batches

            try ensureParticleStorageCapacity(count: instances.count)
            guard let particleStorageBuffer else { return 0 }
            instances.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    backend.writeBuffer(particleStorageBuffer, data: base, size: raw.count)
                }
            }
            storageSize = UInt64(instances.count * MemoryLayout<GPUParticleInstance>.stride)
        }
        guard !renderBatches.isEmpty else { return 0 }
        guard let particleStorageBuffer else { return 0 }

        let uniformStride = UInt64(MemoryLayout<ParticleUniforms>.stride)
        if particleUniformBuffer == nil {
            particleUniformBuffer = try backend.createBuffer(size: uniformStride, usage: [.uniform, .copyDst])
        }
        guard let particleUniformBuffer else { return 0 }
        var uniforms = ParticleUniforms(
            viewProj: viewProj,
            cameraRight: SIMD4<Float>(right, 0),
            cameraUp: SIMD4<Float>(up, 0),
            cameraForward: SIMD4<Float>(forward, 0)
        )
        writeUniform(&uniforms, buffer: particleUniformBuffer)

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
        for batch in renderBatches {
            let modePipeline = batch.key.blendMode == .alpha ? pipeline : try ensureParticlePipeline(
                hdr: hdr,
                blendMode: batch.key.blendMode
            )
            let textureView = try particleTextureView(for: batch.key.texturePath)
            let sampler = try particleSampler()
            let bindGroup = try makeBindGroup(
                pipeline: modePipeline,
                entries: [
                    GPUBindGroupEntry(binding: 0, buffer: particleUniformBuffer, offset: 0, size: uniformStride),
                    GPUBindGroupEntry(binding: 1, buffer: particleStorageBuffer, offset: 0, size: storageSize),
                    GPUBindGroupEntry(binding: 2, sampler: sampler),
                    GPUBindGroupEntry(binding: 3, textureView: textureView)
                ]
            )
            pass.setPipeline(modePipeline)
            pass.setBindGroup(bindGroup, index: 0)
            pass.draw(vertexCount: 6,
                      instanceCount: UInt32(batch.count),
                      firstInstance: UInt32(batch.start))
        }
        pass.end()
        return renderBatches.count
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

    private func particleSampler() throws -> GPUSampler {
        if let linearSampler {
            return linearSampler
        }
        linearSampler = try backend.createSampler(
            desc: GPUSamplerDescriptor(
                addressModeU: .clampToEdge,
                addressModeV: .clampToEdge,
                magFilter: .linear,
                minFilter: .linear,
                mipmapFilter: .nearest
            )
        )
        return linearSampler!
    }

    private func particleTextureView(for path: String?) throws -> GPUTextureView {
        guard let path else {
            return try ensureFallbackParticleTextureView()
        }
        if let resource = particleTextureResources[path] {
            return resource.view
        }
        do {
            let decoded = try ImageAssetDecoder.decodeRGBA8(path: path)
            let textureWidth = UInt32(decoded.width)
            let textureHeight = UInt32(decoded.height)
            let gpuTexture = try backend.createTexture(
                width: textureWidth,
                height: textureHeight,
                format: .rgba8Unorm,
                usage: [.textureBinding, .copyDst]
            )
            decoded.pixels.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    backend.writeTexture(
                        gpuTexture,
                        data: base,
                        dataSize: raw.count,
                        bytesPerRow: textureWidth * 4,
                        rowsPerImage: textureHeight,
                        width: textureWidth,
                        height: textureHeight
                    )
                }
            }
            let resource = GPUParticleTextureResource(
                texture: gpuTexture,
                view: try gpuTexture.createView(),
                width: textureWidth,
                height: textureHeight,
                sourcePath: path
            )
            particleTextureResources[path] = resource
            particleTextureFailures.remove(path)
            Logger.renderer.debug(
                "uploaded particle texture: size=\(textureWidth)x\(textureHeight) source=\(path)"
            )
            return resource.view
        } catch {
            if !particleTextureFailures.contains(path) {
                particleTextureFailures.insert(path)
                Logger.renderer.warning(
                    "particle texture decode failed: source=\(path) reason=\(String(describing: error))"
                )
            }
            return try ensureFallbackParticleTextureView()
        }
    }

    private func ensureFallbackParticleTextureView() throws -> GPUTextureView {
        if let fallbackParticleTextureView {
            return fallbackParticleTextureView
        }
        let texture = try backend.createTexture(
            width: 1,
            height: 1,
            format: .rgba8Unorm,
            usage: [.textureBinding, .copyDst]
        )
        let pixel: [UInt8] = [255, 255, 255, 255]
        pixel.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeTexture(
                    texture,
                    data: base,
                    dataSize: raw.count,
                    bytesPerRow: 4,
                    rowsPerImage: 1,
                    width: 1,
                    height: 1
                )
            }
        }
        fallbackParticleTexture = texture
        fallbackParticleTextureView = try texture.createView()
        return fallbackParticleTextureView!
    }
}
