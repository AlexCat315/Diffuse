import Foundation

@main
enum FrameClockTests {
    static func main() throws {
        var clock = DisplayFrameClock()
        expect(clock.advance(to: 1_000_000_000), 1.0 / 60)
        expect(clock.advance(to: 1_008_333_333), 0.008333333)
        expect(clock.advance(to: 1_025_000_000), 0.016666667)
        // Idle callbacks advance the same clock; a new animation does not jump.
        for timestamp in stride(from: UInt64(1_041_666_667), through: 3_000_000_000, by: 16_666_667) {
            _ = clock.advance(to: timestamp)
        }
        expect(clock.advance(to: 3_000_000_040), 0.008333334)
        // Dropped frames advance by their display time, with a bounded catch-up.
        expect(clock.advance(to: 3_250_000_040), 0.1)
        expect(clock.advance(to: 3_250_000_040), 0)
        expect(clock.advance(to: 3_200_000_000), 0)
        expect(clock.advance(to: 3_266_666_707), 0.016666667)
        clock = DisplayFrameClock()
        expect(clock.advance(to: 10_000_000_000), 1.0 / 60)

        print("PASS: display timestamps, idle clock, dropped frames, surface reset")
    }

    private static func expect(_ actual: Double, _ expected: Double) {
        precondition(abs(actual - expected) < 0.00000001, "expected \(expected), got \(actual)")
    }
}
