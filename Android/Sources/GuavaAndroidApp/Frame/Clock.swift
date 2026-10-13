/// Uses Choreographer's monotonic display timestamp, including idle callbacks.
/// A new surface starts a fresh clock, so background time never advances a scene.
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
