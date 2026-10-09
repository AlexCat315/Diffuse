// NativeRHITests — AccessTracker: same-state RAW/WAR/WAW ordering, range overlap,
// independent reads, and cross-queue hazard attribution.

import XCTest
@testable import NativeRHI

final class AccessTrackerTests: XCTestCase {
    private let buffer = ResourceRef(kind: .buffer, id: 1)
    private let texture = ResourceRef(kind: .texture, id: 2)

    private func access(
        _ resource: ResourceRef, _ kind: AccessKind,
        stage: AccessStage = .compute, range: BufferRange? = nil
    ) -> ResourceAccess {
        ResourceAccess(resource: resource, kind: kind, stage: stage, range: range)
    }

    // MARK: Same-state hazards

    func testWriteAfterWriteIsDetected() {
        var tracker = AccessTracker()
        // Two consecutive storage writes, state unchanged.
        XCTAssertTrue(tracker.observe(access(buffer, .write), on: .graphics).isEmpty)
        let hazards = tracker.observe(access(buffer, .write), on: .graphics)
        XCTAssertEqual(hazards.count, 1)
        XCTAssertEqual(hazards.first?.kind, .writeAfterWrite)
        XCTAssertEqual(hazards.first?.sourceQueue, .graphics)
        XCTAssertEqual(hazards.first?.destinationQueue, .graphics)
    }

    func testWriteAfterReadIsDetected() {
        var tracker = AccessTracker()
        XCTAssertTrue(tracker.observe(access(buffer, .read), on: .graphics).isEmpty)
        let hazards = tracker.observe(access(buffer, .write), on: .graphics)
        XCTAssertEqual(hazards.count, 1)
        XCTAssertEqual(hazards.first?.kind, .writeAfterRead)
    }

    func testReadAfterWriteIsDetected() {
        var tracker = AccessTracker()
        XCTAssertTrue(tracker.observe(access(buffer, .write), on: .compute).isEmpty)
        let hazards = tracker.observe(access(buffer, .read), on: .compute)
        XCTAssertEqual(hazards.count, 1)
        XCTAssertEqual(hazards.first?.kind, .readAfterWrite)
    }

    // MARK: Independent accesses

    func testIndependentReadsProduceNoHazard() {
        var tracker = AccessTracker()
        XCTAssertTrue(tracker.observe(access(buffer, .read), on: .graphics).isEmpty)
        XCTAssertTrue(tracker.observe(access(buffer, .read), on: .graphics).isEmpty)
    }

    func testDifferentResourcesProduceNoHazard() {
        var tracker = AccessTracker()
        let other = ResourceRef(kind: .buffer, id: 9)
        tracker.observe(access(buffer, .write), on: .graphics)
        let hazards = tracker.observe(access(other, .write), on: .graphics)
        XCTAssertTrue(hazards.isEmpty)
    }

    // MARK: Buffer ranges

    func testDisjointRangesProduceNoHazard() {
        var tracker = AccessTracker()
        tracker.observe(
            access(buffer, .write, range: BufferRange(offset: 0, size: 1024)),
            on: .graphics
        )
        let hazards = tracker.observe(
            access(buffer, .write, range: BufferRange(offset: 2048, size: 1024)),
            on: .graphics
        )
        XCTAssertTrue(hazards.isEmpty)
    }

    func testOverlappingRangesProduceHazard() {
        var tracker = AccessTracker()
        tracker.observe(
            access(buffer, .write, range: BufferRange(offset: 0, size: 1024)),
            on: .graphics
        )
        let hazards = tracker.observe(
            access(buffer, .read, range: BufferRange(offset: 512, size: 1024)),
            on: .graphics
        )
        XCTAssertEqual(hazards.first?.kind, .readAfterWrite)
    }

    // MARK: Window pruning

    func testWriteClearsPriorReadWindow() {
        var tracker = AccessTracker()
        // Read, then a write that becomes the new last write and clears reads.
        tracker.observe(access(buffer, .read), on: .graphics)
        tracker.observe(access(buffer, .write), on: .graphics)
        // A subsequent read hazards only against the write, not the stale read.
        let hazards = tracker.observe(access(buffer, .read), on: .graphics)
        XCTAssertEqual(hazards.count, 1)
        XCTAssertEqual(hazards.first?.kind, .readAfterWrite)
    }

    // MARK: Cross-queue

    func testCrossQueueHazardAttributesQueues() {
        var tracker = AccessTracker()
        tracker.observe(access(buffer, .write, stage: .compute), on: .compute)
        let hazards = tracker.observe(access(buffer, .read, stage: .fragment), on: .graphics)
        XCTAssertEqual(hazards.count, 1)
        XCTAssertEqual(hazards.first?.kind, .readAfterWrite)
        XCTAssertEqual(hazards.first?.sourceQueue, .compute)
        XCTAssertEqual(hazards.first?.destinationQueue, .graphics)
        XCTAssertEqual(hazards.first?.sourceStage, .compute)
        XCTAssertEqual(hazards.first?.destinationStage, .fragment)
    }

