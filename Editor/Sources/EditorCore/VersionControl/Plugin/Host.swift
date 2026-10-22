import Foundation
import PluginRuntime

/// Runs the bundled version control plugins in a plugin host of their own,
/// so polling never queues behind AI plugins or the language server.
final class VersionControlPlugins: @unchecked Sendable {
    private let hostExecutable: URL?
    private let lock = NSLock()
    private var client: PluginHostProcessClient?
    private var mounts: [VersionControlSystem: VersionControlPlugin] = [:]

    init(hostExecutable: URL?) {
        self.hostExecutable = hostExecutable
    }

    deinit { client?.stop() }

    /// Systems whose command-line tool is installed.
    var installedSystems: Set<VersionControlSystem> {
        Set(VersionControlProvider.bundled.filter { VersionControlTool.locate($0.process.command) != nil }.map(\.system))
    }

    func backend(for repository: VersionControlRepository) throws -> any VersionControlBackend {
        PluginBackend(repository: repository, plugin: try plugin(for: repository.system, workspace: repository.root))
    }

    /// The plugin for `system`, running its commands in `workspace`.
    func plugin(for system: VersionControlSystem, workspace: URL) throws -> VersionControlPlugin {
        guard let provider = VersionControlProvider.provider(for: system) else {
            throw VersionControlError.unsupported("The \(system.rawValue) plugin is missing from this build.")
        }
        guard let tool = VersionControlTool.locate(provider.process.command) else { throw VersionControlError.toolMissing(system) }
        return try lock.withLock {
            if let mounted = mounts[system], mounted.workspace == workspace, mounted.tool.executable == tool.executable {
                return mounted
            }
            if client == nil {
                guard let hostExecutable else {
                    throw VersionControlError.unsupported("GuavaPluginHost was not found; version control runs through it.")
                }
                client = PluginHostProcessClient(executableURL: hostExecutable)
            }
            let plugin = VersionControlPlugin(provider: provider, tool: tool, workspace: workspace, client: client!)
            mounts[system] = plugin
            return plugin
        }
    }
}

/// One provider mounted for one working tree. The host binding is made on
/// first use and again after the plugin host restarts.
final class VersionControlPlugin: @unchecked Sendable {
    let provider: VersionControlProvider
    let tool: VersionControlTool
    let workspace: URL
    private let client: PluginHostProcessClient
    private let lock = NSLock()
    private var binding: PluginExecutionBinding?

    init(provider: VersionControlProvider, tool: VersionControlTool, workspace: URL, client: PluginHostProcessClient) {
        self.provider = provider
        self.tool = tool
        self.workspace = workspace
        self.client = client
    }

    /// One `provider` call: the step request and a window of the last command's output.
    func invoke(_ request: String, stdout: String) throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: ["request": request, "stdout": stdout])
        let binding = try mounted()
        let result = try client.prepareCapability(binding: binding,
            capabilityID: binding.pluginID + "." + VersionControlContribution.entryPoint, input: input, querySnapshot: nil)
        guard case let .read(data) = result else { throw VersionControlError.unsupported("The plugin returned host calls.") }
        return data
    }

    private func mounted() throws -> PluginExecutionBinding {
        try lock.withLock {
            if let binding, binding.hostGeneration == client.generation { return binding }
            // Bundled plugins ship with the editor, so they are trusted as built.
            let inspection = try client.inspectPlugin(at: provider.package)
            var context = PluginProcessContext(workspace: workspace)
            context.executables = [provider.process.command: tool.executable]
            let binding = try client.loadPlugin(at: provider.package,
                authorization: PluginAuthorizationRecord(inspection: inspection), processContext: context)
            self.binding = binding
            return binding
        }
    }
}
