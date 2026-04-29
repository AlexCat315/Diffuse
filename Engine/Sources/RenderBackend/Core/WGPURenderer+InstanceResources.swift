import RHIWGPU
import SceneRuntime
import simd

extension WGPURenderer {
    func writeInstanceUniforms(scene: RenderScene, viewProj: simd_float4x4) {
        if let dyn = dynamicInstanceResources {
            for (i, instance) in scene.instances.enumerated() {
                var mvp = viewProj * instance.transform
                let offset = UInt64(i) * dyn.stride
                withUnsafeBytes(of: &mvp) { raw in
                    if let base = raw.baseAddress {
                        backend.writeBuffer(
                            dyn.uniformBuffer, data: base, size: raw.count, offset: offset)
                    }
                }
            }
            return
        }

        for (i, instance) in scene.instances.enumerated() where i < instanceResources.count {
            var mvp = viewProj * instance.transform
            withUnsafeBytes(of: &mvp) { raw in
                if let base = raw.baseAddress {
                    backend.writeBuffer(instanceResources[i].uniformBuffer, data: base, size: raw.count)
                }
            }
        }
    }

    func ensureInstanceResources(scene: RenderScene, pipeline: GPURenderPipeline) throws {
        let instanceCount = scene.instances.count
        let meshIndices = scene.instances.map(\.meshIndex)

        let useDynamicOffsets = instanceCount > dynamicOffsetThreshold
        let bindGroupLayout: GPUBindGroupLayout
        if let meshBindGroupLayout {
            bindGroupLayout = meshBindGroupLayout
        } else {
            bindGroupLayout = try pipeline.getBindGroupLayout(group: 0)
        }

        if useDynamicOffsets {
            if let dyn = dynamicInstanceResources, dyn.capacity >= instanceCount {
                instanceResourceMeshIndices = meshIndices
                return
            }
            instanceResources.removeAll(keepingCapacity: false)
            instanceResourceMeshIndices = meshIndices

            let totalSize = UInt64(max(instanceCount, 1)) * dynamicUniformStride
            let uniformBuffer = try backend.createBuffer(size: totalSize, usage: [.uniform, .copyDst])
            let bindGroup = try backend.createBindGroup(
                layout: bindGroupLayout,
                entries: try meshBindGroupEntries(instanceUniformBuffer: uniformBuffer)
            )
            dynamicInstanceResources = DynamicInstanceResources(
                uniformBuffer: uniformBuffer,
                bindGroup: bindGroup,
                stride: dynamicUniformStride,
                capacity: instanceCount
            )
            return
        }

        if dynamicInstanceResources == nil
            && instanceResources.count == instanceCount
            && instanceResourceMeshIndices == meshIndices {
            return
        }

        dynamicInstanceResources = nil
        instanceResources.removeAll(keepingCapacity: false)
        instanceResourceMeshIndices = meshIndices
        for meshIndex in meshIndices {
            let uniformBuffer = try backend.createBuffer(size: 64, usage: [.uniform, .copyDst])
            let bindGroup = try backend.createBindGroup(
                layout: bindGroupLayout,
                entries: try meshBindGroupEntries(
                    instanceUniformBuffer: uniformBuffer,
                    baseColorTextureView: baseColorTextureView(for: meshIndex)
                )
            )
            instanceResources.append(
                InstanceResources(uniformBuffer: uniformBuffer, bindGroup: bindGroup))
        }
    }

    func meshBindGroupEntries(instanceUniformBuffer: GPUBuffer,
                              baseColorTextureView: GPUTextureView? = nil) throws -> [GPUBindGroupEntry] {
        try ensureStylizedCharacterUniformBuffer()
        try ensureMeshSamplingFallbackResources()
        guard let stylizedCharacterUniformBuffer,
              let linearSampler,
              let fallbackMeshTextureView
        else {
            throw WGPUBackendError.initFailed("mesh bind group resources missing")
        }
        let textureView = baseColorTextureView ?? fallbackMeshTextureView
        return [
            GPUBindGroupEntry(binding: 0, buffer: instanceUniformBuffer, offset: 0, size: 64),
            GPUBindGroupEntry(
                binding: 1,
                buffer: stylizedCharacterUniformBuffer,
                offset: 0,
                size: UInt64(MemoryLayout<StylizedCharacterUniforms>.stride)
            ),
            GPUBindGroupEntry(binding: 2, sampler: linearSampler),
            GPUBindGroupEntry(binding: 3, textureView: textureView),
        ]
    }

    func baseColorTextureView(for meshIndex: Int) -> GPUTextureView? {
        guard let materialSet = MeshMaterialRegistry.shared.materials(for: meshIndex),
              let textureIndex = materialSet.materials.first?.baseColorTextureIndex
        else {
            return nil
        }
        return meshTextureResources[meshIndex]?[textureIndex]?.view
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
        if fallbackMeshTextureView != nil { return }
        let texture = try backend.createTexture(
            width: 1,
            height: 1,
            format: .rgba8Unorm,
            usage: [.textureBinding, .copyDst]
        )
        let whitePixel: [UInt8] = [255, 255, 255, 255]
        whitePixel.withUnsafeBytes { raw in
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
        fallbackMeshTexture = texture
        fallbackMeshTextureView = try texture.createView()
    }
}
