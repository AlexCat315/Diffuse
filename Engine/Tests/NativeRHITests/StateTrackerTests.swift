// NativeRHITests — StateTracker: barrier emission, merging, and reset.

import XCTest
@testable import NativeRHI

final class StateTrackerTests: XCTestCase {
    private func ref(_ id: UInt32 = 1) -> ResourceRef {
        ResourceRef(kind: .texture, id: id)
    }

    func testFirstRequirementEmitsBarrierFromEmptyState() {
        let tracker = StateTracker()
        tracker.requireState(ref(), .renderTarget)
        let barriers = tracker.commitBarriers()

        XCTAssertEqual(barriers.count, 1)
        XCTAssertEqual(barriers[0].before, [])
        XCTAssertEqual(barriers[0].after, .renderTarget)
    }

    func testRequiringSameStateEmitsNoBarrier() {
        let tracker = StateTracker()
        tracker.setInitialState(ref(), .renderTarget)
        tracker.requireState(ref(), .renderTarget)
        XCTAssertTrue(tracker.commitBarriers().isEmpty)
    }

    func testStateChangeEmitsBarrierWithBeforeAndAfter() {
        let tracker = StateTracker()
        tracker.setInitialState(ref(), .shaderResource)
        tracker.requireState(ref(), .renderTarget)
        let barriers = tracker.commitBarriers()

        XCTAssertEqual(barriers.count, 1)
        XCTAssertEqual(barriers[0].before, .shaderResource)
        XCTAssertEqual(barriers[0].after, .renderTarget)
    }

    func testRepeatedTransitionsOfSameResourceMergeIntoOneBarrier() {
        let tracker = StateTracker()
        tracker.requireState(ref(), .shaderResource)
        tracker.requireState(ref(), .renderTarget)
        let barriers = tracker.commitBarriers()

        // Two transitions merge into a single barrier whose destination is the
        // union of the requested states.
        XCTAssertEqual(barriers.count, 1)
        XCTAssertEqual(barriers[0].before, [])
        XCTAssertEqual(barriers[0].after, [.shaderResource, .renderTarget])
    }

    func testDistinctResourcesAreNotMerged() {
        let tracker = StateTracker()
        tracker.requireState(ResourceRef(kind: .texture, id: 1), .renderTarget)
        tracker.requireState(ResourceRef(kind: .texture, id: 2), .renderTarget)
        XCTAssertEqual(tracker.commitBarriers().count, 2)
    }

    func testCommitDrainsPendingBarriers() {
        let tracker = StateTracker()
        tracker.requireState(ref(), .renderTarget)
        XCTAssertEqual(tracker.commitBarriers().count, 1)
        XCTAssertTrue(tracker.commitBarriers().isEmpty)
    }

    func testRemoveResourceStopsTracking() {
        let tracker = StateTracker()
        tracker.setInitialState(ref(), .renderTarget)
        tracker.removeResource(ref())
        tracker.requireState(ref(), .shaderResource)
        // After removal the resource is unknown again, so the barrier starts
        // from the empty state rather than the old renderTarget state.
        let barriers = tracker.commitBarriers()
        XCTAssertEqual(barriers[0].before, [])
    }
}
