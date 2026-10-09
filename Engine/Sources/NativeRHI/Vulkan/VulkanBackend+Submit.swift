// NativeRHI Vulkan — per-frame state, submission, timeline semaphores, and
// swapchain acquire/present. There is no vkQueueWaitIdle on the submit path:
// each submit gets its own fence, the GPU work is queued, and completion fires
// from a background waiter. Acquired images are recycled from a fixed pool.

#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

/// Per-slot frames-in-flight state: command pools and upload storage. Each
/// window owns its acquire semaphores. A command pool resets only when its slot begins
/// a new frame (the FrameRing has already confirmed the GPU finished the old one).
final class VulkanFrame {
    let index: Int
    let uploader: VulkanFrameUploader
    var commandPools: [UInt32: VkCommandPool] = [:]

    init(index: Int, uploader: VulkanFrameUploader) {
        self.index = index; self.uploader = uploader
    }
}

/// A one-shot worker owns the fence until cleanup and callback finish. Native
/// handles are immutable here; no registry or queue mutation occurs off-thread.
private final class VulkanFenceCompletion: @unchecked Sendable {
    private let backend: VulkanBackend
    private var context: VulkanContext { backend.context }
    private let fence: VkFence
    private let commandPool: VkCommandPool?
    private let completion: () -> Void

    init(backend: VulkanBackend, fence: VkFence, commandPool: VkCommandPool? = nil, completion: @escaping () -> Void) {
        self.backend = backend
        self.fence = fence
        self.commandPool = commandPool
        self.completion = completion
    }

    func wait() {
        var fenceSlot = fence
        let result = context.sync.waitForFences(context.device, 1, &fenceSlot, VK_TRUE, UInt64.max)
        if result != VK_SUCCESS { backend.submissionStatus.record("vkWaitForFences failed: \(result)") }
        context.sync.destroyFence(context.device, fence, nil)
        if let commandPool { context.auxiliary.destroyCommandPool(context.device, commandPool, nil) }
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
    func makeFrameUploader(slot: Int) throws -> FrameUploader {
        try lock.withLock {
            try submissionStatus.check()
            activeSlot = slot
            if slot < frames.count {
                let frame = frames[slot]
                for pool in frame.commandPools.values {
                    try rhiRequire(draw.resetCommandPool(context.device, pool, 0) == VK_SUCCESS, "vkResetCommandPool failed")
                }
                frame.uploader.reset()
                return frame.uploader
            }
            let uploader = VulkanFrameUploader(backend: self) { [context, allocator] capacity in
                try Self.makeUploadChunk(context: context, allocator: allocator, size: capacity)
            }
            frames.append(VulkanFrame(index: slot, uploader: uploader))
            return uploader
        }
    }

    private func commandPool(frame: VulkanFrame, family: UInt32) throws -> VkCommandPool {
        if let existing = frame.commandPools[family] { return existing }
        var info = VkCommandPoolCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        info.queueFamilyIndex = family
        info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue
        guard let pool = vkWithOutHandle({ _ = context.resources.createCommandPool(context.device, &info, nil, $0) }) else { throw RHIError.outOfMemory }
        frame.commandPools[family] = pool
        return pool
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
            usage: [.transferSource, .transferDestination, .uniform, .storageRead, .vertex, .index, .indirect])
        chunkBufferIDs[key] = id
        return id
    }

