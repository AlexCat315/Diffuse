public import Foundation

/// SDL's on-demand event loop must be explicitly woken for work arriving over a pipe or timer.
final class PluginUIQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var enqueue: ((@escaping () -> Void) -> Void)?
    func install(_ enqueue: ((@escaping () -> Void) -> Void)?) {
        guard let enqueue else { return }
        lock.withLock { self.enqueue = enqueue }
    }
    func schedule(_ body: @escaping @MainActor @Sendable () -> Void) {
        let work: @Sendable () -> Void = { MainActor.assumeIsolated { body() } }
        if let enqueue = lock.withLock({ enqueue }) { enqueue(work) }
        else { Task { @MainActor in body() } }
    }
}
