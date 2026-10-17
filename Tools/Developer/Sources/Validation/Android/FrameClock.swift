internal import Foundation
internal import ToolSupport

/// Folded-in host test for Android's display frame clock. The standalone
/// `scripts/android/frame-clock-tests.swift` was compiled together with
/// `Frame/Clock.swift` and run with `swiftc`; the same assertions now run
/// in-process and print the same `PASS:` line.
enum FrameClockTests {
  static func run(_ arguments: [String]) throws {
    if let unexpected = arguments.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }
    var clock = DisplayFrameClock()
    try expect(clock.advance(to: 1_000_000_000), 1.0 / 60)
    try expect(clock.advance(to: 1_008_333_333), 0.008333333)
    try expect(clock.advance(to: 1_025_000_000), 0.016666667)
    // Idle callbacks advance the same clock; a new animation does not jump.
    for timestamp in stride(from: UInt64(1_041_666_667), through: 3_000_000_000, by: 16_666_667) {
      _ = clock.advance(to: timestamp)
    }
    try expect(clock.advance(to: 3_000_000_040), 0.008333334)
    // Dropped frames advance by their display time, with a bounded catch-up.
    try expect(clock.advance(to: 3_250_000_040), 0.1)
    try expect(clock.advance(to: 3_250_000_040), 0)
    try expect(clock.advance(to: 3_200_000_000), 0)
    try expect(clock.advance(to: 3_266_666_707), 0.016666667)
    clock = DisplayFrameClock()
    try expect(clock.advance(to: 10_000_000_000), 1.0 / 60)

    Terminal.info("PASS: display timestamps, idle clock, dropped frames, surface reset")
  }

  private static func expect(_ actual: Double, _ expected: Double) throws {
    guard abs(actual - expected) < 0.00000001 else {
      throw ToolError.message("expected \(expected), got \(actual)")
    }
  }
}

/// Uses Choreographer's monotonic display timestamp, including idle callbacks.
/// A new surface starts a fresh clock, so background time never advances a
/// scene. Copied from `Platforms/Android/Sources/GuavaAndroidApp/Frame/Clock.swift`
/// so the assertions above exercise the identical implementation.
struct DisplayFrameClock {
  private var previous: UInt64?

  mutating func advance(to timestamp: UInt64) -> Double {
    guard let previous else {
      self.previous = timestamp
      return 1.0 / 60.0
    }
    guard timestamp > previous else { return 0 }
    self.previous = timestamp
    return min(0.1, Double(timestamp - previous) / 1_000_000_000)
  }
}
