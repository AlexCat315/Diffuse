// NativeRHI Vulkan — per-frame state, submission, timeline semaphores, and
// swapchain acquire/present. There is no vkQueueWaitIdle on the submit path:
// each submit gets its own fence, the GPU work is queued, and completion fires
// from a background waiter. Acquired images are recycled from a fixed pool.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

/// Per-slot frames-in-flight state: its own command pool and a per-frame binary
/// acquire semaphore. A slot's command pool is reset only when that slot begins
/// a new frame (the FrameRing has already confirmed the GPU finished the old one).
final class VulkanFrame {
    let index: Int
    let commandPool: VkCommandPool
    let acquireSemaphore: VkSemaphore
    let uploader: VulkanFrameUploader

    init(index: Int, commandPool: VkCommandPool, acquireSemaphore: VkSemaphore,
         uploader: VulkanFrameUploader) {
        self.index = index
        self.commandPool = commandPool
        self.acquireSemaphore = acquireSemaphore
        self.uploader = uploader
    }
}

/// A one-shot worker owns the fence until cleanup and callback finish. Native
/// handles are immutable here; no registry or queue mutation occurs off-thread.
private final class VulkanFenceCompletion: @unchecked Sendable {
    private let context: VulkanContext
    private let fence: VkFence
    private let completion: () -> Void

    init(context: VulkanContext, fence: VkFence, completion: @escaping () -> Void) {
        self.context = context
        self.fence = fence
        self.completion = completion
    }

    func wait() {
        var fenceSlot = fence
        _ = context.sync.waitForFences(context.device, 1, &fenceSlot, VK_TRUE, UInt64.max)
        context.sync.destroyFence(context.device, fence, nil)
        completion()
    }
}

/// Adapts the chunked upload ring to the frontend's `FrameUploader` contract.
/// Each chunk's persistently-mapped VkBuffer is exposed as a transient Buffer
/// handle that the command encoder resolves back to the chunk's VkBuffer.
final class VulkanFrameUploader: FrameUploader {
    private unowned let backend: VulkanBackend
    private let allocator: ChunkUploadAllocator<VulkanUploadChunk>

    init(backend: VulkanBackend, factory: @escaping (Int) throws -> VulkanUploadChunk) {
        self.backend = backend
        self.allocator = ChunkUploadAllocator(factory: factory)
    }

    func reset() {
        allocator.reset()
    }

    func write(_ data: Data, alignment: Int) throws -> UploadLocation {
        let placement = try allocator.write(data, alignment: alignment)
        let bufferID = backend.registerTransientBuffer(placement.chunk)
        return UploadLocation(buffer: Buffer(id: bufferID), offset: placement.offset)
    }
}

