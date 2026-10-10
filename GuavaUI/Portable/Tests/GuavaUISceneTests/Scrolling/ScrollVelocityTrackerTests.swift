#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import GuavaUIScene

@Suite struct ScrollVelocityTrackerTests {

    @Test("A single sample carries no direction")
    func singleSample() {
        var tracker = ScrollVelocityTracker()
        tracker.add(time: 0, value: 40)
        #expect(tracker.velocity(at: 0.5) == 0)
        // Kept all the same: it is the first sample the next fit will use.
        #expect(tracker.sampleCount == 1)
    }

    @Test("Steady movement reports its own speed")
    func steadyMovement() {
        var tracker = ScrollVelocityTracker(window: 0.1)
        for index in 0..<6 {
            tracker.add(time: Double(index) * 0.016, value: Float(index) * 8)
        }
        let measured = tracker.velocity()
        #expect(abs(measured - 500) < 1) // 8pt per 16ms
    }

    @Test("Movement in the negative direction reports a negative speed")
    func direction() {
        var tracker = ScrollVelocityTracker(window: 0.1)
        for index in 0..<6 {
            tracker.add(time: Double(index) * 0.016, value: Float(-index) * 8)
        }
        #expect(tracker.velocity() < -400)
    }

    @Test("Samples older than the window stop counting")
    func windowAgesSamplesOut() {
        var tracker = ScrollVelocityTracker(window: 0.1)
        tracker.add(time: 0, value: 0)
        tracker.add(time: 0.2, value: 100)
        // The first sample is 200ms old: only one usable sample is left.
        #expect(tracker.velocity(at: 0.2) == 0)

        tracker.reset()
        tracker.add(time: 0, value: 0)
        tracker.add(time: 0.05, value: 50)
        #expect(abs(tracker.velocity(at: 0.05) - 1_000) < 1)
    }

    @Test("Uneven sample spacing still recovers the underlying speed")
    func unevenSpacing() {
        var tracker = ScrollVelocityTracker(window: 0.5)
        // Real wheel devices deliver irregular gaps and unequal notches.
        let samples: [(TimeInterval, Float)] = [
            (0.000, 0), (0.017, 12), (0.041, 25), (0.058, 40), (0.089, 58)
        ]
        for sample in samples { tracker.add(time: sample.0, value: sample.1) }
        let measured = tracker.velocity()
        let roughRate = Float(58) / Float(0.089)
        #expect(abs(measured - roughRate) < roughRate * 0.1)
    }

    @Test("Coming to rest measures zero, not whatever the last gap implies")
    func restMeasuresZero() {
        var tracker = ScrollVelocityTracker(window: 0.1)
        for index in 0..<5 {
            tracker.add(time: Double(index) * 0.02, value: Float(index) * 10)
        }
        #expect(tracker.velocity() > 400)
        // The gesture holds still: several samples at the same position.
        for index in 5..<12 {
            tracker.add(time: Double(index) * 0.02, value: 40)
        }
        #expect(abs(tracker.velocity()) < 1)
    }

    @Test("A clock that runs backwards restarts instead of reporting nonsense")
    func backwardsClock() {
        var tracker = ScrollVelocityTracker()
        tracker.add(time: 5.0, value: 100)
        tracker.add(time: 1.0, value: 0)
        #expect(tracker.sampleCount == 1)
        tracker.add(time: 1.05, value: 50)
        #expect(abs(tracker.velocity() - 1_000) < 1)

        // A tracker that has heard nothing for longer than `staleAfter` no
        // longer describes the gesture at all.
        var idle = ScrollVelocityTracker()
        idle.add(time: 0, value: 0)
        idle.add(time: 0.05, value: 40)
        #expect(abs(idle.velocity() - 800) < 1)
        #expect(idle.velocity(at: 2.0, staleAfter: 0.25) == 0)
    }

    @Test("Non-finite samples are ignored rather than poisoning the fit")
    func nonFiniteSamples() {
        var tracker = ScrollVelocityTracker()
        tracker.add(time: .nan, value: 10)
        tracker.add(time: 0, value: .infinity)
        #expect(tracker.sampleCount == 0)
        tracker.add(time: 0, value: 0)
        tracker.add(time: 0.1, value: 10)
        #expect(abs(tracker.velocity() - 100) < 1)
    }
}
