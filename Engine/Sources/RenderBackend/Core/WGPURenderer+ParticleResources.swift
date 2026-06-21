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

/// Non-indexed indirect draw arguments. Layout matches WebGPU's
/// DrawIndirectArgs: vertexCount, instanceCount, firstVertex, firstInstance.
private struct GPUParticleIndirectDrawArgs {
    var vertexCount: UInt32
    var instanceCount: UInt32
    var firstVertex: UInt32
    var firstInstance: UInt32
}

/// Uniforms for GPU particle culling and compaction.
private struct GPUParticleCullUniforms {
    var viewProj: simd_float4x4
    /// x: batch count.
    var params: SIMD4<UInt32>
}

/// Per-render-batch source and destination ranges for GPU culling. The culling
/// shader preserves order inside each batch by compacting visible instances
/// into the range beginning at `outputStart`.
private struct GPUParticleCullBatch {
    var sourceStart: UInt32
    var sourceCount: UInt32
    var outputStart: UInt32
    var _padding: UInt32 = 0
}

private struct GPUParticleCullEncodeResult {
    var storageBuffer: GPUBuffer
    var storageSize: UInt64
    var dispatchWorkgroups: Int
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
    /// x: scale, y: scroll speed, z: field mode (0 none, 1 uniform, 2 curl).
    var vectorFieldParams: SIMD4<Float>
    /// xyz: force center, w: force radius. Radius 0 means unbounded.
    var forceCenterRadius: SIMD4<Float>
    /// xyz: force axis, w: force mode (0 none, 1 radial, 2 vortex).
    var forceAxisMode: SIMD4<Float>
    /// x: force strength, y: force falloff.
    var forceParams: SIMD4<Float>
}

/// Layout matches `ParticleSimToInstanceUniforms` in `particle_sim_to_instance.wgsl`.
private struct GPUParticleSimulationInstanceUniforms {
    var worldTransform: simd_float4x4
    /// x: particle count, y: base render instance.
    var params: SIMD4<Float>
    var uvRect: SIMD4<Float>
    /// x: columns, y: rows, z: frame count, w: frame rate.
    var textureSheet: SIMD4<Float>
    /// x: alignment mode (0 billboard, 1 velocity), y: velocity stretch scale, z: max stretch.
    var renderParams: SIMD4<Float>
}

/// Layout matches `ParticleSimState` in `particle_simulate.wgsl`.
private struct GPUParticleSimulationState {
    var positionLifetime: SIMD4<Float>
    var velocityAge: SIMD4<Float>
    var sizeRotation: SIMD4<Float>
    var color: SIMD4<Float>
}

extension WGPURenderer {
    private func gpuVectorFieldMode(_ mode: ParticleVectorFieldMode) -> Float {
        switch mode {
        case .none:
            return 0
        case .uniform:
            return 1
        case .curl:
            return 2
        }
    }

    private func gpuForceMode(_ mode: ParticleForceMode) -> Float {
        switch mode {
        case .none:
            return 0
        case .radial:
            return 1
        case .vortex:
            return 2
        }
    }

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

