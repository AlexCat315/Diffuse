import Foundation

/// Frame completion requires both endFrame and completion of every submission.
/// Condition variables avoid accumulating stale semaphore signals on slot reuse.
public final class FrameRing {
    public final class Slot {
        public let index: Int
        public fileprivate(set) var inFlight = false
        public fileprivate(set) var pendingCommandBuffers = 0
        fileprivate var sealed = false
        fileprivate var epoch: UInt64 = 0
        fileprivate var completedEpoch: UInt64 = 0
        init(index: Int) { self.index = index }
    }

    private struct Retirement {
        let epochs: [Int: UInt64]
        let action: () -> Void
    }
    private var retirements: [Retirement] = []
    private let condition = NSCondition()
    private let slots: [Slot]
    private var current: Slot?
    private var epoch: UInt64 = 0
    private(set) var completedFrames: UInt64 = 0

    public init(slotCount: Int) {
        precondition(slotCount >= 1)
        slots = (0..<slotCount).map(Slot.init)
    }

    public var slotCount: Int { slots.count }
    public var currentSlotIndex: Int? {
        condition.lock()
        defer { condition.unlock() }
        return current?.index
    }

    @discardableResult
    public func begin() -> Slot {
        condition.lock()
        defer { condition.unlock() }
        precondition(current == nil, "end the current frame before beginning another")
        let slot = slots[Int(epoch % UInt64(slots.count))]
        while slot.inFlight { condition.wait() }
        drainRetirements()
        epoch += 1
        slot.epoch = epoch
        slot.inFlight = true
        slot.sealed = false
        slot.pendingCommandBuffers = 0
        current = slot
        return slot
    }

    public func end() {
        condition.lock()
        defer { condition.unlock() }
        guard let slot = current else { return }
        slot.sealed = true
        current = nil
        finishIfReady(slot)
        drainRetirements()
    }

    public func retireCurrent(_ action: @escaping () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        let epochs = Dictionary(uniqueKeysWithValues: slots.filter(\.inFlight).map { ($0.index, $0.epoch) })
        retirements.append(Retirement(epochs: epochs, action: action))
        drainRetirements()
    }

    public func registerCommandBuffer(slotIndex: Int) {
        condition.lock()
        defer { condition.unlock() }
        let slot = slots[slotIndex]
        precondition(slot.inFlight && !slot.sealed)
        slot.pendingCommandBuffers += 1
    }

    public func unregisterCommandBuffer(slotIndex: Int) {
        completeCommandBuffer(slotIndex: slotIndex)
    }

    public func commandBufferCompleted(slotIndex: Int) {
        completeCommandBuffer(slotIndex: slotIndex)
    }

    private func completeCommandBuffer(slotIndex: Int) {
        condition.lock()
        defer { condition.unlock() }
        let slot = slots[slotIndex]
        precondition(slot.pendingCommandBuffers > 0)
        slot.pendingCommandBuffers -= 1
        finishIfReady(slot)
    }

    private func finishIfReady(_ slot: Slot) {
        guard slot.inFlight && slot.sealed && slot.pendingCommandBuffers == 0 else { return }
        // GPU callbacks only update completion state. Destruction is drained
        // on the API thread under Device's lock, never against live registries.
        slot.completedEpoch = slot.epoch
        slot.inFlight = false
        completedFrames += 1
        condition.broadcast()
    }

    private func drainRetirements() {
        var pending: [Retirement] = []
        for retirement in retirements {
            if retirement.epochs.allSatisfy({ slots[$0.key].completedEpoch >= $0.value }) {
                retirement.action()
            } else {
                pending.append(retirement)
            }
        }
        retirements = pending
    }

    public func waitUntilIdle() {
        condition.lock()
        defer { condition.unlock() }
        precondition(current == nil, "end the active frame before waiting for idle")
        while slots.contains(where: \.inFlight) { condition.wait() }
        drainRetirements()
    }
}
