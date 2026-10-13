// NativeRHITests — ChunkUploadAllocator: suballocation, alignment, chunk
// growth, and reset-at-slot-reuse.

import XCTest
@testable import NativeRHI

private final class TestChunk: UploadRingChunk {
    let capacity: Int
    private let backing: UnsafeMutableRawPointer

    init(capacity: Int) {
        self.capacity = capacity
        self.backing = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 256)
    }

    func cpuPointer() -> UnsafeMutableRawPointer { backing }

    deinit { backing.deallocate() }
}

private final class BorrowedBytesUploader: FrameUploader {
    var copied: [UInt8] = []

    func reset() { copied.removeAll() }

    func write(_ data: Data, alignment: Int) throws -> UploadLocation {
        XCTFail("Borrowed bytes must not take the intermediate Data path")
        throw RHIError.outOfMemory
    }

    func write(_ bytes: UnsafeRawBufferPointer, alignment: Int) throws -> UploadLocation {
        copied = Array(bytes)
        return UploadLocation(buffer: Buffer(id: 1), offset: alignment)
    }
}

final class ChunkUploadAllocatorTests: XCTestCase {
    func testBorrowedBytesDispatchToBackendThroughProtocol() throws {
        let backend = BorrowedBytesUploader()
        let uploader: any FrameUploader = backend
        var source: [UInt8] = [17, 29, 41, 53]
        let location = try source.withUnsafeBytes { try uploader.write($0, alignment: 64) }
        source[0] = 99
        XCTAssertEqual(backend.copied, [17, 29, 41, 53])
        XCTAssertEqual(location.offset, 64)
    }

    private func makeAllocator(chunkSize: Int = 1024) -> ChunkUploadAllocator<TestChunk> {
        ChunkUploadAllocator(defaultChunkSize: chunkSize) { TestChunk(capacity: $0) }
    }

    func testFirstAllocationStartsAtZero() throws {
        let allocator = makeAllocator()
        let allocation = try allocator.allocate(size: 100)
        XCTAssertEqual(allocation.offset, 0)
        // The allocator floors chunk size to 64 KiB (see ChunkUploadAllocator.init).
        XCTAssertEqual(allocation.chunk.capacity, 64 * 1_024)
    }

    func testAllocationsRespectAlignment() throws {
        let allocator = makeAllocator()
        _ = try allocator.allocate(size: 100)
        let second = try allocator.allocate(size: 100, alignment: 256)
        XCTAssertEqual(second.offset, 256)
    }

    func testWriteCopiesData() throws {
        let allocator = makeAllocator()
        let data = Data([1, 2, 3, 4])
        let allocation = try allocator.write(data)
        let bytes = [UInt8](UnsafeBufferPointer(
            start: allocation.pointer.assumingMemoryBound(to: UInt8.self),
            count: 4
        ))
        XCTAssertEqual(bytes, [1, 2, 3, 4])
    }

    func testAllocationLargerThanChunkGrowsNewChunk() throws {
        let allocator = makeAllocator(chunkSize: 1024)
        let large = try allocator.allocate(size: 4096)
        XCTAssertGreaterThanOrEqual(large.chunk.capacity, 4096)
        XCTAssertEqual(large.offset, 0)
    }

    func testZeroSizeThrows() {
        let allocator = makeAllocator()
        XCTAssertThrowsError(try allocator.allocate(size: 0))
    }

    func testResetReturnsAllocationsToZero() throws {
        let allocator = makeAllocator()
        _ = try allocator.allocate(size: 500)
        allocator.reset()
        let after = try allocator.allocate(size: 100)
        XCTAssertEqual(after.offset, 0)
    }
}
