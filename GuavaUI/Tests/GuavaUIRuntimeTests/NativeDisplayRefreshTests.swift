#if os(macOS)
import Foundation
import XCTest
import PlatformShell
@testable import GuavaUIRuntime

final class NativeDisplayRefreshTests: XCTestCase {
    @MainActor
    func testSDLWaitServicesNativeDisplayCallbacksAndLifecycle() async throws {
        let shell = try SDL3Shell()
        defer { shell.shutdown() }
        let window = try shell.createWindow(title: "Native display callback regression", options: .init(width: 160, height: 100))

        func receiveTicks(count: Int) -> [DisplayRefreshTick] {
            var ticks: [DisplayRefreshTick] = []
            let deadline = TimingTrace.now() + 1
            while ticks.count < count && TimingTrace.now() < deadline {
                shell.pollWindowEvents()
                XCTAssertTrue(shell.setDisplayRefreshEnabled(true, windowID: window.id))
                if let tick = shell.takeDisplayRefresh(windowID: window.id) { ticks.append(tick) }
                if ticks.count < count { shell.waitForEvents(timeout: 0.1) }
            }
            return ticks
        }

        let first = receiveTicks(count: 3)
        XCTAssertEqual(first.count, 3, "SDL's native wait must service display link callbacks")
        for tick in first {
            XCTAssertGreaterThan(tick.targetTimestamp, tick.timestamp)
            XCTAssertLessThan(abs(tick.timestamp - TimingTrace.now()), 1)
        }
        for (previous, current) in zip(first, first.dropFirst()) {
            XCTAssertGreaterThan(current.timestamp, previous.timestamp)
            XCTAssertLessThan(current.timestamp - previous.timestamp, 0.075,
                              "Native callbacks must wake SDL before its 100 ms timeout")
        }

        shell.setDisplayRefreshEnabled(false, windowID: window.id)
        shell.pollWindowEvents()
        shell.waitForEvents(timeout: 0.04)
        XCTAssertNil(shell.takeDisplayRefresh(windowID: window.id))
        XCTAssertEqual(receiveTicks(count: 2).count, 2)

        shell.hideWindow(window.id)
        shell.pollWindowEvents()
        XCTAssertTrue(shell.setDisplayRefreshEnabled(true, windowID: window.id))
        shell.waitForEvents(timeout: 0.04)
        XCTAssertNil(shell.takeDisplayRefresh(windowID: window.id))
        shell.showWindow(window.id)
        XCTAssertEqual(receiveTicks(count: 2).count, 2)

        shell.destroyWindow(window.id)
        XCTAssertNil(shell.takeDisplayRefresh(windowID: window.id))
    }
}
#endif
