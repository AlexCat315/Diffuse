import Foundation
import Testing
@testable import GuavaUIRuntime
@testable import PlatformShell

struct FrameDeadlineTests {
    @Test("Fixed deadlines retain their phase across late work and early input wakes")
    func absolutePhase() {
        var cadence = FrameDeadline()
        cadence.update(interval: 0.01, now: 100)
        let firstDue = cadence.consumeIfDue(now: 100)
        let earlyDue = cadence.consumeIfDue(now: 100.004)
        #expect(firstDue)
        #expect(!earlyDue)
        #expect(abs((cadence.next ?? 0) - 100.01) < 1e-9)
        let lateDue = cadence.consumeIfDue(now: 100.027)
        #expect(lateDue)
        #expect(abs((cadence.next ?? 0) - 100.03) < 1e-9)
        let repeatedDue = cadence.consumeIfDue(now: 100.027)
        #expect(!repeatedDue)
        #expect(abs((cadence.remaining(now: 100.028) ?? 0) - 0.002) < 1e-9)
    }

    @Test("A blocked present consumes the deadline without a new full-period wait")
    func presentationOverrun() {
        var cadence = FrameDeadline()
        cadence.update(interval: 1.0 / 60, now: 100)
        let firstDue = cadence.consumeIfDue(now: 100)
        #expect(firstDue)
        #expect(cadence.remaining(now: 100.020) == 0)
        let overrunDue = cadence.consumeIfDue(now: 100.020)
        #expect(overrunDue)
        #expect(abs((cadence.next ?? 0) - (100 + 2.0 / 60)) < 1e-9)
    }

    @Test("Changing rates or leaving cadence resets the pending deadline")
    func reconfiguration() {
        var cadence = FrameDeadline()
        cadence.update(interval: 0.01, now: 100)
        let firstDue = cadence.consumeIfDue(now: 100)
        #expect(firstDue)
        cadence.update(interval: 0.02, now: 100.004)
        let reconfiguredDue = cadence.consumeIfDue(now: 100.004)
        #expect(reconfiguredDue)
        #expect(abs((cadence.next ?? 0) - 100.024) < 1e-9)
        cadence.update(interval: nil, now: 100.005)
        #expect(cadence.next == nil)
        let stoppedDue = cadence.consumeIfDue(now: 200)
        #expect(!stoppedDue)
    }

    @Test("Native callbacks retain only the newest timestamp and coalesce wakeups")
    func nativeCallbackCoalescing() {
        let wakes = WakeCount()
        let inbox = DisplayRefreshInbox { wakes.increment() }
        let first = DisplayRefreshTick(timestamp: 100, targetTimestamp: 100.016)
        let latest = DisplayRefreshTick(timestamp: 100.032, targetTimestamp: 100.048)
        inbox.publish(first)
        #expect(wakes.value == 0)
        inbox.setEnabled(true)
        inbox.publish(first)
        inbox.publish(latest)
        #expect(wakes.value == 1)
        #expect(inbox.take() == latest)
        #expect(inbox.take() == nil)
        inbox.publish(first)
        #expect(wakes.value == 2)
        inbox.setEnabled(false)
        #expect(inbox.take() == nil)
        inbox.publish(latest)
        #expect(wakes.value == 2)
        inbox.setEnabled(true)
        #expect(inbox.take() == nil)
    }
}

private final class WakeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
