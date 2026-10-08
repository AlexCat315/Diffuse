import CDX12Bridge
import Foundation

final class DX12UploadChunk: UploadRingChunk {
    let capacity: Int
    let handle: Buffer
    private let pointer: UnsafeMutableRawPointer
    init(capacity: Int, handle: Buffer) {
        self.capacity = capacity; self.handle = handle
        pointer = .allocate(byteCount: capacity, alignment: 256)
    }
    deinit { pointer.deallocate() }
    func cpuPointer() -> UnsafeMutableRawPointer { pointer }
}
final class DX12FrameUploader: FrameUploader {
    private unowned let backend: DX12Device
    private let allocator: ChunkUploadAllocator<DX12UploadChunk>
    init(backend: DX12Device) {
        self.backend = backend
        allocator = ChunkUploadAllocator { [unowned backend] size in
            let handle = Buffer(id: backend.nextInternalID); backend.nextInternalID += 1
            let usage: BufferUsage = [.uniform, .storageRead, .vertex, .index, .indirect, .transferSource]
            try backend.check(grhi_dx12_buffer(backend.native, handle.id, UInt64(size), usage.rawValue, 1))
            backend.resources.buffers[handle.id] = BufferDescriptor(size: size, usage: usage)
            return DX12UploadChunk(capacity: size, handle: handle)
        }
    }
    func reset() { allocator.reset() }
    func write(_ data: Data, alignment: Int) throws -> UploadLocation {
        let allocation = try allocator.write(data, alignment: max(256, alignment))
        try backend.check(grhi_dx12_upload_buffer(backend.native, allocation.chunk.handle.id, UInt64(allocation.offset), allocation.pointer, data.count))
        return UploadLocation(buffer: allocation.chunk.handle, offset: allocation.offset)
    }
}
