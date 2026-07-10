import Foundation
import Testing
@testable import GuavaUIApp

@Suite("AppDisplayHandle")
struct AppDisplayHandleTests {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.withLock { value += 1 }
        }

        var current: Int {
            lock.withLock { value }
        }
    }

    @Test("Repeated display requests coalesce to one event-loop wake")
    func coalescesDisplayWakes() {
        let wakes = LockedCounter()
        let display = AppDisplayHandle {
            wakes.increment()
        }

        display.requestDisplay()
        display.requestDisplay()
        display.requestDisplay()

        #expect(wakes.current == 1)
        #expect(display.drainDisplayRequest())
        #expect(!display.drainDisplayRequest())

        display.requestDisplay()
        #expect(wakes.current == 2)
    }
}
