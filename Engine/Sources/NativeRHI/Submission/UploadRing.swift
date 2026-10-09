// NativeRHI — per-frame chunked upload allocator.
//
// This is the production counterpart of upload_ring.zig, which the prototype
// never wired into a backend. Each frame-in-flight slot owns one allocator.
// Chunks are reset when the slot is reused (which only happens after the GPU
// has finished with that slot), so every suballocation is automatically kept
// alive until the frame that uses it completes.

import Foundation

/// Backend-provided chunk of GPU-visible storage. On Metal this wraps a
/// shared-storage `MTLBuffer` whose `contents` pointer is directly writable.
public protocol UploadRingChunk: AnyObject {
    var capacity: Int { get }
    func cpuPointer() -> UnsafeMutableRawPointer
}

public struct UploadAllocation<Chunk: UploadRingChunk> {
    public let chunk: Chunk
    public let offset: Int

    public var pointer: UnsafeMutableRawPointer {
        chunk.cpuPointer().advanced(by: offset)
    }
}

public final class ChunkUploadAllocator<Chunk: UploadRingChunk> {
    private struct Entry {
        let chunk: Chunk
        var used: Int
        var capacity: Int
    }

    private let factory: (Int) throws -> Chunk
    private let defaultChunkSize: Int
    private var entries: [Entry] = []
    private var currentIndex: Int?

    public init(defaultChunkSize: Int = 4 * 1_024 * 1_024, factory: @escaping (Int) throws -> Chunk) {
        self.defaultChunkSize = max(64 * 1_024, defaultChunkSize)
        self.factory = factory
    }

    /// Called when the owning frame slot begins (GPU work from the previous
    /// use of the slot has already been waited on).
    public func reset() {
        for index in entries.indices {
            entries[index].used = 0
        }
        currentIndex = entries.isEmpty ? nil : 0
    }

    public var totalChunkCapacity: Int {
        entries.reduce(0) { $0 + $1.capacity }
    }

    public func allocate(size: Int, alignment: Int = 256) throws -> UploadAllocation<Chunk> {
        guard size > 0 else { throw RHIError.invalidArgument("upload size must be > 0") }
        let alignment = max(1, alignment)

        if let index = currentIndex, let allocation = attempt(index: index, size: size, alignment: alignment) {
            return allocation
        }
        for index in entries.indices where index != currentIndex {
            if let allocation = attempt(index: index, size: size, alignment: alignment) {
                currentIndex = index
                return allocation
            }
        }

        let capacity = max(defaultChunkSize, align(size: size, alignment: alignment))
        let chunk = try factory(capacity)
        guard chunk.capacity >= capacity else {
            throw RHIError.invalidArgument("upload chunk smaller than requested")
        }
        entries.append(Entry(chunk: chunk, used: 0, capacity: chunk.capacity))
        let index = entries.count - 1
        currentIndex = index
        return attempt(index: index, size: size, alignment: alignment)!
    }

    public func write(_ data: Data, alignment: Int = 256) throws -> UploadAllocation<Chunk> {
        let allocation = try allocate(size: data.count, alignment: alignment)
        data.withUnsafeBytes { bytes in
            allocation.pointer.copyMemory(from: bytes.baseAddress!, byteCount: data.count)
        }
        return allocation
    }

    private func attempt(index: Int, size: Int, alignment: Int) -> UploadAllocation<Chunk>? {
        let alignedOffset = align(size: entries[index].used, alignment: alignment)
        let end = alignedOffset + size
        guard end <= entries[index].capacity else { return nil }
        entries[index].used = end
        return UploadAllocation(chunk: entries[index].chunk, offset: alignedOffset)
    }
}

@inlinable
func align(size: Int, alignment: Int) -> Int {
    let alignment = max(1, alignment)
    return ((size + alignment - 1) / alignment) * alignment
}