    func submit(_ submit: PlannedSubmit, completion: @escaping () -> Void) throws {
        try submissionStatus.check()
        let nativeQueue: VulkanQueue
        switch submit.queue {
        case .graphics: nativeQueue = context.queues.graphics
        case .compute: nativeQueue = context.queues.compute
        case .transfer: nativeQueue = context.queues.transfer
        }

        // Per-frame command buffer from this slot's pool.
        let frame = frames[activeSlot]
        var cmd: VkCommandBuffer = vkNull()
        var allocInfo = VkCommandBufferAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocInfo.commandPool = try commandPool(frame: frame, family: nativeQueue.family)
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
        let previousTextures = registries.textures
        do {
            try encode(cmd: cmd, commands: submit.commands)
        } catch {
            registries.textures = previousTextures
            throw error
        }
        var queued = false
        defer { if !queued { registries.textures = previousTextures } }
        guard draw.endCommandBuffer(cmd) == VK_SUCCESS else {
            throw RHIError.submitFailed("vkEndCommandBuffer failed")
        }

        // Resolve timeline semaphores (create on first use).
        var waitTimeline = try submit.waitSemaphores.map { try semaphore(for: $0) }
        let acquisitions = submit.queue == .graphics ? swapchains.values.filter { $0.presentation.pendingAcquire } : []
        for window in acquisitions {
            guard let semaphore = window.acquireSemaphores[activeSlot] else { throw RHIError.submitFailed("acquire semaphore is missing") }
            waitTimeline.append(TimelineEntry(semaphore: semaphore, value: 0))
        }
        let signalTimeline = try submit.signalSemaphores.map { try semaphore(for: $0) }

        guard let fence = vkWithOutHandle({ out in
            var info = VkFenceCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
            context.sync.createFence(context.device, &info, nil, out)
        }) else { throw RHIError.outOfMemory }

        let result = withSubmissionInfo(command: cmd, waits: waitTimeline, signals: signalTimeline) {
            sync.queueSubmit(nativeQueue.handle, 1, $0, fence)
        }
        guard result == VK_SUCCESS else {
            sync.destroyFence(context.device, fence, nil)
            throw RHIError.submitFailed("vkQueueSubmit failed: \(result)")
        }

        queued = true
        for window in acquisitions { window.presentation.pendingAcquire = false }
        // Asynchronous completion: wait on a background thread, then fire the
        // callback. No queue idle on the hot path.
        let waiter = VulkanFenceCompletion(backend: self, fence: fence, completion: completion)
        DispatchQueue.global().async { waiter.wait() }
    }

    // MARK: Swapchain

    func acquireSwapchainImage(_ handle: Swapchain) throws -> SwapchainImage {
        guard let window = swapchains[handle.id], activeSlot < frames.count else { throw RHIError.swapchainAcquireFailed("configure a swapchain and begin a frame first") }
        let swapchain = window.chain
        if window.needsRecreate { try recreateWindowSwapchain(window) }
        try rhiRequire(window.presentation.acquiredID == nil, "present the acquired image before acquiring another")
        if window.acquireSemaphores[activeSlot] == nil { window.acquireSemaphores[activeSlot] = try binarySemaphore() }
        let semaphore = window.acquireSemaphores[activeSlot]!
        var result = swapchain.acquire(semaphore: semaphore, timeout: UInt64.max)
        if result.result == VK_ERROR_OUT_OF_DATE_KHR {
            try recreateWindowSwapchain(window)
            result = swapchain.acquire(semaphore: semaphore, timeout: UInt64.max)
        }
        guard result.result == VK_SUCCESS || result.result == VK_SUBOPTIMAL_KHR else {
            throw RHIError.swapchainAcquireFailed("vkAcquireNextImageKHR: \(result.result)")
        }
        let image = makeSwapchainImage(handle: handle, window: window, index: result.index)
        window.presentation.acquiredID = image.texture.id; window.presentation.pendingAcquire = true
        return image
    }

