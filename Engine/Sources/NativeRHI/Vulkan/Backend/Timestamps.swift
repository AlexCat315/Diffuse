#if (os(Windows) || os(Linux) || os(Android)) && canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

/// A retired timestamp query pool plus what is needed to turn it into markers.
/// Held by the fence completion until the GPU signals, then read exactly once.
struct VulkanTimestampRecording {
    let pool: VkQueryPool
    let queryCount: UInt32
    let labels: [String]
    let profile: GPUTimestampProfile
    /// Driver supplied nanoseconds per timestamp tick.
    let period: Double
}

extension VulkanBackend: GPUTimestampRecording {
    /// Ticks are only meaningful with a period; drivers report nanoseconds.
    var gpuTimestampNanosecondsPerTick: Double { Double(context.limits.timestampPeriod) }

    /// Two queries per recorded command.
    private static let slotQueryCapacity: Int = 256

    private var canTimestamp: Bool {
        gpuTimestampProfile != nil && gpuTimestampNanosecondsPerTick > 0
    }

    /// Resets this slot's pool and prepares it for `markerCount` markers.
    /// Returns `nil` when profiling is off, the period is unusable, or the slot
    /// cannot hold this many markers.
    func beginGPUTimestamps(cmd: VkCommandBuffer, markerCount: Int,
                            labels: [String]) -> VulkanTimestampRecording? {
        guard let profile = gpuTimestampProfile else { return nil }
        let period = gpuTimestampNanosecondsPerTick
        guard period > 0 else {
            profile.note("unusable timestampPeriod=\(period)")
            return nil
        }
        guard markerCount > 0 else {
            profile.note("submission had no commands")
            return nil
        }
        let queryCount = markerCount * 2
        guard queryCount <= Self.slotQueryCapacity else {
            profile.note("submission needs \(queryCount) queries, capacity \(Self.slotQueryCapacity)")
            return nil
        }
        guard activeSlot < frames.count else {
            profile.note("frame slot \(activeSlot) is not set up")
            return nil
        }
        guard let pool = timestampPool(for: frames[activeSlot]) else {
            let frame = frames[activeSlot]
            profile.note("vkCreateQueryPool -> \(frame.queryPoolFailure.rawValue)"
                + " (handle nil: \(frame.queryPoolHandleWasNil))")
            return nil
        }
        profile.note("recording \(queryCount) queries over \(markerCount) passes")
        draw.cmdResetQueryPool(cmd, pool, 0, UInt32(queryCount))
        return VulkanTimestampRecording(pool: pool, queryCount: UInt32(queryCount), labels: labels,
                                        profile: profile, period: period)
    }

    /// Per-frame-slot pool, created on first use and kept for the slot's life so
    /// steady-state sampling performs no allocation.
    private func timestampPool(for frame: VulkanFrame) -> VkQueryPool? {
        if let existing = frame.queryPool { return existing }
        var info = VkQueryPoolCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO
        info.queryType = VkQueryType(VK_QUERY_TYPE_TIMESTAMP.rawValue)
        info.queryCount = UInt32(Self.slotQueryCapacity)
        // `createQueryPool` wants `UnsafeMutablePointer<VkQueryPool?>`, which is
        // exactly the pointer a `VkQueryPool?` storage yields. Going through
        // `vkWithOutHandle` instead would rebind an `Optional<Optional<>>` onto
        // the same eight bytes and lose the handle.
        var storage: VkQueryPool?
        let result = withUnsafeMutablePointer(to: &storage) { pointer in
            context.resources.createQueryPool(context.device, &info, nil, pointer)
        }
        frame.queryPoolFailure = result
        frame.queryPoolHandleWasNil = storage == nil
        guard let pool = storage else { return nil }
        frame.queryPool = pool
        return pool
    }

    /// Writes one timestamp and the barrier that makes it visible to later work.
    /// The spec's query-pool pattern: an empty memory dependency scoped to the
    /// host so the write is ordered and readable, without gating device memory.
    private func writeTimestamp(cmd: VkCommandBuffer, recording: VulkanTimestampRecording,
                                stage: VkPipelineStageFlagBits, query: UInt32) {
        draw.cmdWriteTimestamp(cmd, stage, recording.pool, query)
        var barrier = VkMemoryBarrier()
        barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
        barrier.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT.rawValue
        barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT.rawValue
        let host = VkPipelineStageFlags(VK_PIPELINE_STAGE_HOST_BIT.rawValue)
        draw.cmdPipelineBarrier(cmd, host, host, 0, 1, &barrier, 0, nil, 0, nil)
    }

    func writeGPUTimestampBegin(cmd: VkCommandBuffer, recording: VulkanTimestampRecording, query: UInt32) {
        writeTimestamp(cmd: cmd, recording: recording,
                       stage: VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, query: query)
    }

    func writeGPUTimestampEnd(cmd: VkCommandBuffer, recording: VulkanTimestampRecording, query: UInt32) {
        writeTimestamp(cmd: cmd, recording: recording,
                       stage: VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, query: query)
    }

    /// Turns a completed submission's query pool into profile markers.
    ///
    /// Runs on the fence waiter once the GPU signalled. The pool is already
    /// retired, so the results are final; a query the driver could not resolve is
    /// skipped rather than reported as zero, so an unfinished marker is absent
    /// instead of silently fast.
    func recordGPUTimestamps(_ recording: VulkanTimestampRecording) {
        let count = Int(recording.queryCount)
        let byteStride = MemoryLayout<UInt64>.stride
        var raw = [UInt64](repeating: 0, count: count)
        let status = raw.withUnsafeMutableBytes { bytes in
            context.resources.getQueryPoolResults(
                context.device, recording.pool, 0, recording.queryCount,
                byteStride * count, bytes.baseAddress, VkDeviceSize(byteStride),
                VkQueryResultFlags(VK_QUERY_RESULT_64_BIT.rawValue | VK_QUERY_RESULT_WAIT_BIT.rawValue))
        }
        guard status == VK_SUCCESS else {
            recording.profile.note("vkGetQueryPoolResults returned \(status)")
            return
        }
        let labels = recording.labels
        var usable = 0
        raw.withUnsafeBufferPointer { buffer in
            for query in stride(from: 0, to: count, by: 2) {
                let start = buffer[query], end = buffer[query + 1]
                // Drivers may leave a zero or non-advancing pair when a marker
                // straddles a context switch.
                guard start != 0, end > start else { continue }
                let elapsed = (Double(end - start) * recording.period).rounded()
                guard elapsed > 0 else { continue }
                let index = query / 2
                let label = index < labels.count ? labels[index] : "pass#\(index)"
                recording.profile.append(GPUTimestampProfile.Marker(label: label, nanoseconds: UInt64(elapsed)))
                usable += 1
            }
        }
        recording.profile.note(usable == 0 ? "queries returned no advancing pair" : "ok")
    }
}
#endif
