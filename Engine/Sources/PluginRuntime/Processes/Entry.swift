internal import Foundation
internal import CoveProcess

final class ProcessEntry: @unchecked Sendable {
    /// Output returned by one poll. Only editor entry points reach processes,
    /// under the larger host-entry-point limits.
    static let chunkBytes = 4 * 1_048_576
    let session: ProcessSession
    let generation: UUID
    let permissionID: String
    private let lock = NSLock()
    private var update: PluginProcessUpdate
    private let maximumBytes: Int
    private var consumer: Task<Void, Never>?
    private var lastMemorySample = ContinuousClock.now

    init(session: ProcessSession, generation: UUID, permissionID: String, maximumBytes: Int) {
        self.permissionID = permissionID
        self.session = session; self.generation = generation; self.maximumBytes = maximumBytes
        update = PluginProcessUpdate(handle: session.id)
        consumer = Task { [weak self, events = session.events] in
            do {
                for try await event in events { self?.receive(event) }
            } catch { self?.failed(error) }
        }
    }
    deinit { consumer?.cancel(); session.cancel() }

    private func receive(_ event: ProcessEvent) {
        let overflow = lock.withLock {
            switch event {
            case let .stdout(data): update.stdout.append(data)
            case let .stderr(data): update.stderr.append(data)
            case let .exited(status): update.exitStatus = status
            case .stdoutClosed, .stderrClosed: break
            }
            if update.stdout.count + update.stderr.count > maximumBytes {
                update.stdout = Data(); update.stderr = Data(); update.failure = "process output limit exceeded"
                return true
            }
            return false
        }
        if overflow { session.cancel() }
    }
    private func failed(_ error: Error) {
        lock.withLock { if update.failure == nil { update.failure = String(describing: error) } }
    }
    func poll() -> PluginProcessUpdate {
        lock.withLock {
            if lastMemorySample.duration(to: .now) >= .seconds(1) {
                update.residentMemoryBytes = session.isRunning ? PluginProcessMemory.residentBytes(processID: session.processIdentifier) : nil
                lastMemorySample = .now
            }
            var result = update
            result.stdout = Data(update.stdout.prefix(Self.chunkBytes))
            result.stderr = Data(update.stderr.prefix(Self.chunkBytes))
            update.stdout.removeFirst(result.stdout.count)
            update.stderr.removeFirst(result.stderr.count)
            if !update.stdout.isEmpty || !update.stderr.isEmpty { result.exitStatus = nil }
            return result
        }
    }
}
