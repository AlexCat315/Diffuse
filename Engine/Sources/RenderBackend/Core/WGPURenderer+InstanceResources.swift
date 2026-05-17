import RHIWGPU
import SceneRuntime
import simd

private struct MeshInstanceUniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
    var colorTint: SIMD4<Float>
}

extension WGPURenderer {
    func writeInstanceUniforms(scene: RenderScene, viewProj: simd_float4x4) {
        if let dyn = dynamicInstanceResources {
            for (i, instance) in scene.instances.enumerated() {
                var u = MeshInstanceUniforms(
                    mvp: viewProj * instance.transform,
                    model: instance.transform,
                    colorTint: effectiveBaseColor(for: instance)
                )
                let offset = UInt64(i) * dyn.stride
                withUnsafeBytes(of: &u) { raw in
                    if let base = raw.baseAddress {
                        backend.writeBuffer(
                            dyn.uniformBuffer, data: base, size: raw.count, offset: offset)
                    }
                }
            }
            return
        }

        for (i, instance) in scene.instances.enumerated() where i < instanceResources.count {
            var u = MeshInstanceUniforms(
                mvp: viewProj * instance.transform,
                model: instance.transform,
                colorTint: effectiveBaseColor(for: instance)
            )
            withUnsafeBytes(of: &u) { raw in
                if let base = raw.baseAddress {
                    backend.writeBuffer(instanceResources[i].uniformBuffer, data: base, size: raw.count)
                }
            }
        }
    }

    func ensureInstanceResources(scene: RenderScene, pipeline: GPURenderPipeline) throws {
        let instanceCount = scene.instances.count
        let resourceKeys = scene.instances.map {
            InstanceResourceKey(meshIndex: $0.meshIndex,
                                baseColorTextureIndex: $0.material.baseColorTextureIndex)
        }

        let useDynamicOffsets = instanceCount > dynamicOffsetThreshold
        let bindGroupLayout: GPUBindGroupLayout
        if let meshBindGroupLayout {
            bindGroupLayout = meshBindGroupLayout
        } else {
            bindGroupLayout = try pipeline.getBindGroupLayout(group: 0)
        }

        if useDynamicOffsets {
            if let dyn = dynamicInstanceResources,
               dyn.capacity >= instanceCount,
               instanceResourceShadowGeneration == shadowResourceGeneration {
                instanceResourceKeys = resourceKeys
                return
            }
            instanceResources.removeAll(keepingCapacity: false)
            instanceResourceKeys = resourceKeys

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
            instanceResourceShadowGeneration = shadowResourceGeneration
            return
        }

        if dynamicInstanceResources == nil
            && instanceResources.count == instanceCount
            && instanceResourceKeys == resourceKeys
            && instanceResourceShadowGeneration == shadowResourceGeneration {
            return
        }

        dynamicInstanceResources = nil
        instanceResources.removeAll(keepingCapacity: false)
        instanceResourceKeys = resourceKeys
        for instance in scene.instances {
            let uniformBuffer = try backend.createBuffer(
                size: UInt64(MemoryLayout<MeshInstanceUniforms>.stride),
                usage: [.uniform, .copyDst]
            )
            let bindGroup = try backend.createBindGroup(
                layout: bindGroupLayout,
                entries: try meshBindGroupEntries(
                    instanceUniformBuffer: uniformBuffer,
                    baseColorTextureView: baseColorTextureView(for: instance)
                )
            )
            instanceResources.append(
                InstanceResources(uniformBuffer: uniformBuffer, bindGroup: bindGroup))
        }
        instanceResourceShadowGeneration = shadowResourceGeneration
    }

    func meshBindGroupEntries(instanceUniformBuffer: GPUBuffer,
                              baseColorTextureView: GPUTextureView? = nil) throws -> [GPUBindGroupEntry] {
        try ensureStylizedCharacterUniformBuffer()
        try ensureMeshSamplingFallbackResources()
        try ensureSceneLightUniformBuffer()
        try ensureShadowResources(settings: activeRenderSettings.shadowSettings)
        guard let stylizedCharacterUniformBuffer,
              let linearSampler,
              let fallbackMeshTextureView,
              let sceneLightUniformBuffer,
              let shadowUniformBuffer,
              let shadowSampler,
              let shadowMapTarget
        else {
            throw WGPUBackendError.initFailed("mesh bind group resources missing")
        }
        let textureView = baseColorTextureView ?? fallbackMeshTextureView
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
        ]
    }

    func baseColorTextureView(for instance: RenderInstance) -> GPUTextureView? {
        let meshIndex = instance.meshIndex
        if let textureIndex = instance.material.baseColorTextureIndex {
            return meshTextureResources[meshIndex]?[textureIndex]?.view
        }
        guard let materialSet = MeshMaterialRegistry.shared.materials(for: meshIndex),
              let textureIndex = materialSet.materials.compactMap(\.baseColorTextureIndex).first
        else {
            return nil
        }
        return meshTextureResources[meshIndex]?[textureIndex]?.view
    }

    func effectiveBaseColor(for instance: RenderInstance) -> SIMD4<Float> {
        let materialColor = instance.material.baseColorFactor
        return SIMD4<Float>(
            instance.colorTint.x * materialColor.x,
            instance.colorTint.y * materialColor.y,
            instance.colorTint.z * materialColor.z,
            materialColor.w
        )
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
        shadowBindingsByLightIndex: [Int: ShadowLightBinding] = [:]
    ) {
        guard let sceneLightUniformBuffer else { return }
        var uniforms = SceneLightUniforms(
            scene: scene,
            shadowBindingsByLightIndex: shadowBindingsByLightIndex
        )
        writeUniform(&uniforms, buffer: sceneLightUniformBuffer)
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
