// NativeRHI Metal backend — resource & pipeline creation, and destruction.

#if os(macOS)
import Metal

extension MetalDevice {
    // MARK: Buffers

    public func createBuffer(_ handle: Buffer, descriptor: BufferDescriptor) throws {
        guard descriptor.size > 0 else {
            throw RHIError.invalidArgument("buffer size must be > 0")
        }
        // Shared storage is CPU-writable and GPU/CPU coherent (Apple Silicon
        // uniform memory), so immediate uploads can memcpy into contents.
        guard let buffer = device.makeBuffer(length: descriptor.size, options: .storageModeShared) else {
            throw RHIError.outOfMemory
        }
        buffer.label = descriptor.label
        registries.buffers[handle.id] = buffer
    }

    // MARK: Textures

    public func createTexture(_ handle: Texture, descriptor: TextureDescriptor) throws {
        try rhiValidateTextureSamples(descriptor)
        guard device.supportsTextureSampleCount(descriptor.sampleCount) else {
            throw RHIError.unsupportedFeature("Metal adapter does not support the requested texture sample count")
        }
        let td = MTLTextureDescriptor()
        td.pixelFormat = mtlPixelFormat(descriptor.format)
        td.width = max(1, descriptor.width)
        td.height = max(1, descriptor.height)
        td.depth = max(1, descriptor.depth)
        td.textureType = descriptor.sampleCount > 1 ? .type2DMultisample : mtlTextureType(descriptor.dimension)
        if descriptor.dimension == .texture2DArray {
            td.arrayLength = max(1, descriptor.layers)
        }
        td.mipmapLevelCount = max(1, descriptor.mipLevels)
        td.sampleCount = max(1, descriptor.sampleCount)
        td.usage = mtlTextureUsage(descriptor.usage)
        // Device-local storage; immediate uploads blit from shared staging.
        td.storageMode = .private
        guard let texture = device.makeTexture(descriptor: td) else {
            throw RHIError.outOfMemory
        }
        texture.label = descriptor.label
        registries.textures[handle.id] = texture
    }

    // MARK: Samplers

    public func createSampler(_ handle: Sampler, descriptor: SamplerDescriptor) throws {
        let sd = MTLSamplerDescriptor()
        sd.minFilter = mtlSamplerMinMagFilter(descriptor.minFilter)
        sd.magFilter = mtlSamplerMinMagFilter(descriptor.magFilter)
        sd.mipFilter = mtlSamplerMipFilter(descriptor.mipFilter)
        sd.sAddressMode = mtlSamplerAddressMode(descriptor.addressModeU)
        sd.tAddressMode = mtlSamplerAddressMode(descriptor.addressModeV)
        sd.rAddressMode = mtlSamplerAddressMode(descriptor.addressModeW)
        if descriptor.compareEnabled {
            sd.compareFunction = mtlCompareFunction(descriptor.compareOp)
        }
        guard let sampler = device.makeSamplerState(descriptor: sd) else {
            throw RHIError.outOfMemory
        }
        registries.samplers[handle.id] = sampler
    }

    // MARK: Shader modules

    public func createShaderModule(_ handle: ShaderModule, descriptor: ShaderModuleDescriptor) throws {
        let library = try libraryCache.library(for: descriptor)
        let function: MTLFunction?
        if descriptor.specializationConstants.isEmpty { function = library.makeFunction(name: descriptor.entryPoint) }
        else {
            let constants = MTLFunctionConstantValues()
            for constant in descriptor.specializationConstants {
                let type: MTLDataType
                switch constant.value.type { case .uint32: type = .uint; case .int32: type = .int; case .float32: type = .float; case .bool: type = .bool }
                var bits = constant.value.bits
                withUnsafePointer(to: &bits) { constants.setConstantValue($0,type: type,index: Int(constant.id)) }
            }
            function = try library.makeFunction(name: descriptor.entryPoint,constantValues: constants)
        }
        guard let function else {
            throw RHIError.invalidArgument(
                "entry point '\(descriptor.entryPoint)' not found in the compiled library"
            )
        }
        registries.shaderStages[handle.id] = descriptor.stage
        registries.shaderThreadgroupSizes[handle.id] = descriptor.threadgroupSize
        registries.shaderFunctions[handle.id] = function
        registries.shaderLibraries[handle.id] = library
    }

