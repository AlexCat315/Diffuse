import Testing
import GuavaAndroidContract

private func expectAdvance(
    _ clock: inout DisplayFrameClock, to timestamp: UInt64, is expected: Double
) {
    #expect(abs(clock.advance(to: timestamp) - expected) < 0.00000001)
}

@Test func firstFrameUsesDisplayRefreshDefault() {
    var clock = DisplayFrameClock()
    expectAdvance(&clock, to: 1_000_000_000, is: 1.0 / 60)
}

@Test func idleCallbacksDoNotAdvanceAnimationClock() {
    var clock = DisplayFrameClock()
    expectAdvance(&clock, to: 1_000_000_000, is: 1.0 / 60)
    expectAdvance(&clock, to: 1_008_333_333, is: 0.008333333)
    expectAdvance(&clock, to: 1_025_000_000, is: 0.016666667)
    for timestamp in stride(from: UInt64(1_041_666_667), through: 3_000_000_000, by: 16_666_667) {
        _ = clock.advance(to: timestamp)
    }
    expectAdvance(&clock, to: 3_000_000_040, is: 0.008333334)
}

@Test func droppedFramesAreBoundedAndBackwardsTimestampsIgnored() {
    var clock = DisplayFrameClock()
    _ = clock.advance(to: 3_000_000_000)
    expectAdvance(&clock, to: 3_250_000_040, is: 0.1)
    expectAdvance(&clock, to: 3_250_000_040, is: 0)
    expectAdvance(&clock, to: 3_200_000_000, is: 0)
    expectAdvance(&clock, to: 3_266_666_707, is: 0.016666667)
}

@Test func newSurfaceStartsFreshClock() {
    var clock = DisplayFrameClock()
    expectAdvance(&clock, to: 1_000_000_000, is: 1.0 / 60)
    clock = DisplayFrameClock()
    expectAdvance(&clock, to: 10_000_000_000, is: 1.0 / 60)
}
