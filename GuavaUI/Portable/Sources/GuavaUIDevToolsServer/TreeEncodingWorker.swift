import Foundation

/// JSONEncoder recursively visits nested components. Dispatch workers have a
/// much smaller stack than the scene thread on macOS; real editor trees can
/// overflow that stack even when their node count is modest. Use one serial,
/// idle-sleeping worker with the same stack budget as the native main thread.
final class TreeEncodingWorker: @unchecked Sendable {
    private final class Inbox: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [@Sendable () -> Void] = []
        private var stopped = false

        func submit(_ job: @escaping @Sendable () -> Void) {
            condition.lock()
            defer { condition.unlock() }
            guard !stopped else { return }
            jobs.append(job)
            condition.signal()
        }

        func next() -> (@Sendable () -> Void)? {
            condition.lock()
            defer { condition.unlock() }
            while jobs.isEmpty && !stopped { condition.wait() }
            guard !stopped else { return nil }
            return jobs.removeFirst()
        }

        func stop() {
            condition.lock()
            stopped = true
            jobs.removeAll()
            condition.signal()
            condition.unlock()
        }
    }

    private let inbox = Inbox()

    init() {
        let inbox = inbox
        let thread = Thread {
            while let job = inbox.next() {
                #if canImport(ObjectiveC)
                autoreleasepool(invoking: job)
                #else
                job()
                #endif
            }
        }
        thread.name = "guava.devtools.tree-encoding"
        thread.qualityOfService = .utility
        thread.stackSize = 8 * 1024 * 1024
        thread.start()
    }

    func submit(_ job: @escaping @Sendable () -> Void) { inbox.submit(job) }

    deinit { inbox.stop() }
}
