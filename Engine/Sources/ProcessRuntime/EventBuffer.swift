import Foundation

private enum ProcessEventBufferError: Error { case multipleConsumers }

final class ProcessEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var events: [ProcessEvent?] = []
    private var head = 0
    private var bytes = 0
    private var waiter: CheckedContinuation<ProcessEvent?, Error>?
    private var completion: Result<Void, Error>?

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func append(_ event: ProcessEvent) -> Bool {
        lock.withLock {
            guard completion == nil else { return true }
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: event)
                return true
            }
            let size = Self.size(event)
            guard size <= maximumBytes - bytes else { return false }
            events.append(event)
            bytes += size
            return true
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.withLock {
            guard completion == nil else { return }
            completion = error.map { .failure($0) } ?? .success(())
            if let waiter {
                self.waiter = nil
                if let error { waiter.resume(throwing: error) }
                else { waiter.resume(returning: nil) }
            }
        }
    }

    func next() async throws -> ProcessEvent? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    if head < events.count, let event = events[head] {
                        events[head] = nil
                        head += 1
                        bytes -= Self.size(event)
                        if head >= 64 { events.removeFirst(head); head = 0 }
                        continuation.resume(returning: event)
                    } else if let completion {
                        continuation.resume(with: completion.map { nil })
                    } else if waiter != nil {
                        continuation.resume(throwing: ProcessEventBufferError.multipleConsumers)
                    } else {
                        waiter = continuation
                    }
                }
            }
        } onCancel: { self.finish(throwing: CancellationError()) }
    }

    private static func size(_ event: ProcessEvent) -> Int {
        switch event {
        case let .stdout(data), let .stderr(data): data.count
        case .exited, .stdoutClosed, .stderrClosed: 0
        }
    }
}
