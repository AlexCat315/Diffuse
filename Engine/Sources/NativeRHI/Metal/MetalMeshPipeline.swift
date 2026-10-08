#if os(macOS)
import Metal

struct MetalMeshPipeline {
    let state: MTLRenderPipelineState
    let meshSize: ThreadgroupSize
    let taskSize: ThreadgroupSize
    let rasterization: RasterizationState
}

extension MetalDevice {
    public func createMeshPipeline(_ handle: MeshPipeline, descriptor: MeshPipelineDescriptor) throws {
        guard queryAdapterCapabilities().meshShading else {
            throw RHIError.unsupportedFeature("adapter has no mesh shader support")
        }
        guard registries.shaderStages[descriptor.mesh.id] == .mesh,
              let mesh = registries.shaderFunctions[descriptor.mesh.id] else {
            throw RHIError.invalidArgument("mesh pipeline requires a mesh shader")
        }
        let pd = MTLMeshRenderPipelineDescriptor()
        pd.meshFunction = mesh
        pd.label = descriptor.label
        if let task = descriptor.task {
            guard capabilities.meshShading.task else {
                throw RHIError.unsupportedFeature("task shaders are not enabled in the current mesh implementation")
            }
            guard registries.shaderStages[task.id] == .task else {
                throw RHIError.invalidArgument("task shader stage mismatch")
            }
            pd.objectFunction = registries.shaderFunctions[task.id]
        }
        if let fragment = descriptor.fragment {
            guard registries.shaderStages[fragment.id] == .fragment else {
                throw RHIError.invalidArgument("fragment shader stage mismatch")
            }
            pd.fragmentFunction = registries.shaderFunctions[fragment.id]
        }
        try rhiRequire(descriptor.colorAttachments.count <= 8, "too many mesh color attachments")
        for (index, attachment) in descriptor.colorAttachments.enumerated() {
            let target = pd.colorAttachments[index]!
            target.pixelFormat = mtlPixelFormat(attachment.format)
            let blend = attachment.blend
            target.isBlendingEnabled = blend.enabled
            target.sourceRGBBlendFactor = mtlBlendFactor(blend.sourceColorBlendFactor)
            target.destinationRGBBlendFactor = mtlBlendFactor(blend.destinationColorBlendFactor)
            target.rgbBlendOperation = mtlBlendOperation(blend.colorBlendOperation)
            target.sourceAlphaBlendFactor = mtlBlendFactor(blend.sourceAlphaBlendFactor)
            target.destinationAlphaBlendFactor = mtlBlendFactor(blend.destinationAlphaBlendFactor)
            target.alphaBlendOperation = mtlBlendOperation(blend.alphaBlendOperation)
        }
        if let depth = descriptor.depthFormat { pd.depthAttachmentPixelFormat = mtlPixelFormat(depth) }
        // Depth state requires its own encoder binding. Reject it until this
        // pipeline has a depth-state implementation rather than dropping it.
        guard descriptor.depthStencil == nil else {
            throw RHIError.unsupportedFeature("mesh depth/stencil state is not implemented")
        }
        let state = try device.makeRenderPipelineState(descriptor: pd, options: []).0
        let meshSize = registries.shaderThreadgroupSizes[descriptor.mesh.id] ?? ThreadgroupSize()
        let taskSize = descriptor.task.flatMap { registries.shaderThreadgroupSizes[$0.id] } ?? ThreadgroupSize()
        try rhiRequire(meshSize.x * meshSize.y * meshSize.z <= state.maxTotalThreadsPerMeshThreadgroup,
                       "mesh workgroup exceeds pipeline limit")
        if descriptor.task != nil {
            try rhiRequire(taskSize.x * taskSize.y * taskSize.z <= state.maxTotalThreadsPerObjectThreadgroup,
                           "task workgroup exceeds pipeline limit")
        }
        registries.meshPipelines[handle.id] = MetalMeshPipeline(
            state: state, meshSize: meshSize, taskSize: taskSize, rasterization: descriptor.rasterization)
    }

    public func destroyMeshPipeline(_ handle: MeshPipeline) {
        registries.meshPipelines[handle.id] = nil
    }
}

extension ThreadgroupSize {
    var metalSize: MTLSize { MTLSize(width: x, height: y, depth: z) }
}
#endif
