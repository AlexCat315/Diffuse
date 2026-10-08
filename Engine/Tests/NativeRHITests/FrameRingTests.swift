// NativeRHITests — FrameRing: slot reuse, deferred retirement, and completion
// gating across one or more command buffers.

import XCTest
@testable import NativeRHI

final class FrameRingTests: XCTestCase {
    func testRetireRunsImmediatelyWithoutActiveFrame() {
        let ring = FrameRing(slotCount: 1)
        var ran = false
        ring.retireCurrent { ran = true }
        XCTAssertTrue(ran)
    }

    func testRetireDeferredUntilCommandBufferCompletes() {
        let ring = FrameRing(slotCount: 1)
        let slot = ring.begin()
        XCTAssertEqual(slot.index, 0)

        ring.registerCommandBuffer(slotIndex: slot.index)
        var retired = false
        ring.retireCurrent { retired = true }
        XCTAssertFalse(retired)

        ring.end()
        ring.commandBufferCompleted(slotIndex: slot.index)
        ring.waitUntilIdle()
        XCTAssertTrue(retired)
    }

    func testRetireWaitsForAllCommandBuffers() {
        let ring = FrameRing(slotCount: 1)
        let slot = ring.begin()

        ring.registerCommandBuffer(slotIndex: slot.index)
        ring.registerCommandBuffer(slotIndex: slot.index)
        var retired = false
        ring.retireCurrent { retired = true }

        ring.commandBufferCompleted(slotIndex: slot.index)
        XCTAssertFalse(retired)
        ring.end()
        ring.commandBufferCompleted(slotIndex: slot.index)
        ring.waitUntilIdle()
        XCTAssertTrue(retired)
    }

    func testCompletionBeforeEndDoesNotRetireOrCloseFrame() {
        let ring = FrameRing(slotCount: 1)
        let slot = ring.begin()
        var retired = false
        ring.registerCommandBuffer(slotIndex: slot.index)
        ring.retireCurrent { retired = true }
        ring.commandBufferCompleted(slotIndex: slot.index)
        XCTAssertTrue(slot.inFlight)
        XCTAssertFalse(retired)
        ring.registerCommandBuffer(slotIndex: slot.index)
        ring.end()
        XCTAssertFalse(retired)
        ring.commandBufferCompleted(slotIndex: slot.index)
        ring.waitUntilIdle()
        XCTAssertTrue(retired)
    }

    func testEmptyFramesCanBeReusedRepeatedly() {
        let ring = FrameRing(slotCount: 1)
        for _ in 0..<100 {
            ring.begin()
            ring.end()
            ring.waitUntilIdle()
        }
        XCTAssertEqual(ring.completedFrames, 100)
    }

    func testRetirementWaitsForPriorFramesOnOtherQueues() {
        let ring = FrameRing(slotCount: 2)
        let prior = ring.begin()
        ring.registerCommandBuffer(slotIndex: prior.index)
        ring.end()
        let current = ring.begin()
        ring.registerCommandBuffer(slotIndex: current.index)
        var retired = false
        ring.retireCurrent { retired = true }
        ring.end()
        ring.commandBufferCompleted(slotIndex: current.index)
        XCTAssertFalse(retired)
        ring.commandBufferCompleted(slotIndex: prior.index)
        ring.waitUntilIdle()
        XCTAssertTrue(retired)
    }

    func testSlotsCycleAfterCompletion() {
        let ring = FrameRing(slotCount: 2)
        let slot0 = ring.begin()
        ring.end()
        let slot1 = ring.begin()
        XCTAssertEqual(slot0.index, 0)
        XCTAssertEqual(slot1.index, 1)

        ring.end()

        let slot2 = ring.begin()
        XCTAssertEqual(slot2.index, 0)
    }

    func testUnregisterBalancesFailedRegistration() {
        let ring = FrameRing(slotCount: 1)
        let slot = ring.begin()
        ring.registerCommandBuffer(slotIndex: slot.index)
        ring.unregisterCommandBuffer(slotIndex: slot.index)
        ring.end()
        ring.waitUntilIdle()
        // Registration count is back to zero; the slot is still in flight but
        // completing is not required. No assertion beyond not trapping.
    }
}
