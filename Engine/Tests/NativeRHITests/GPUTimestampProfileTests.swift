// NativeRHITests — GPUTimestampProfile: bounded accumulation, ordering and
// reset. The Vulkan query pool itself needs a device, so these cover the parts
// that are pure bookkeeping.

import XCTest
@testable import NativeRHI

final class GPUTimestampProfileTests: XCTestCase {
    private func marker(_ label: String, _ nanoseconds: UInt64) -> GPUTimestampProfile.Marker {
        GPUTimestampProfile.Marker(label: label, nanoseconds: nanoseconds)
    }

    func testMarkersKeepCompletionOrderAndCount() {
        let profile = GPUTimestampProfile()
        profile.append(marker("ui-segment", 1_000))
        profile.append(marker("backdrop-blit", 2_000))
        profile.append(marker("backdrop-blur-v", 3_000))
        XCTAssertEqual(profile.sampleCount, 3)
        XCTAssertEqual(profile.recordedMarkers.map(\.label), ["ui-segment", "backdrop-blit", "backdrop-blur-v"])
        XCTAssertEqual(profile.recordedMarkers.map(\.nanoseconds), [1_000, 2_000, 3_000])
    }

    func testSamplingStopsAtTheMarkerLimitButStillCounts() {
        let profile = GPUTimestampProfile(markerLimit: 2)
        for index in 0..<5 { profile.append(marker("pass", UInt64(index))) }
        XCTAssertEqual(profile.sampleCount, 5, "every completion should still be counted")
        XCTAssertEqual(profile.recordedMarkers.count, 2, "only the limit worth of markers is retained")
        XCTAssertEqual(profile.recordedMarkers.map(\.nanoseconds), [0, 1])
    }

    func testResetClearsCountersAndRetainedMarkers() {
        let profile = GPUTimestampProfile()
        profile.append(marker("ui-segment", 1_000))
        profile.reset()
        XCTAssertEqual(profile.sampleCount, 0)
        XCTAssertTrue(profile.recordedMarkers.isEmpty)
    }

    func testConcurrentAppendsAreSerialised() {
        let profile = GPUTimestampProfile(markerLimit: 1_000)
        let writers = 4, perWriter = 50
        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            for index in 0..<perWriter { profile.append(marker("pass-\(writer)", UInt64(index))) }
        }
        XCTAssertEqual(profile.sampleCount, writers * perWriter)
        XCTAssertEqual(profile.recordedMarkers.count, writers * perWriter)
    }

    func testZeroLimitRetainsNothingButStillCounts() {
        let profile = GPUTimestampProfile(markerLimit: 0)
        profile.append(marker("ui-segment", 1_000))
        XCTAssertEqual(profile.sampleCount, 1)
        XCTAssertTrue(profile.recordedMarkers.isEmpty)
    }

    func testDescriptorLabelDefaultsToNilSoUnlabelledPassesStayUnchanged() {
        XCTAssertNil(RenderPassDescriptor(colorTargets: []).label)
        XCTAssertEqual(RenderPassDescriptor(colorTargets: [], label: "ui-segment").label, "ui-segment")
    }
}