    func ensureParticleSimulationResources(for plan: ParticleGPUSimulationPlan,
                                           slot: Int = 0) throws
        -> GPUParticleSimulationResources? {
        guard plan.usesGPU else { return nil }
        guard backend.rawDevice != nil else {
            throw WGPUBackendError.initFailed("device not ready")
        }
        let slot = max(0, slot)

        let capacity = max(1, plan.particleCapacity)
        let workgroupSize = min(
            max(1, plan.workgroupSize),
            ParticleGPUSimulationPlan.maximumWorkgroupSize
        )
        if particleSimulationResources.count <= slot {
            particleSimulationResources.append(
                contentsOf: repeatElement(nil, count: slot - particleSimulationResources.count + 1)
            )
        }
        if let resources = particleSimulationResources[slot],
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
        particleSimulationResources[slot] = resources
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
                                      vectorFieldMode: ParticleVectorFieldMode = .none,
                                      forceMode: ParticleForceMode = .none,
                                      forceCenter: SIMD3<Float> = .zero,
                                      forceAxis: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                                      forceRadius: Float = 0,
                                      forceStrength: Float = 0,
                                      forceFalloff: Float = 1,
                                      elapsedTime: Float = 0,
                                      slot: Int = 0) throws -> GPUParticleSimulationResources? {
        guard let resources = try ensureParticleSimulationResources(for: plan, slot: slot) else { return nil }
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
                gpuVectorFieldMode(vectorFieldMode),
                0
            ),
            forceCenterRadius: SIMD4<Float>(
                forceCenter,
                max(0, forceRadius)
            ),
            forceAxisMode: SIMD4<Float>(
                forceAxis,
                gpuForceMode(forceMode)
            ),
            forceParams: SIMD4<Float>(
                forceStrength,
                max(0, forceFalloff),
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
        elapsedTime: Float,
        additionalRenderInstanceCapacity: Int = 0
    ) throws -> GPUParticleSimulationEncodeReport {
        var report = GPUParticleSimulationEncodeReport()
        gpuParticleRenderBatches.removeAll(keepingCapacity: true)
        gpuParticleRenderInstanceCount = 0
        for (slot, batch) in scene.particleSimulationBatches.enumerated() {
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
                vectorFieldMode: batch.vectorFieldMode,
                forceMode: batch.forceMode,
                forceCenter: batch.forceCenter,
                forceAxis: batch.forceAxis,
                forceRadius: batch.forceRadius,
                forceStrength: batch.forceStrength,
                forceFalloff: batch.forceFalloff,
                elapsedTime: elapsedTime,
                slot: slot
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
                    workgroupSize: workgroupSize,
                    reservedTrailingInstances: additionalRenderInstanceCapacity
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
        workgroupSize: Int,
        reservedTrailingInstances: Int = 0
    ) throws -> Int {
        guard particleCount > 0 else { return 0 }
        let baseInstance = gpuParticleRenderInstanceCount
        let requiredInstanceCount = baseInstance + particleCount
        let reservedInstanceCount = requiredInstanceCount + max(0, reservedTrailingInstances)
        try ensureParticleStorageCapacity(count: reservedInstanceCount)
        guard let particleStorageBuffer else { return 0 }

        var uniforms = GPUParticleSimulationInstanceUniforms(
            worldTransform: batch.worldTransform,
            params: SIMD4<Float>(Float(particleCount), Float(baseInstance), 0, 0),
            uvRect: batch.uvRect,
            textureSheet: SIMD4<Float>(
                Float(batch.textureSheetColumns),
                Float(batch.textureSheetRows),
                Float(batch.textureSheetFrameCount),
                batch.textureSheetFrameRate
            ),
            renderParams: SIMD4<Float>(
                batch.renderAlignment == .velocity ? 1 : 0,
                batch.velocityStretchScale,
                batch.velocityStretchMax,
                0
            )
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
        particleIndirectDrawCount = 0
        guard !scene.particles.isEmpty || gpuParticleRenderInstanceCount > 0 else { return 0 }

        // Camera basis for screen-aligned billboards.
        let forward = simd_normalize(scene.camera.target - scene.camera.eye)
        var right = simd_cross(forward, scene.camera.up)
        let rightLength = simd_length(right)
        right = rightLength > 1e-5 ? right / rightLength : SIMD3<Float>(1, 0, 0)
        let up = simd_cross(right, forward)

        var renderBatches: [ParticleRenderBatch]
        let sourceInstanceCount: Int
        if scene.particles.isEmpty {
            guard let particleStorageBuffer else { return 0 }
            _ = particleStorageBuffer
            renderBatches = gpuParticleRenderBatches
            sourceInstanceCount = gpuParticleRenderInstanceCount
        } else {
            let cpuBaseInstance = gpuParticleRenderInstanceCount
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
            renderBatches = gpuParticleRenderBatches
            renderBatches.append(
                contentsOf: ParticleRenderBatchPlan(particles: scene.particles).batches.map { batch in
                    ParticleRenderBatch(
                        key: batch.key,
                        start: cpuBaseInstance + batch.start,
                        count: batch.count
                    )
                }
            )

            let totalInstanceCount = cpuBaseInstance + instances.count
            try ensureParticleStorageCapacity(count: totalInstanceCount)
            guard let particleStorageBuffer else { return 0 }
            instances.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    backend.writeBuffer(
                        particleStorageBuffer,
                        data: base,
                        size: raw.count,
                        offset: UInt64(cpuBaseInstance * MemoryLayout<GPUParticleInstance>.stride)
                    )
                }
            }
            sourceInstanceCount = totalInstanceCount
        }
        guard !renderBatches.isEmpty else { return 0 }
        guard let particleStorageBuffer else { return 0 }
        let cullResult = try encodeParticleCullPass(
            encoder: encoder,
            sourceBuffer: particleStorageBuffer,
            sourceInstanceCount: sourceInstanceCount,
            batches: renderBatches,
            viewProj: viewProj
        )
        let renderInstanceBuffer = cullResult.storageBuffer
        let storageSize = cullResult.storageSize
        guard let particleIndirectDrawBuffer else { return 0 }

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
        for (index, batch) in renderBatches.enumerated() {
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
                    GPUBindGroupEntry(binding: 1, buffer: renderInstanceBuffer, offset: 0, size: storageSize),
                    GPUBindGroupEntry(binding: 2, sampler: sampler),
                    GPUBindGroupEntry(binding: 3, textureView: textureView)
                ]
            )
            pass.setPipeline(modePipeline)
            pass.setBindGroup(bindGroup, index: 0)
            pass.drawIndirect(
                buffer: particleIndirectDrawBuffer,
                offset: UInt64(index * MemoryLayout<GPUParticleIndirectDrawArgs>.stride)
            )
        }
        pass.end()
        particleIndirectDrawCount = renderBatches.count
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

    private func ensureParticleCullResources() throws {
        if particleCullPipeline != nil,
           particleCullBindGroupLayout != nil,
           particleCullUniformBuffer != nil {
            return
        }
        guard backend.rawDevice != nil else {
            throw WGPUBackendError.initFailed("device not ready")
        }

        let bindGroupLayout = try backend.createBindGroupLayout(entries: [
            GPUBindGroupLayoutEntry(binding: 0,
                                    visibility: .compute,
                                    type: .uniformBuffer),
            GPUBindGroupLayoutEntry(binding: 1,
                                    visibility: .compute,
                                    type: .readOnlyStorageBuffer),
            GPUBindGroupLayoutEntry(binding: 2,
                                    visibility: .compute,
                                    type: .readOnlyStorageBuffer),
            GPUBindGroupLayoutEntry(binding: 3,
                                    visibility: .compute,
                                    type: .storageBuffer),
            GPUBindGroupLayoutEntry(binding: 4,
                                    visibility: .compute,
                                    type: .storageBuffer),
        ])
        let pipelineLayout = try backend.createPipelineLayout(bindGroupLayouts: [bindGroupLayout])
        let shaderSource = try Self.loadComputeShaderSource(named: "particle_cull_compact")
        let module = try backend.createShaderModule(wgsl: shaderSource,
                                                    label: "particle_cull_compact")
        let pipeline = try backend.createComputePipeline(shaderModule: module,
                                                        entryPoint: "main",
                                                        layout: pipelineLayout)
        let uniformBuffer = try backend.createBuffer(
            size: UInt64(MemoryLayout<GPUParticleCullUniforms>.stride),
            usage: [.uniform, .copyDst]
        )
        particleCullBindGroupLayout = bindGroupLayout
        particleCullPipelineLayout = pipelineLayout
        particleCullPipeline = pipeline
        particleCullUniformBuffer = uniformBuffer
    }

    private func encodeParticleCullPass(
        encoder: GPUCommandEncoder,
        sourceBuffer: GPUBuffer,
        sourceInstanceCount: Int,
        batches: [ParticleRenderBatch],
        viewProj: simd_float4x4
    ) throws -> GPUParticleCullEncodeResult {
        guard sourceInstanceCount > 0, !batches.isEmpty else {
            return GPUParticleCullEncodeResult(storageBuffer: sourceBuffer,
                                               storageSize: 0,
                                               dispatchWorkgroups: 0)
        }
        try ensureParticleCullResources()
        try ensureParticleVisibleStorageCapacity(count: sourceInstanceCount)
        try ensureParticleCullBatchCapacity(count: batches.count)
        try ensureParticleIndirectDrawCapacity(count: batches.count)
        guard let particleCullPipeline,
              let particleCullBindGroupLayout,
              let particleCullUniformBuffer,
              let particleCullBatchBuffer,
              let particleVisibleStorageBuffer,
              let particleIndirectDrawBuffer
        else {
            return GPUParticleCullEncodeResult(storageBuffer: sourceBuffer,
                                               storageSize: UInt64(sourceInstanceCount * MemoryLayout<GPUParticleInstance>.stride),
                                               dispatchWorkgroups: 0)
        }

        var uniforms = GPUParticleCullUniforms(
            viewProj: viewProj,
            params: SIMD4<UInt32>(UInt32(batches.count), 0, 0, 0)
        )
        writeUniform(&uniforms, buffer: particleCullUniformBuffer)

        var batchDescriptors = [GPUParticleCullBatch]()
        batchDescriptors.reserveCapacity(batches.count)
        for batch in batches {
            batchDescriptors.append(
                GPUParticleCullBatch(
                    sourceStart: UInt32(batch.start),
                    sourceCount: UInt32(batch.count),
                    outputStart: UInt32(batch.start)
                )
            )
        }
        batchDescriptors.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(particleCullBatchBuffer, data: base, size: raw.count)
            }
        }

        let instanceStride = UInt64(MemoryLayout<GPUParticleInstance>.stride)
        let batchStride = UInt64(MemoryLayout<GPUParticleCullBatch>.stride)
        let drawStride = UInt64(MemoryLayout<GPUParticleIndirectDrawArgs>.stride)
        let bindGroup = try backend.createBindGroup(
            layout: particleCullBindGroupLayout,
            entries: [
                GPUBindGroupEntry(
                    binding: 0,
                    buffer: particleCullUniformBuffer,
                    offset: 0,
                    size: UInt64(MemoryLayout<GPUParticleCullUniforms>.stride)
                ),
                GPUBindGroupEntry(
                    binding: 1,
                    buffer: sourceBuffer,
                    offset: 0,
                    size: UInt64(sourceInstanceCount) * instanceStride
                ),
                GPUBindGroupEntry(
                    binding: 2,
                    buffer: particleCullBatchBuffer,
                    offset: 0,
                    size: UInt64(batches.count) * batchStride
                ),
                GPUBindGroupEntry(
                    binding: 3,
                    buffer: particleVisibleStorageBuffer,
                    offset: 0,
                    size: UInt64(sourceInstanceCount) * instanceStride
                ),
                GPUBindGroupEntry(
                    binding: 4,
                    buffer: particleIndirectDrawBuffer,
                    offset: 0,
                    size: UInt64(batches.count) * drawStride
                ),
            ]
        )
        let pass = try encoder.beginComputePass()
        pass.setPipeline(particleCullPipeline)
        pass.setBindGroup(bindGroup, index: 0)
        let groups = UInt32(max(1, Int(ceil(Float(batches.count) / 64.0))))
        pass.dispatch(x: groups)
        pass.end()

        particleCullBatchCount = batches.count
        particleCullCandidateCount = sourceInstanceCount
        particleCullDispatchWorkgroups = Int(groups)
        return GPUParticleCullEncodeResult(
            storageBuffer: particleVisibleStorageBuffer,
            storageSize: UInt64(sourceInstanceCount) * instanceStride,
            dispatchWorkgroups: Int(groups)
        )
    }

    private func ensureParticleVisibleStorageCapacity(count: Int) throws {
        guard count > particleVisibleStorageCapacity || particleVisibleStorageBuffer == nil else { return }
        let newCapacity = max(count, max(particleVisibleStorageCapacity * 2, 256))
        particleVisibleStorageBuffer = try backend.createBuffer(
            size: UInt64(newCapacity * MemoryLayout<GPUParticleInstance>.stride),
            usage: [.storage, .copySrc]
        )
        particleVisibleStorageCapacity = newCapacity
    }

    private func ensureParticleCullBatchCapacity(count: Int) throws {
        guard count > particleCullBatchCapacity || particleCullBatchBuffer == nil else { return }
        let newCapacity = max(count, max(particleCullBatchCapacity * 2, 64))
        particleCullBatchBuffer = try backend.createBuffer(
            size: UInt64(newCapacity * MemoryLayout<GPUParticleCullBatch>.stride),
            usage: [.storage, .copyDst]
        )
        particleCullBatchCapacity = newCapacity
    }

    private func ensureParticleIndirectDrawCapacity(count: Int) throws {
        guard count > particleIndirectDrawCapacity || particleIndirectDrawBuffer == nil else { return }
        let newCapacity = max(count, max(particleIndirectDrawCapacity * 2, 64))
        particleIndirectDrawBuffer = try backend.createBuffer(
            size: UInt64(newCapacity * MemoryLayout<GPUParticleIndirectDrawArgs>.stride),
            usage: [.indirect, .storage, .copySrc]
        )
        particleIndirectDrawCapacity = newCapacity
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
