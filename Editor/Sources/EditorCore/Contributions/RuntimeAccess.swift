import Foundation
import PluginRuntime

/// Adapters request a live binding; they never inspect, authorize or own mounts.
final class PluginRuntimeAccess: @unchecked Sendable {
    typealias Resolve = @MainActor @Sendable (String, String) async throws -> (PluginExecutionBinding, PluginHostProcessClient)
    private let lock = NSLock()
    private var resolver: Resolve?
    let contributions: PluginContributions

    init(contributions: PluginContributions) { self.contributions = contributions }
    var taskProviders: [TaskProvider] { TaskProvider.registered(in: contributions.tasks.snapshot.values.map(\.value)) }
    var versionControlProviders: [VersionControlProvider] {
        VersionControlProvider.registered(in: contributions.versionControl.snapshot.values.map(\.value))
    }
    func configure(_ resolver: @escaping Resolve) { lock.withLock { self.resolver = resolver } }
    func resolve(_ id: String, event: String) async throws -> (PluginExecutionBinding, PluginHostProcessClient) {
        guard let resolver = lock.withLock({ resolver }) else { throw PluginManagerError.runtimeUnavailable }
        return try await resolver(id, event)
    }
}
