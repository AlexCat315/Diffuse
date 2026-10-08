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

final class ChunkUploadAllocatorTests: XCTestCase {
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
