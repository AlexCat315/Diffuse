#if canImport(CVulkanHeaders)
import CVulkanHeaders

extension VulkanBackend {
    func releaseNativeObjects() {
        _ = context.instanceCommands.deviceWaitIdle(context.device)
        swapchain?.destroy(registries: registries)
        if swapchain == nil, let surface { context.instanceCommands.destroySurfaceKHR(context.instance, surface, nil) }
        for id in Array(registries.accelerationStructures.keys) { destroyAccelerationStructure(AccelerationStructure(id: id)) }
        for id in Array(registries.meshPipelines.keys) { destroyMeshPipeline(MeshPipeline(id: id)) }
        for id in Array(registries.graphicsPipelines.keys) { destroyGraphicsPipeline(GraphicsPipeline(id: id)) }
        for id in Array(registries.computePipelines.keys) { destroyComputePipeline(ComputePipeline(id: id)) }
        context.core.destroyDescriptorPool(context.device, descriptorPool, nil)
        for layout in registries.pipelineLayouts.values { context.resources.destroyPipelineLayout(context.device, layout.native, nil) }
        for layout in registries.bindingLayouts.values { context.resources.destroyDescriptorSetLayout(context.device, layout, nil) }
        for id in Array(registries.shaderModules.keys) { destroyShaderModule(ShaderModule(id: id)) }
        for id in Array(registries.samplers.keys) { destroySampler(Sampler(id: id)) }
        for id in Array(registries.textures.keys) { destroyTexture(Texture(id: id)) }
        for id in Array(registries.buffers.keys) { destroyBuffer(Buffer(id: id)) }
        for frame in frames {
            for pool in frame.commandPools.values { context.auxiliary.destroyCommandPool(context.device, pool, nil) }
            if let semaphore = frame.acquireSemaphore { sync.destroySemaphore(context.device, semaphore, nil) }
        }
        for semaphore in timelineSemaphores.values { sync.destroySemaphore(context.device, semaphore, nil) }
        for semaphore in presentation.ready.values { sync.destroySemaphore(context.device, semaphore, nil) }
        if let scratchCommandPool { context.auxiliary.destroyCommandPool(context.device, scratchCommandPool, nil) }
        if let scratchFence { sync.destroyFence(context.device, scratchFence, nil) }
        allocator.destroyAll()
        context.instanceCommands.destroyDevice(context.device, nil)
        context.instanceCommands.destroyInstance(context.instance, nil)
    }
}
#endif