    func testReadOnlyFramesKeepOneDependencyPerQueueAndRange() {
        var tracker = AccessTracker()
        for _ in 0..<5_000 {
            XCTAssertTrue(tracker.observe(access(buffer, .read, stage: .vertex), on: .graphics).isEmpty)
            XCTAssertTrue(tracker.observe(access(buffer, .read, stage: .fragment), on: .graphics).isEmpty)
        }
        tracker.observe(access(buffer, .read, stage: .compute), on: .compute)
        let hazards = tracker.observe(access(buffer, .write), on: .transfer)
        XCTAssertEqual(hazards.count, 2)
        XCTAssertEqual(hazards.first { $0.sourceQueue == .graphics }?.sourceStage, [.vertex,.fragment])
        XCTAssertEqual(hazards.first { $0.sourceQueue == .compute }?.sourceStage, .compute)
        XCTAssertTrue(hazards.allSatisfy { $0.kind == .writeAfterRead && $0.destinationQueue == .transfer })
    }

    func testCoveredReadsReuseRAWAndPreserveStageUnionForTheNextWrite() {
        var tracker = AccessTracker()
        tracker.observe(access(buffer, .write, stage: .compute), on: .compute)
        for index in 0..<128 {
            let hazards = tracker.observe(access(buffer, .read, stage: .vertex), on: .graphics)
            if index == 0 {
                XCTAssertEqual(hazards.count, 1)
                XCTAssertEqual(hazards.first?.kind, .readAfterWrite)
                XCTAssertEqual(hazards.first?.sourceQueue, .compute)
                XCTAssertEqual(hazards.first?.destinationStage, .vertex)
            } else { XCTAssertTrue(hazards.isEmpty) }
        }
        let expanded = tracker.observe(access(buffer, .read, stage: .fragment), on: .graphics)
        XCTAssertEqual(expanded.first?.kind, .readAfterWrite)
        XCTAssertEqual(expanded.first?.destinationStage, .fragment)
        XCTAssertTrue(tracker.observe(access(buffer, .read, stage: [.vertex, .fragment]), on: .graphics).isEmpty)
        let writes = tracker.observe(access(buffer, .write, stage: .transfer), on: .transfer)
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.first { $0.kind == .writeAfterRead }?.sourceStage, [.vertex, .fragment])
        XCTAssertEqual(writes.first { $0.kind == .writeAfterWrite }?.sourceQueue, .compute)
        for queue in [QueueClass.graphics, .compute] {
            let next = tracker.observe(access(buffer, .read, stage: .fragment), on: queue)
            XCTAssertEqual(next.count, 1)
            XCTAssertEqual(next.first?.sourceQueue, .transfer)
            XCTAssertEqual(next.first?.destinationQueue, queue)
            XCTAssertEqual(next.first?.kind, .readAfterWrite)
        }
    }

    func testResetClearsAllState() {
        var tracker = AccessTracker()
        XCTAssertTrue(tracker.observe(access(texture, .write), on: .graphics).isEmpty)
        XCTAssertFalse(tracker.observe(access(texture, .write), on: .graphics).isEmpty)
        tracker.reset()
        let hazards = tracker.observe(access(texture, .write), on: .graphics)
        XCTAssertTrue(hazards.isEmpty)
    }

    func testReadCoverageDoesNotHideNewRangesQueuesOrImmediateWrites() {
        var tracker = AccessTracker()
        let first = BufferRange(offset: 0, size: 64), second = BufferRange(offset: 64, size: 64)
        tracker.observe(access(buffer, .write, stage: .transfer), on: .graphics)
        XCTAssertEqual(tracker.observe(access(buffer, .read, stage: .vertex, range: first), on: .graphics).count, 1)
        XCTAssertTrue(tracker.observe(access(buffer, .read, stage: .vertex, range: first), on: .graphics).isEmpty)
        XCTAssertEqual(tracker.observe(access(buffer, .read, stage: .vertex, range: second), on: .graphics).count, 1)
        XCTAssertEqual(tracker.observe(access(buffer, .read, stage: .vertex, range: first), on: .compute).count, 1)
        let writes = tracker.observe(access(buffer, .write, stage: .transfer), on: .graphics)
        XCTAssertEqual(writes.filter { $0.kind == .writeAfterRead }.count, 3)
        XCTAssertEqual(tracker.observe(access(buffer, .read, stage: .vertex, range: first), on: .graphics).count, 1)
    }
}
