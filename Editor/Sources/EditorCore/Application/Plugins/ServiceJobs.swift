public import Foundation
public import PluginRuntime

/// Native and cross-plugin work is asynchronous. Every job belongs to its calling plugin.
@MainActor final class PluginServiceJobs {
    nonisolated init() {}
    final class Job {
        let owner: String
        var task: Task<Void, Never>?
        var result: Result<Data, Error>?
        init(owner: String) { self.owner = owner }
    }
    private var jobs: [UUID: Job] = [:]
    private var cleanups: [String: [@MainActor () -> Void]] = [:]
    func own(owner: String, cleanup: @escaping @MainActor () -> Void) { cleanups[owner, default: []].append(cleanup) }
    func start(owner: String, work: @escaping @MainActor () async throws -> Data) throws -> UUID {
        guard jobs.count < 256 else { throw PluginCommandError.unavailable }
        let id = UUID(), job = Job(owner: owner); jobs[id] = job
        job.task = Task { @MainActor in
            do { job.result = .success(try await work()) } catch { job.result = .failure(error) }
            job.task = nil
        }
        return id
    }
    func poll(id: UUID, owner: String) throws -> Data {
        guard let job = jobs[id], job.owner == owner else { throw PluginCommandError.unavailable }
        guard let result = job.result else { return Data(#"{"status":"running"}"#.utf8) }
        jobs[id] = nil
        switch result {
        case let .success(value):
            return try JSONSerialization.data(withJSONObject: ["status": "completed", "value": JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])])
        case let .failure(error):
            return try JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription])
        }
    }
    func cancel(id: UUID, owner: String) { guard jobs[id]?.owner == owner else { return }; jobs.removeValue(forKey: id)?.task?.cancel() }
    func cancel(owner: String) {
        for (id, job) in jobs where job.owner == owner { job.task?.cancel(); jobs[id] = nil }
        for cleanup in cleanups.removeValue(forKey: owner) ?? [] { cleanup() }
    }
    func cancelAll() { for owner in Set(jobs.values.map(\.owner)).union(cleanups.keys) { cancel(owner: owner) } }
}

/// Only the pipe reader blocks; work always runs on the application actor.
final class PluginHostCallWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private let semaphore = DispatchSemaphore(value: 0)
    func complete(_ value: Result<Data, Error>) { lock.withLock { result = value }; semaphore.signal() }
    func wait() throws -> Data {
        guard !Thread.isMainThread else { throw EditorProjectToolError("Plugin host callback reached the UI thread") }
        guard semaphore.wait(timeout: .now() + 4) == .success else { throw EditorProjectToolError("Plugin host service deadline exceeded") }
        guard let result = lock.withLock({ result }) else { throw EditorProjectToolError("Plugin host service returned no result") }
        return try result.get()
    }
}
