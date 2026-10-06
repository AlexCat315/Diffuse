import Foundation

/// Bounded, opt-in CPU timeline owned and accessed by the scene thread.
/// Parent component spans include child work, preserving nesting in exports.
public final class PerformanceTimeline {
    public struct Event: Codable, Equatable, Sendable {
        public var sequence: UInt64
        public var phase: String
        public var name: String
        public var scopeID: String?
        public var startMs: Double
        public var durationMs: Double
        public var reasons: [RecompositionReason]
    }
    public private(set) var enabled = false
    private var buffer: [Event] = []
    private var nextIndex = 0
    public var events: [Event] {
        if nextIndex == 0 { return buffer }
        return Array(buffer[nextIndex...]) + Array(buffer[..<nextIndex])
    }
    /// Read only the tail after a connection cursor, without copying old spans.
    public func events(after sequence: UInt64) -> [Event] {
        guard let last = buffer.last, !buffer.isEmpty else { return [] }
        let latest = buffer.count == capacity ? buffer[(nextIndex + buffer.count - 1) % buffer.count].sequence : last.sequence
        guard latest > sequence else { return [] }
        let count = Int(min(UInt64(buffer.count), latest - sequence))
        let first = buffer.count == capacity ? (nextIndex + buffer.count - count) % buffer.count : buffer.count - count
        return (0..<count).map { buffer[(first + $0) % buffer.count] }
    }
    public private(set) var dropped = 0
    private var sequence: UInt64 = 0
    private var origin = ContinuousClock.now
    private let capacity: Int
    public init(capacity: Int = 2048) { self.capacity = max(1, min(8192, capacity)) }
    public func setEnabled(_ value: Bool) {
        if value && !enabled { buffer.removeAll(keepingCapacity: true); nextIndex = 0; dropped = 0; origin = .now }
        enabled = value
    }
    public func begin() -> Double? {
        guard enabled else { return nil }
        return milliseconds(origin.duration(to: .now))
    }
    public func end(_ start: Double?, phase: String, name: String, scopeID: String? = nil,
                    reasons: [RecompositionReason] = []) {
        guard enabled, let start else { return }
        sequence &+= 1
        let event = Event(sequence: sequence, phase: phase, name: String(name.prefix(160)), scopeID: scopeID,
            startMs: start, durationMs: max(0, milliseconds(origin.duration(to: .now)) - start),
            reasons: Array(reasons.prefix(16)))
        if buffer.count < capacity { buffer.append(event) }
        else { buffer[nextIndex] = event; nextIndex = (nextIndex + 1) % capacity; dropped += 1 }
    }
    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