    // MARK: Graphics pipelines

    public func createGraphicsPipeline(_ handle: GraphicsPipeline, descriptor: GraphicsPipelineDescriptor) throws {
        guard let vertexFunction = registries.shaderFunctions[descriptor.vertex.id] else {
            throw RHIError.invalidArgument("graphics pipeline: vertex shader module not found")
        }
        var fragmentFunction: MTLFunction?
        if let fragment = descriptor.fragment {
            guard let function = registries.shaderFunctions[fragment.id] else {
                throw RHIError.invalidArgument("graphics pipeline: fragment shader module not found")
            }
            fragmentFunction = function
        }

        let pd = MTLRenderPipelineDescriptor()
        try rhiValidateSampleCount(descriptor.sampleCount)
        guard device.supportsTextureSampleCount(descriptor.sampleCount) else {
            throw RHIError.unsupportedFeature("Metal adapter does not support the requested pipeline sample count")
        }
        pd.rasterSampleCount = descriptor.sampleCount
        pd.vertexFunction = vertexFunction
        pd.fragmentFunction = fragmentFunction

        // MRT: one color attachment per descriptor entry.
        for (index, attachment) in descriptor.colorAttachments.enumerated() {
            guard let mtlAttachment = pd.colorAttachments[index] else { continue }
            mtlAttachment.pixelFormat = mtlPixelFormat(attachment.format)
            let blend = attachment.blend
            if blend.enabled {
                mtlAttachment.isBlendingEnabled = true
                mtlAttachment.sourceRGBBlendFactor = mtlBlendFactor(blend.sourceColorBlendFactor)
                mtlAttachment.destinationRGBBlendFactor = mtlBlendFactor(blend.destinationColorBlendFactor)
                mtlAttachment.rgbBlendOperation = mtlBlendOperation(blend.colorBlendOperation)
                mtlAttachment.sourceAlphaBlendFactor = mtlBlendFactor(blend.sourceAlphaBlendFactor)
                mtlAttachment.destinationAlphaBlendFactor = mtlBlendFactor(blend.destinationAlphaBlendFactor)
                mtlAttachment.alphaBlendOperation = mtlBlendOperation(blend.alphaBlendOperation)
            }
        }

        if let depthFormat = descriptor.depthFormat {
            pd.depthAttachmentPixelFormat = mtlPixelFormat(depthFormat)
        }
        if let stencilFormat = descriptor.stencilFormat {
            pd.stencilAttachmentPixelFormat = mtlPixelFormat(stencilFormat)
        }

        // Rasterization itself (cull/winding/fill) is encoder state in Metal;
        // stash the descriptor so the render encoder can apply it on bind.
        registries.pipelineRasterStates[handle.id] = descriptor.rasterization

        // Vertex layout. Throw on capacity overflow (never silently truncate).
        if let layout = descriptor.vertexLayout {
            guard layout.attributes.count <= 32 else {
                throw RHIError.invalidArgument(
                    "graphics pipeline has \(layout.attributes.count) vertex attributes; limit is 32"
                )
            }
            guard layout.bufferLayouts.count <= 8 else {
                throw RHIError.invalidArgument(
                    "graphics pipeline has \(layout.bufferLayouts.count) buffer layouts; limit is 8"
                )
            }
            pd.vertexDescriptor = makeVertexDescriptor(layout)
        }

        do {
            let state = try device.makeRenderPipelineState(descriptor: pd)
            registries.renderPipelines[handle.id] = MetalGraphicsPipeline(state: state, descriptor: descriptor)
        } catch {
            throw RHIError.invalidArgument(
                "graphics pipeline failed: \(error.localizedDescription)"
            )
        }
        registries.pipelinePrimitives[handle.id] = mtlPrimitiveType(descriptor.primitive)

        // Depth/stencil state paired with this pipeline.
        if let depthStencil = descriptor.depthStencil {
            let dsd = MTLDepthStencilDescriptor()
            dsd.depthCompareFunction = mtlCompareFunction(depthStencil.depthCompare)
            dsd.isDepthWriteEnabled = depthStencil.depthWriteEnabled
            if let state = device.makeDepthStencilState(descriptor: dsd) {
                registries.depthStates[handle.id] = state
            }
        }
    }

