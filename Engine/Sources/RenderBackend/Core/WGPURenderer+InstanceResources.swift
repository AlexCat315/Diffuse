import RHIWGPU
import SceneRuntime
import SIMDCompat

struct MeshInstanceUniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var colorTint: SIMD4<Float>
    var material: SIMD4<Float> = .zero
}

extension WGPURenderer {
    func meshBindGroupEntries(instanceUniformBuffer: GPUBuffer,
                              baseColorTextureView: GPUTextureView? = nil,
                              normalMapTextureView: GPUTextureView? = nil,
                              metallicRoughnessTextureView: GPUTextureView? = nil,
                              jointPaletteBuffer: GPUBuffer? = nil,
                              instanceStorageBuffer: GPUBuffer? = nil) throws -> [GPUBindGroupEntry] {
        try ensureStylizedCharacterUniformBuffer()
        try ensureMeshSamplingFallbackResources()
        try ensureIBLEnvironment()
        try ensureSceneLightUniformBuffer()
        try ensureShadowResources(settings: activeRenderSettings.shadowSettings)
        try ensureFallbackJointPaletteBuffer()
        guard let stylizedCharacterUniformBuffer,
              let linearSampler,
              let fallbackMeshTextureView,
              let fallbackNormalMapTextureView,
              let fallbackMetallicRoughnessTextureView,
              let sceneLightUniformBuffer,
              let shadowUniformBuffer,
              let shadowSampler,
              let shadowMapTarget,
              let fallbackJointPaletteBuffer
        else {
            throw WGPUBackendError.initFailed("mesh bind group resources missing")
        }
        if fallbackInstanceStorageBuffer == nil {
            fallbackInstanceStorageBuffer = try backend.createBuffer(size: UInt64(MemoryLayout<MeshInstanceUniforms>.stride), usage: [.storage, .copyDst])
        }
        let instances = instanceStorageBuffer ?? fallbackInstanceStorageBuffer!
        let textureView = baseColorTextureView ?? fallbackMeshTextureView
        let normalView  = normalMapTextureView ?? fallbackNormalMapTextureView
        let mrView      = metallicRoughnessTextureView ?? fallbackMetallicRoughnessTextureView
        let iblView     = iblEnvironmentView ?? fallbackMeshTextureView
        let paletteBuffer = jointPaletteBuffer ?? fallbackJointPaletteBuffer
        return [
            GPUBindGroupEntry(
                binding: 0,
                buffer: instanceUniformBuffer,
                offset: 0,
                size: UInt64(MemoryLayout<MeshInstanceUniforms>.stride)
            ),
            GPUBindGroupEntry(
                binding: 1,
                buffer: stylizedCharacterUniformBuffer,
                offset: 0,
                size: UInt64(MemoryLayout<StylizedCharacterUniforms>.stride)
            ),
            GPUBindGroupEntry(binding: 2, sampler: linearSampler),
            GPUBindGroupEntry(binding: 3, textureView: textureView),
            GPUBindGroupEntry(
                binding: 4,
                buffer: sceneLightUniformBuffer,
                offset: 0,
                size: SceneLightUniforms.byteSize
            ),
            GPUBindGroupEntry(
                binding: 5,
                buffer: shadowUniformBuffer,
                offset: 0,
                size: UInt64(MemoryLayout<ShadowUniforms>.stride)
            ),
            GPUBindGroupEntry(binding: 6, sampler: shadowSampler),
            GPUBindGroupEntry(binding: 7, textureView: shadowMapTarget.colorView),
            GPUBindGroupEntry(
                binding: 8,
                buffer: paletteBuffer,
                offset: 0,
                size: paletteBuffer.size
            ),
            GPUBindGroupEntry(binding: 9, textureView: normalView),
            GPUBindGroupEntry(binding: 10, textureView: mrView),
            GPUBindGroupEntry(binding: 11, textureView: iblView),
            GPUBindGroupEntry(binding: 12, buffer: instances, offset: 0, size: instances.size),
        ]
    }

    func ensureStylizedCharacterUniformBuffer() throws {
        guard backend.rawDevice != nil else { return }
        if stylizedCharacterUniformBuffer != nil { return }
        stylizedCharacterUniformBuffer = try backend.createBuffer(size: 256, usage: [.uniform, .copyDst])
    }

