#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders

struct VulkanMeshPipelineRecord {
    let pipeline: VkPipeline
    let descriptor: MeshPipelineDescriptor
}

extension VulkanBackend {
    func createMeshPipeline(_ handle: MeshPipeline, descriptor: MeshPipelineDescriptor) throws {
        guard context.features.mesh, let module = registries.shaderModules[descriptor.mesh.id], module.stage == .mesh,
              let layout = registries.pipelineLayouts[descriptor.layout.id] else { throw RHIError.unsupportedFeature("Vulkan mesh shader unavailable or invalid layout") }
        let arena = VulkanScratch()
        var stages = [try shaderStage(module, arena: arena)]
        if let task = descriptor.task {
            guard context.features.task, let module = registries.shaderModules[task.id], module.stage == .task else { throw RHIError.unsupportedFeature("Vulkan task shader unavailable") }
            stages.append(try shaderStage(module, arena: arena))
        }
        if let fragment = descriptor.fragment {
            guard let module = registries.shaderModules[fragment.id], module.stage == .fragment else { throw RHIError.invalidArgument("unknown fragment shader") }
            stages.append(try shaderStage(module, arena: arena))
        }
        let graphics = meshGraphicsDescriptor(descriptor)
        let pipeline = try graphicsPipeline(graphics, nativeLayout: layout.native, stages: stages, arena: arena)
        registries.meshPipelines[handle.id] = VulkanMeshPipelineRecord(pipeline: pipeline, descriptor: descriptor)
    }
    func meshGraphicsDescriptor(_ descriptor: MeshPipelineDescriptor) -> GraphicsPipelineDescriptor {
        GraphicsPipelineDescriptor(layout: descriptor.layout, vertex: ShaderModule(id: 0), fragment: descriptor.fragment,
            colorAttachments: descriptor.colorAttachments, depthFormat: descriptor.depthFormat,
            rasterization: descriptor.rasterization, depthStencil: descriptor.depthStencil)
    }
    func destroyMeshPipeline(_ handle: MeshPipeline) {
        guard let record = registries.meshPipelines.removeValue(forKey: handle.id) else { return }
        context.resources.destroyPipeline(context.device, record.pipeline, nil)
    }
}
#endif
