// NativeRHI Metal backend — chunked upload ring.
//
// Each frames-in-flight slot owns a `ChunkUploadAllocator` whose chunks wrap a
// shared-storage `MTLBuffer`. Suballocations stay alive for exactly the frame
// that uses them (the slot is only reset after its GPU work completes), so
// there is no per-upload staging alloc + commit + wait on the hot path.

#if os(macOS)
import Metal

/// A chunk of GPU-visible upload storage: a shared-storage `MTLBuffer` plus
/// the `Buffer` handle it is registered under (so the frontend can bind it).
final class MetalUploadChunk: UploadRingChunk {
    let buffer: MTLBuffer
    let bufferHandle: Buffer
    let capacity: Int

    init(buffer: MTLBuffer, handle: Buffer) {
        self.buffer = buffer
        self.bufferHandle = handle
        self.capacity = buffer.length
    }

    func cpuPointer() -> UnsafeMutableRawPointer {
        buffer.contents()
    }
}

/// Per-frame uploader vended to the frontend. Wraps a
/// `ChunkUploadAllocator<MetalUploadChunk>` and translates allocations into
/// `UploadLocation`s the frontend can bind directly.
final class MetalFrameUploader: FrameUploader {
    private let allocator: ChunkUploadAllocator<MetalUploadChunk>

    init(chunkSize: Int, makeChunk: @escaping (Int) throws -> MetalUploadChunk) {
        self.allocator = ChunkUploadAllocator(defaultChunkSize: chunkSize, factory: makeChunk)
    }

    func reset() {
        allocator.reset()
    }

    func write(_ data: Data, alignment: Int) throws -> UploadLocation {
        try data.withUnsafeBytes { try write($0, alignment: alignment) }
    }

    /// Zero-copy fast path: copies the caller's memory straight into ring
    /// storage without building an intermediate `Data`.
    func write(_ bytes: UnsafeRawBufferPointer, alignment: Int) throws -> UploadLocation {
        let allocation = try allocator.write(bytes, alignment: alignment)
        return UploadLocation(buffer: allocation.chunk.bufferHandle, offset: allocation.offset)
    }
}

#endif