    func writeStylizedCharacterUniforms() {
        guard let stylizedCharacterUniformBuffer else { return }
        let style = activeRenderSettings.stylizedCharacterStyle
        var uniforms = StylizedCharacterUniforms(
            toonThresholds: style.toonThresholds,
            toonLevels: style.toonLevels,
            inkWashColor: style.inkWashColor,
            params: SIMD4<Float>(
                style.paperGrainStrength,
                style.rimStrength,
                style.materialBiasStrength,
                style.outlineWidth
            )
        )
        withUnsafeBytes(of: &uniforms) { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(stylizedCharacterUniformBuffer,
                                    data: base,
                                    size: raw.count)
            }
        }
    }

    func ensureSceneLightUniformBuffer() throws {
        guard backend.rawDevice != nil else { return }
        if sceneLightUniformBuffer != nil { return }
        sceneLightUniformBuffer = try backend.createBuffer(size: SceneLightUniforms.byteSize, usage: [.uniform, .copyDst])
    }

    func writeSceneLightUniforms(
        scene: RenderScene,
        shadowBindingsByLightIndex: [Int: ShadowLightBinding] = [:],
        debugViewMode: Int = 0
    ) {
        guard let sceneLightUniformBuffer else { return }
        var uniforms = SceneLightUniforms(
            scene: scene,
            shadowBindingsByLightIndex: shadowBindingsByLightIndex
        )
        // Pack the viewport debug-view selector into the free .z lane so the mesh
        // shader can switch G-buffer visualizations without a dedicated binding.
        uniforms.exposureAndLightCount.z = Float(debugViewMode)
        writeUniform(&uniforms, buffer: sceneLightUniformBuffer)
    }

    func ensureFallbackJointPaletteBuffer() throws {
        guard backend.rawDevice != nil else { return }
        if fallbackJointPaletteBuffer != nil { return }
        let size = UInt64(MemoryLayout<simd_float4x4>.stride)
        let buf = try backend.createBuffer(size: size, usage: [.storage, .copyDst])
        var identity = matrix_identity_float4x4
        withUnsafeBytes(of: &identity) { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(buf, data: base, size: raw.count)
            }
        }
        fallbackJointPaletteBuffer = buf
    }

    func ensureJointPaletteBuffers(from paletteMap: JointPaletteMap) throws {
        for (entityID, palette) in paletteMap.palettes {
            let required = UInt64(max(palette.matrices.count, 1)) * UInt64(MemoryLayout<simd_float4x4>.stride)
            if let existing = jointPaletteBuffers[entityID], existing.size >= required { continue }
            jointPaletteBuffers[entityID] = try backend.createBuffer(size: required, usage: [.storage, .copyDst])
        }
    }

    func writeJointPaletteBuffers(from paletteMap: JointPaletteMap) {
        for (entityID, palette) in paletteMap.palettes {
            guard let buffer = jointPaletteBuffers[entityID], !palette.matrices.isEmpty else { continue }
            palette.matrices.withUnsafeBufferPointer { ptr in
                let raw = UnsafeRawPointer(ptr.baseAddress!)
                let size = ptr.count * MemoryLayout<simd_float4x4>.stride
                backend.writeBuffer(buffer, data: raw, size: size)
            }
        }
    }

    func ensureMeshSamplingFallbackResources() throws {
        guard backend.rawDevice != nil else { return }
        if linearSampler == nil {
            linearSampler = try backend.createSampler(
                desc: GPUSamplerDescriptor(
                    addressModeU: .clampToEdge,
                    addressModeV: .clampToEdge,
                    magFilter: .linear,
                    minFilter: .linear,
                    mipmapFilter: .linear
                )
            )
        }
        if fallbackMeshTextureView == nil {
            let texture = try backend.createTexture(
                width: 1, height: 1, format: .rgba8Unorm, usage: [.textureBinding, .copyDst])
            let whitePixel: [UInt8] = [255, 255, 255, 255]
            whitePixel.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    backend.writeTexture(texture, data: base, dataSize: raw.count,
                                         bytesPerRow: 4, rowsPerImage: 1, width: 1, height: 1)
                }
            }
            fallbackMeshTexture = texture
            fallbackMeshTextureView = try texture.createView()
        }
        if fallbackNormalMapTextureView == nil {
            let texture = try backend.createTexture(
                width: 1, height: 1, format: .rgba8Unorm, usage: [.textureBinding, .copyDst])
            // Flat normal in tangent space: (0,0,1) packed as (128,128,255,255)
            let flatNormal: [UInt8] = [128, 128, 255, 255]
            flatNormal.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    backend.writeTexture(texture, data: base, dataSize: raw.count,
                                         bytesPerRow: 4, rowsPerImage: 1, width: 1, height: 1)
                }
            }
            fallbackNormalMapTexture = texture
            fallbackNormalMapTextureView = try texture.createView()
        }
        if fallbackMetallicRoughnessTextureView == nil {
            let texture = try backend.createTexture(
                width: 1, height: 1, format: .rgba8Unorm, usage: [.textureBinding, .copyDst])
            // ORM/ARM default: AO=1 (R), roughness=1 (G), metallic=0 (B). A
            // metallic of 0 makes the metal BRDF reduce to the existing diffuse
            // look, so meshes without a metallic-roughness map are unchanged.
            let nonMetal: [UInt8] = [255, 255, 0, 255]
            nonMetal.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    backend.writeTexture(texture, data: base, dataSize: raw.count,
                                         bytesPerRow: 4, rowsPerImage: 1, width: 1, height: 1)
                }
            }
            fallbackMetallicRoughnessTexture = texture
            fallbackMetallicRoughnessTextureView = try texture.createView()
        }
    }

    /// Bakes the studio IBL environment into a mipmapped equirect HDR texture
    /// (mip 0 sharp, higher mips = rougher prefilter) once, for sampling in the
    /// mesh shader.
    func ensureIBLEnvironment() throws {
        guard backend.rawDevice != nil, iblEnvironmentView == nil else { return }
        let mips = StudioEnvironmentIBL.generate()
        guard let base = mips.first else { return }
        let texture = try backend.createTexture(
            width: UInt32(base.width),
            height: UInt32(base.height),
            format: .rgba16Float,
            usage: [.textureBinding, .copyDst],
            mipLevels: UInt32(mips.count)
        )
        for (level, mip) in mips.enumerated() {
            mip.halfRGBA.withUnsafeBytes { raw in
                guard let ptr = raw.baseAddress else { return }
                backend.writeTexture(texture, data: ptr, dataSize: raw.count,
                                     bytesPerRow: UInt32(mip.width * 4 * 2),
                                     rowsPerImage: UInt32(mip.height),
                                     width: UInt32(mip.width), height: UInt32(mip.height),
                                     mipLevel: UInt32(level))
            }
        }
        iblEnvironmentTexture = texture
        iblEnvironmentView = try texture.createView()
    }
}