    func present(_ image: SwapchainImage, completion: @escaping () -> Void) throws {
        guard let window = swapchains[image.swapchain.id], window.generation == image.generation,
              window.presentation.acquiredID == image.texture.id,
              let index = window.chain.textureIDs.firstIndex(of: image.texture.id) else { throw RHIError.presentFailed("image was not acquired from this swapchain") }
        let ready: VkSemaphore
        if let existing = window.presentation.ready[image.texture.id] { ready = existing }
        else { ready = try binarySemaphore(); window.presentation.ready[image.texture.id] = ready }
        // Presentation owns an independent pool; a frame slot may complete and
        // reset its pools before the final transition/present wait has finished.
        let transient = VulkanFrame(index: -1, uploader: frames[activeSlot].uploader)
        let pool = try commandPool(frame: transient, family: context.queues.graphics.family)
        var submitted = false
        defer { if !submitted { context.auxiliary.destroyCommandPool(context.device, pool, nil) } }
        var cmd: VkCommandBuffer = vkNull()
        var allocation = VkCommandBufferAllocateInfo()
        allocation.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocation.commandPool = pool; allocation.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; allocation.commandBufferCount = 1
        try rhiRequire(context.resources.allocateCommandBuffers(context.device, &allocation, &cmd) == VK_SUCCESS, "present command allocation failed")
        var begin = VkCommandBufferBeginInfo(); begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        try rhiRequire(draw.beginCommandBuffer(cmd, &begin) == VK_SUCCESS, "present command begin failed")
        let previous = registries.textures[image.texture.id]!
        try transitionTexture(cmd: cmd, handle: image.texture, state: .present)
        defer { if !submitted { registries.textures[image.texture.id] = previous } }
        try rhiRequire(draw.endCommandBuffer(cmd) == VK_SUCCESS, "present command end failed")
        guard let fence = vkWithOutHandle({ out in
            var info = VkFenceCreateInfo(); info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
            _ = sync.createFence(context.device, &info, nil, out)
        }) else { throw RHIError.outOfMemory }
        let waits: [TimelineEntry] = window.presentation.pendingAcquire ? [TimelineEntry(semaphore: window.acquireSemaphores[activeSlot]!, value: 0)] : []
        let result = withSubmissionInfo(command: cmd, waits: waits, signals: [TimelineEntry(semaphore: ready, value: 0)]) {
            sync.queueSubmit(context.queues.graphics.handle, 1, $0, fence)
        }
        guard result == VK_SUCCESS else { sync.destroyFence(context.device, fence, nil); throw RHIError.presentFailed("present transition submit failed: \(result)") }
        submitted = true; window.presentation.pendingAcquire = false; window.presentation.acquiredID = nil
        let waiter = VulkanFenceCompletion(backend: self, fence: fence, commandPool: pool, completion: completion)
        DispatchQueue.global().async { waiter.wait() }
        let status = window.chain.present(queue: context.queues.graphics.handle, semaphore: ready, index: UInt32(index))
        if status == VK_ERROR_OUT_OF_DATE_KHR || status == VK_SUBOPTIMAL_KHR { window.needsRecreate = true }
        else if status != VK_SUCCESS { submissionStatus.record("vkQueuePresentKHR: \(status)") }
    }

    private func binarySemaphore() throws -> VkSemaphore {
        var info = VkSemaphoreCreateInfo(); info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        guard let semaphore = vkWithOutHandle({ _ = sync.createSemaphore(context.device, &info, nil, $0) }) else { throw RHIError.outOfMemory }
        return semaphore
    }

    private func makeSwapchainImage(handle: Swapchain, window: VulkanWindowSwapchain, index: UInt32) -> SwapchainImage {
        let chain = window.chain
        return SwapchainImage(swapchain: handle, generation: window.generation, texture: Texture(id: chain.textureIDs[Int(index)]),
                              width: Int(chain.extent.width), height: Int(chain.extent.height))
    }

    private func recreateWindowSwapchain(_ window: VulkanWindowSwapchain) throws {
        try waitUntilIdle()
        for semaphore in window.presentation.ready.values { sync.destroySemaphore(context.device, semaphore, nil) }
        window.presentation = VulkanPresentationState()
        try window.chain.recreate(registries: registries)
        window.generation += 1; window.needsRecreate = false
    }

    // MARK: Synchronization

    func waitUntilIdle() throws {
        let result = context.instanceCommands.deviceWaitIdle(context.device)
        guard result == VK_SUCCESS else {
            throw RHIError.submitFailed("vkDeviceWaitIdle failed: \(result)")
        }
        try submissionStatus.check()
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
        let arena = VulkanScratch()
        createInfo.pNext = UnsafeRawPointer(arena.make(typeInfo))
        guard let semaphore: VkSemaphore = withExtendedLifetime(arena, { vkWithOutHandle({
            _ = context.sync.createSemaphore(context.device, &createInfo, nil, $0)
        }) }) else {
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
        info.usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue
            | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue
            | VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT.rawValue
        let arena = VulkanScratch()
        let families = Array(Set([context.queues.graphics.family, context.queues.compute.family, context.queues.transfer.family]))
        info.sharingMode = families.count > 1 ? VK_SHARING_MODE_CONCURRENT : VK_SHARING_MODE_EXCLUSIVE
        if families.count > 1 { info.queueFamilyIndexCount = UInt32(families.count); info.pQueueFamilyIndices = arena.store(families) }
        guard let buffer: VkBuffer = withExtendedLifetime(arena, { vkWithOutHandle({
            _ = context.core.createBuffer(context.device, &info, nil, $0)
        }) }) else { throw RHIError.outOfMemory }
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
