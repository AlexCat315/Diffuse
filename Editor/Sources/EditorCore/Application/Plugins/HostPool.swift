import Foundation
import PluginRuntime

/// One isolated host process per plugin.
///
/// A plugin is third-party-shaped code whether or not it ships with the editor:
/// it can loop, exhaust memory or crash. Sharing one host process couples them,
/// so a fault in any plugin stalls or kills every other. Each plugin therefore
/// gets its own process, created on first use and dropped when it exits.
final class PluginHostPool: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [String: PluginHostProcessClient] = [:]
    private let executable: @Sendable () throws -> URL
    /// Called when one plugin's process dies. Only that plugin is affected.
    private let onCrash: @Sendable (String) -> Void
    private var _hostCallHandler: (@Sendable (String, PluginHostServiceCall) throws -> Data)?
    var hostCallHandler: (@Sendable (String, PluginHostServiceCall) throws -> Data)? {
        get { lock.withLock { _hostCallHandler } }
        set { lock.withLock { _hostCallHandler = newValue } }
    }

    /// `executable` resolves lazily so a project with no plugins never launches
    /// a process.
    init(executable: @escaping @Sendable () throws -> URL,
         onCrash: @escaping @Sendable (String) -> Void = { _ in }) {
        self.executable = executable
        self.onCrash = onCrash
    }

    /// The process serving this plugin. A plugin never shares one.
    func client(forPluginID pluginID: String) throws -> PluginHostProcessClient {
        try lock.withLock {
            if let existing = clients[pluginID] { return existing }
            let client = PluginHostProcessClient(executableURL: try executable())
            let notify = onCrash
            client.onInvalidation = { _ in notify(pluginID) }
            client.onHostCall = { [weak self] call in
                guard let handler = self?.hostCallHandler else { throw EditorProjectToolError("Plugin host bridge is not configured") }
                return try handler(pluginID, call)
            }
            clients[pluginID] = client
            return client
        }
    }

    func existing(_ pluginID: String) -> PluginHostProcessClient? {
        lock.withLock { clients[pluginID] }
    }

    /// Removes and stops one plugin's process. Other plugins keep running.
    func discard(_ pluginID: String) -> PluginHostProcessClient? {
        let client = lock.withLock { clients.removeValue(forKey: pluginID) }
        client?.stop()
        return client
    }

    func stopAll() {
        let all = lock.withLock { () -> [PluginHostProcessClient] in
            let values = Array(clients.values)
            clients.removeAll()
            return values
        }
        all.forEach { $0.stop() }
    }

    var pluginIDs: [String] { lock.withLock { clients.keys.sorted() } }
}

/// Routes each capability call to the process that owns the plugin, so a
/// restart or crash invalidates only that plugin.
final class PluginHostRouter: PluginCapabilityInvoking, @unchecked Sendable {
    private let pool: PluginHostPool

    init(pool: PluginHostPool) { self.pool = pool }

    var generation: UInt64 {
        // There is no single host generation once processes are per plugin.
        // Every check goes through `validate(_:)`.
        0
    }

    func validate(_ binding: PluginExecutionBinding) throws {
        // Validation must not start a process: a binding is only meaningful
        // while the process that accepted it is alive.
        guard let client = pool.existing(binding.pluginID) else {
            throw PluginHostClientError.communicationFailed
        }
        try binding.validate(hostGeneration: client.generation)
    }

    func prepareCapability(
        binding: PluginExecutionBinding,
        capabilityID: String,
        input: Data,
        querySnapshot: PluginQuerySnapshot?
    ) throws -> PluginPreparedCapabilityResult {
        let client = try pool.client(forPluginID: binding.pluginID)
        try binding.validate(hostGeneration: client.generation)
        return try client.prepareCapability(binding: binding, capabilityID: capabilityID,
                                            input: input, querySnapshot: querySnapshot)
    }
}