extension VulkanBackend {
    func makeFrameUploader(slot: Int) -> FrameUploader {
        lock.lock()
        activeSlot = slot
        if slot < frames.count {
            let existing = frames[slot]
            _ = draw.resetCommandPool(context.device, existing.commandPool, 0)
            existing.uploader.reset()
            lock.unlock()
            return existing.uploader
        }
        let pool = vkWithOutHandle { out in
            var info = VkCommandPoolCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
            info.queueFamilyIndex = context.graphicsFamily
            info.flags = UInt32(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
            context.resources.createCommandPool(context.device, &info, nil, out)
        }!
        let semaphore = vkWithOutHandle { out in
            var info = VkSemaphoreCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
            context.sync.createSemaphore(context.device, &info, nil, out)
        }!
        let uploader = VulkanFrameUploader(backend: self) { [context, allocator] capacity in
            try Self.makeUploadChunk(context: context, allocator: allocator, size: capacity)
        }
        let frame = VulkanFrame(index: slot, commandPool: pool,
                                acquireSemaphore: semaphore, uploader: uploader)
        if frames.count <= slot {
            frames.append(contentsOf: Array(repeating: frame, count: slot - frames.count + 1))
        }
        frames[slot] = frame
        lock.unlock()
        return uploader
    }

    /// Registers a chunk's persistently-mapped VkBuffer as a transient buffer
    /// handle, reusing the same internal ID for repeated writes into one chunk.
    func registerTransientBuffer(_ chunk: VulkanUploadChunk) -> UInt32 {
        let key = ObjectIdentifier(chunk)
        if let existing = chunkBufferIDs[key] { return existing }
        let id = registries.nextInternalID()
        registries.buffers[id] = VulkanBufferRecord(
            buffer: chunk.buffer,
            allocation: chunk.allocation,
            size: chunk.capacity,
            usage: .transferDestination)
        chunkBufferIDs[key] = id
        return id
    }

    func submit(_ submit: PlannedSubmit, completion: @escaping () -> Void) throws {
        // Reject prototype paths before recording anything or updating GPU
        // state. No accepted command may be silently skipped by this backend.
        for command in submit.commands {
            switch command {
            case .renderPass, .computePass, .accelerationStructureBuild:
                throw RHIError.unsupportedFeature("Vulkan pass encoding is still a prototype")
            case .copyPass(let record):
                for item in record.body {
                    if case .copyBuffer = item { continue }
                    throw RHIError.unsupportedFeature("Vulkan recorded texture copies are not implemented")
                }
            case .barriers: break
            }
        }
        let queue: VkQueue
        switch submit.queue {
        case .graphics: queue = context.graphicsQueue
        case .compute: queue = context.computeQueue
        case .transfer: queue = context.transferQueue
        }

        // Per-frame command buffer from this slot's pool.
        let frame = frames[activeSlot]
        var cmd: VkCommandBuffer = vkNull()
        var allocInfo = VkCommandBufferAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocInfo.commandPool = frame.commandPool
        allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocInfo.commandBufferCount = 1
        guard context.resources.allocateCommandBuffers(context.device, &allocInfo, &cmd) == VK_SUCCESS else {
            throw RHIError.submitFailed("vkAllocateCommandBuffers failed")
        }

        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = UInt32(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        guard draw.beginCommandBuffer(cmd, &begin) == VK_SUCCESS else {
            throw RHIError.submitFailed("vkBeginCommandBuffer failed")
        }
        try encode(cmd: cmd, commands: submit.commands)
        guard draw.endCommandBuffer(cmd) == VK_SUCCESS else {
            throw RHIError.submitFailed("vkEndCommandBuffer failed")
        }

        // Resolve timeline semaphores (create on first use).
        let waitTimeline = try submit.waitSemaphores.map { try semaphore(for: $0) }
        let signalTimeline = try submit.signalSemaphores.map { try semaphore(for: $0) }

        guard let fence = vkWithOutHandle({ out in
            var info = VkFenceCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
            context.sync.createFence(context.device, &info, nil, out)
        }) else { throw RHIError.outOfMemory }

        let result = withSubmissionInfo(command: cmd, waits: waitTimeline, signals: signalTimeline) {
            sync.queueSubmit(queue, 1, $0, fence)
        }
        guard result == VK_SUCCESS else {
            sync.destroyFence(context.device, fence, nil)
            throw RHIError.submitFailed("vkQueueSubmit failed: \(result)")
        }

        // Asynchronous completion: wait on a background thread, then fire the
        // callback. No queue idle on the hot path.
        let waiter = VulkanFenceCompletion(context: context, fence: fence, completion: completion)
        DispatchQueue.global().async { waiter.wait() }
    }

    // MARK: Swapchain

    func acquireSwapchainImage() throws -> SwapchainImage {
        guard let swapchain = swapchain else {
            throw RHIError.swapchainAcquireFailed("no swapchain configured")
        }
        let frame = frames[activeSlot]
        let result = swapchain.acquire(semaphore: frame.acquireSemaphore, timeout: UInt64.max)
        if result.result == VK_ERROR_OUT_OF_DATE_KHR || result.result == VK_SUBOPTIMAL_KHR {
            try swapchain.recreate(registries: registries)
            let retry = swapchain.acquire(semaphore: frame.acquireSemaphore, timeout: UInt64.max)
            guard retry.result == VK_SUCCESS else {
                throw RHIError.swapchainAcquireFailed("recreate acquire failed: \(retry.result)")
            }
            return makeSwapchainImage(swapchain: swapchain, index: retry.index)
        }
        guard result.result == VK_SUCCESS else {
            throw RHIError.swapchainAcquireFailed("vkAcquireNextImageKHR: \(result.result)")
        }
        return makeSwapchainImage(swapchain: swapchain, index: result.index)
    }

    func present(_ image: SwapchainImage) throws {
        guard let swapchain = swapchain else {
            throw RHIError.presentFailed("no swapchain configured")
        }
        let index = swapchain.textureIDs.firstIndex(of: image.texture.id) ?? 0
        let frame = frames[activeSlot]
        let result = swapchain.present(queue: context.graphicsQueue,
                                       semaphore: frame.acquireSemaphore, index: UInt32(index))
        if result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR {
            try swapchain.recreate(registries: registries)
        } else if result != VK_SUCCESS {
            throw RHIError.presentFailed("vkQueuePresentKHR: \(result)")
        }
    }

    private func makeSwapchainImage(swapchain: VulkanSwapchain, index: UInt32) -> SwapchainImage {
        let textureID = swapchain.textureIDs[Int(index)]
        return SwapchainImage(texture: Texture(id: textureID),
                              width: Int(swapchain.extent.width),
                              height: Int(swapchain.extent.height))
    }

    // MARK: Synchronization

    func waitUntilIdle() throws {
        let result = context.instanceCommands.deviceWaitIdle(context.device)
        guard result == VK_SUCCESS else {
            throw RHIError.submitFailed("vkDeviceWaitIdle failed: \(result)")
        }
    }

    // MARK: Timeline semaphores

    private struct TimelineEntry {
        let semaphore: VkSemaphore
        let value: UInt64
    }

    /// All C pointers remain inside their Swift storage's valid lifetime.
    private func withSubmissionInfo<Result>(
        command: VkCommandBuffer,
        waits: [TimelineEntry],
        signals: [TimelineEntry],
        _ body: (UnsafePointer<VkSubmitInfo>) -> Result
    ) -> Result {
        let waitValues = waits.map(\.value)
        let signalValues = signals.map(\.value)
        let waitHandles: [VkSemaphore?] = waits.map(\.semaphore)
        let signalHandles: [VkSemaphore?] = signals.map(\.semaphore)
        let stages = waits.map { _ in VkPipelineStageFlags(VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue) }
        var commandHandle: VkCommandBuffer? = command
        return waitValues.withUnsafeBufferPointer { waitValuePointer in
            signalValues.withUnsafeBufferPointer { signalValuePointer in
                waitHandles.withUnsafeBufferPointer { waitHandlePointer in
                    signalHandles.withUnsafeBufferPointer { signalHandlePointer in
                        stages.withUnsafeBufferPointer { stagePointer in
                            withUnsafePointer(to: &commandHandle) { commandPointer in
                                var timeline = VkTimelineSemaphoreSubmitInfo()
                                timeline.sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO
                                timeline.waitSemaphoreValueCount = UInt32(waits.count)
                                timeline.pWaitSemaphoreValues = waitValuePointer.baseAddress
                                timeline.signalSemaphoreValueCount = UInt32(signals.count)
                                timeline.pSignalSemaphoreValues = signalValuePointer.baseAddress
                                return withUnsafePointer(to: &timeline) { timelinePointer in
                                    var info = VkSubmitInfo()
                                    info.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                                    info.pNext = UnsafeRawPointer(timelinePointer)
                                    info.waitSemaphoreCount = UInt32(waits.count)
                                    info.pWaitSemaphores = waitHandlePointer.baseAddress
                                    info.pWaitDstStageMask = stagePointer.baseAddress
                                    info.signalSemaphoreCount = UInt32(signals.count)
                                    info.pSignalSemaphores = signalHandlePointer.baseAddress
                                    info.commandBufferCount = 1
                                    info.pCommandBuffers = commandPointer
                                    return withUnsafePointer(to: &info, body)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func semaphore(for timeline: TimelineSemaphore) throws -> TimelineEntry {
        if let existing = timelineSemaphores[timeline.id] {
            return TimelineEntry(semaphore: existing, value: timeline.value)
        }
        var typeInfo = VkSemaphoreTypeCreateInfo()
        typeInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO
        typeInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE
        typeInfo.initialValue = 0
        var createInfo = VkSemaphoreCreateInfo()
        createInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        createInfo.pNext = withUnsafeMutablePointer(to: &typeInfo) { UnsafeRawPointer($0) }
        guard let semaphore = vkWithOutHandle({
            context.sync.createSemaphore(context.device, &createInfo, nil, $0)
        }) else {
            throw RHIError.outOfMemory
        }
        timelineSemaphores[timeline.id] = semaphore
        return TimelineEntry(semaphore: semaphore, value: timeline.value)
    }

    // MARK: Upload chunk factory

    private static func makeUploadChunk(context: VulkanContext,
                                        allocator: VulkanMemoryAllocator,
                                        size: Int) throws -> VulkanUploadChunk {
        var info = VkBufferCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        info.size = VkDeviceSize(size)
        info.usage = UInt32(VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue)
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        guard let buffer = vkWithOutHandle({
            context.core.createBuffer(context.device, &info, nil, $0)
        }) else { throw RHIError.outOfMemory }
        var req = VkMemoryRequirements()
        context.core.getBufferMemoryRequirements(context.device, buffer, &req)
        let allocation = try allocator.allocate(
            size: req.size, alignment: req.alignment,
            memoryTypeBits: req.memoryTypeBits,
            requiredFlags: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue
                | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue))
        _ = context.core.bindBufferMemory(context.device, buffer, allocation.memory, allocation.offset)
        return VulkanUploadChunk(buffer: buffer, allocation: allocation, capacity: size)
    }
}

#endif // canImport(CVulkanHeaders)