    private func makeVertexDescriptor(_ layout: VertexLayoutDescriptor) -> MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        for attribute in layout.attributes {
            guard let attr = vd.attributes[Int(attribute.location)] else { continue }
            attr.format = mtlVertexFormat(attribute.format)
            attr.offset = attribute.offset
            attr.bufferIndex = Int(kMetalVertexBufferBaseIndex) + Int(attribute.bufferIndex)
        }
        for (index, bufferLayout) in layout.bufferLayouts.enumerated() {
            guard let layoutEntry = vd.layouts[Int(kMetalVertexBufferBaseIndex) + index] else { continue }
            layoutEntry.stride = bufferLayout.stride
            layoutEntry.stepFunction = mtlVertexStepFunction(bufferLayout.stepRate)
            layoutEntry.stepRate = 1
        }
        return vd
    }

    // MARK: Compute pipelines

    public func createComputePipeline(_ handle: ComputePipeline, descriptor: ComputePipelineDescriptor) throws {
        guard registries.shaderStages[descriptor.shader.id] == .compute,
              let function = registries.shaderFunctions[descriptor.shader.id] else {
            throw RHIError.invalidArgument("compute pipeline: shader module not found")
        }
        do {
            let state = try device.makeComputePipelineState(function: function)
            let size = registries.shaderThreadgroupSizes[descriptor.shader.id] ?? ThreadgroupSize()
            try rhiRequire(size.x * size.y * size.z <= state.maxTotalThreadsPerThreadgroup,
                           "compute workgroup exceeds pipeline limit")
            registries.computeThreadgroupSizes[handle.id] = size
            registries.computePipelines[handle.id] = state
        } catch {
            throw RHIError.invalidArgument(
                "compute pipeline failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: Deferred destruction (FrameRing already waited; just release).

    public func destroyBuffer(_ handle: Buffer) {
        registries.bindingSets.removeAll(referencing: handle.id)
        registries.buffers[handle.id] = nil
    }

    public func destroyTexture(_ handle: Texture) {
        registries.bindingSets.removeAll(referencing: handle.id)
        registries.textures[handle.id] = nil
    }

    public func destroySampler(_ handle: Sampler) {
        registries.bindingSets.removeAll(referencing: handle.id)
        registries.samplers[handle.id] = nil
    }

    public func destroyShaderModule(_ handle: ShaderModule) {
        registries.shaderStages[handle.id] = nil
        registries.shaderThreadgroupSizes[handle.id] = nil
        registries.shaderFunctions[handle.id] = nil
        registries.shaderLibraries[handle.id] = nil
    }

    public func destroyGraphicsPipeline(_ handle: GraphicsPipeline) {
        registries.renderPipelines[handle.id] = nil
        registries.depthStates[handle.id] = nil
        registries.pipelinePrimitives[handle.id] = nil
        registries.pipelineRasterStates[handle.id] = nil
    }

    public func destroyComputePipeline(_ handle: ComputePipeline) {
        registries.computeThreadgroupSizes[handle.id] = nil
        registries.computePipelines[handle.id] = nil
    }
}

#endif
