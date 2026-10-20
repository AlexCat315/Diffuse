internal import Foundation
internal import ProcessRuntime

final class ProcessEntry: @unchecked Sendable {
    let session: ProcessSession
    let generation: UUID
    let permissionID: String
    private let lock = NSLock()
    private var update: PluginProcessUpdate
    private let maximumBytes: Int
    private var consumer: Task<Void, Never>?

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
    private func failed(_ error: Error) { lock.withLock { update.failure = String(describing: error) } }
    func poll() -> PluginProcessUpdate {
        lock.withLock {
            let result = update
            update.stdout = Data(); update.stderr = Data()
            return result
        }
    }
}
