import Foundation

/// Single-producer / single-consumer handoff that keeps only the newest value.
///
/// This is a latest-wins mailbox, not a FIFO queue: `publish` never blocks and
/// `consumeLatest` returns the most recently published value, dropping anything
/// the consumer did not pick up in between. The handoff stays bounded to a small
/// slot count (three by default) so producer and consumer never allocate in the
/// hot path. Slot selection is coordinated under one short critical section,
/// which keeps the implementation compatible with macOS 14.
public final class LatestValueBuffer<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var publishedIndex = -1
        var publishedSequence = 0
        var consumedSequence = 0
        var consumerIndex = -1
        var producerCursor = 0
    }

    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func write(_ newValue: Value) {
            lock.withLock {
                value = newValue
            }
        }

        func read() -> Value? {
            lock.withLock { value }
        }
    }

    private let slots: [Slot]
    private let state = LockedState(State())

    public init(slotCount: Int = 3) {
        precondition(slotCount >= 3, "LatestValueBuffer requires at least three slots")
        self.slots = (0..<slotCount).map { _ in Slot() }
    }

    public var slotCount: Int { slots.count }

    public func publish(_ value: Value) {
        let candidate = state.withLock { state -> Int in
            var slotIndex = state.producerCursor
            for _ in 0..<slots.count {
                if slotIndex != state.consumerIndex && slotIndex != state.publishedIndex {
                    break
                }
                slotIndex = (slotIndex + 1) % slots.count
            }
            state.producerCursor = (slotIndex + 1) % slots.count
            return slotIndex
        }

        slots[candidate].write(value)
        state.withLock { state in
            state.publishedIndex = candidate
            state.publishedSequence += 1
        }
    }

    public func consumeLatest() -> Value? {
        let snapshot = state.withLock { state -> (Int, Int)? in
            guard state.publishedSequence != state.consumedSequence else { return nil }
            guard slots.indices.contains(state.publishedIndex) else { return nil }
            state.consumerIndex = state.publishedIndex
            state.consumedSequence = state.publishedSequence
            return (state.publishedIndex, state.consumedSequence)
        }
        guard let (slotIndex, _) = snapshot else { return nil }
        return slots[slotIndex].read()
    }
}
