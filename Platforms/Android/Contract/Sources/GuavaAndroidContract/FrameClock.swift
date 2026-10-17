/// Uses Choreographer's monotonic display timestamp, including idle callbacks.
/// A new surface starts a fresh clock, so background time never advances a
/// scene.
///
/// Kept in the platform-neutral contract package so the Android app and host
/// tests exercise one implementation instead of a copied assertion target.
public struct DisplayFrameClock {
    private var previous: UInt64?

    public init() {}

    public mutating func advance(to timestamp: UInt64) -> Double {
        guard let previous else {
            self.previous = timestamp
            return 1.0 / 60.0
        }
        guard timestamp > previous else { return 0 }
        self.previous = timestamp
        return min(0.1, Double(timestamp - previous) / 1_000_000_000)
    }
}
