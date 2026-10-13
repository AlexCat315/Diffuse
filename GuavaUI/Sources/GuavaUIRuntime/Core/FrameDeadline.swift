/// Absolute deadlines for an explicitly requested fixed rate, or a documented
/// fallback when the shell cannot supply native display callbacks. Work and
/// early input wakes never move the cadence's phase.
struct FrameDeadline {
    private(set) var next: Double?
    private var interval: Double?

    mutating func update(interval: Double?, now: Double) {
        guard interval != self.interval else { return }
        self.interval = interval
        next = interval == nil ? nil : now
    }

    mutating func consumeIfDue(now: Double) -> Bool {
        guard let interval, let next, now >= next else { return false }
        let elapsedIntervals = ((now - next) / interval).rounded(.down) + 1
        self.next = next + elapsedIntervals * interval
        return true
    }

    func remaining(now: Double) -> Double? {
        next.map { max(0, $0 - now) }
    }
}
