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
}

/// Per-frame billboard uniforms; layout matches `ParticleUniforms` in the shader.
private struct ParticleUniforms {
    var viewProj: simd_float4x4
    var cameraRight: SIMD4<Float>
    var cameraUp: SIMD4<Float>
}

extension WGPURenderer {
    private struct ParticleBatchKey: Hashable {
        var blendMode: ParticleBlendMode
        var texturePath: String?
    }

    private struct ParticleBatch {
        var key: ParticleBatchKey
        var start: Int
        var count: Int
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
        viewProj: simd_float4x4,
        hdr: Bool
    ) throws -> Int {
        guard !scene.particles.isEmpty else { return 0 }

        // Camera basis for screen-aligned billboards.
        let forward = simd_normalize(scene.camera.target - scene.camera.eye)
        var right = simd_cross(forward, scene.camera.up)
        let rightLength = simd_length(right)
        right = rightLength > 1e-5 ? right / rightLength : SIMD3<Float>(1, 0, 0)
        let up = simd_cross(right, forward)

        var instances = [GPUParticleInstance]()
        var batches: [ParticleBatch] = []
        instances.reserveCapacity(scene.particles.count)
        let batchKeys = scene.particles.reduce(into: [ParticleBatchKey]()) { keys, particle in
            let key = ParticleBatchKey(blendMode: particle.blendMode,
                                       texturePath: normalizedParticleTexturePath(particle.texturePath))
            if !keys.contains(key) {
                keys.append(key)
            }
        }.sorted { lhs, rhs in
            if lhs.blendMode != rhs.blendMode {
                return lhs.blendMode.rawValue < rhs.blendMode.rawValue
            }
            return (lhs.texturePath ?? "") < (rhs.texturePath ?? "")
        }
        for key in batchKeys {
            let particles = scene.particles.filter {
                $0.blendMode == key.blendMode
                    && normalizedParticleTexturePath($0.texturePath) == key.texturePath
            }
            guard !particles.isEmpty else { continue }
            let start = instances.count
            for particle in particles {
                instances.append(
                    GPUParticleInstance(
                        positionSize: SIMD4<Float>(particle.position, particle.size),
                        rotation: SIMD4<Float>(particle.rotation, 0, 0, 0),
                        color: particle.color,
                        uvRect: particle.uvRect
                    )
                )
            }
            batches.append(ParticleBatch(key: key, start: start, count: particles.count))
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

        let storageSize = UInt64(instances.count * instanceStride)
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
        for batch in batches {
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
        return batches.count
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

    private func normalizedParticleTexturePath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return path
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
