import XCTest
@testable import NativeRHI

final class PresentationPolicyTests: XCTestCase {
    func testVSyncUsesOrderedRefreshEvenWhenOtherModesAreAvailable() throws {
        let selected = try VulkanPresentationPolicy.choose(vsyncEnabled: true,
            supportedModes: [.immediate, .mailbox, .fifo])
        XCTAssertEqual(selected, .fifo)
        XCTAssertTrue(selected.synchronizesToDisplay)
    }

    func testDisablingVSyncPrefersImmediateRegardlessOfDriverOrder() throws {
        let lists: [[PresentationMode]] = [[.fifo, .mailbox, .immediate], [.immediate, .fifo, .mailbox]]
        for supported in lists {
            let selected = try VulkanPresentationPolicy.choose(vsyncEnabled: false, supportedModes: supported)
            XCTAssertEqual(selected, .immediate)
            XCTAssertFalse(selected.synchronizesToDisplay)
        }
    }

    func testUnavailableImmediateReportsSynchronizedFallback() throws {
        let mailbox = try VulkanPresentationPolicy.choose(vsyncEnabled: false, supportedModes: [.fifo, .mailbox])
        XCTAssertEqual(mailbox, .mailbox)
        XCTAssertTrue(mailbox.synchronizesToDisplay)
        let fifo = try VulkanPresentationPolicy.choose(vsyncEnabled: false, supportedModes: [.fifo])
        XCTAssertEqual(fifo, .fifo)
        XCTAssertTrue(fifo.synchronizesToDisplay)
        XCTAssertTrue(PresentationMode.compositor.synchronizesToDisplay)
    }

    func testInvalidModeListsAreRejected() {
        XCTAssertThrowsError(try VulkanPresentationPolicy.choose(vsyncEnabled: false, supportedModes: []))
        XCTAssertThrowsError(try VulkanPresentationPolicy.choose(vsyncEnabled: false, supportedModes: [.compositor]))
        XCTAssertThrowsError(try VulkanPresentationPolicy.choose(vsyncEnabled: true, supportedModes: [.immediate]))
    }
}
