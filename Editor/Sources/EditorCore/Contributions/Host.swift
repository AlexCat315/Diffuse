import Foundation
import PluginRuntime

/// What a step-driven contribution needs from its bundled package: the entry
/// point the editor calls and the one process permission its commands use.
struct StepProvider: Sendable {
    let title: String
    let package: URL
    let entryPoint: String
    let process: PluginProcessPermission
}

/// Failures of the step protocol itself, or of a command a plugin ran.
enum StepError: Error, LocalizedError, Equatable, Sendable {
    case toolMissing(String)
    case commandFailed(command: String, message: String)
    case protocolViolation(String)

    var errorDescription: String? {
        switch self {
        case let .toolMissing(command): "The \(command) command-line tool was not found. Install it and make sure it is on PATH."
        case let .commandFailed(command, message): message.isEmpty ? "\(command) failed." : message
        case let .protocolViolation(message): message
        }
    }
}

/// Runs step-driven bundled plugins in a plugin host of their own, so their
/// polling never queues behind AI plugins or the language server.
final class StepPlugins: @unchecked Sendable {
    private let hostExecutable: URL?
    private let lock = NSLock()
    private var client: PluginHostProcessClient?
    private var mounts: [URL: StepPlugin] = [:]

    init(hostExecutable: URL?) {
        self.hostExecutable = hostExecutable
    }

    deinit { client?.stop() }

    /// `provider`'s plugin, running its commands in `workspace`.
    func plugin(for provider: StepProvider, workspace: URL) throws -> StepPlugin {
        guard let tool = ContributionTool.locate(provider.process.command) else { throw StepError.toolMissing(provider.process.command) }
        return try lock.withLock {
            if let mounted = mounts[provider.package], mounted.workspace == workspace, mounted.tool.executable == tool.executable {
                return mounted
            }
            if client == nil {
                guard let hostExecutable else {
                    throw StepError.protocolViolation("GuavaPluginHost was not found; \(provider.title) runs through it.")
                }
                client = PluginHostProcessClient(executableURL: hostExecutable)
            }
            let plugin = StepPlugin(provider: provider, tool: tool, workspace: workspace, client: client!)
            mounts[provider.package] = plugin
            return plugin
        }
    }
}

/// One provider mounted for one workspace. The host binding is made on first
/// use and again after the plugin host restarts.
final class StepPlugin: @unchecked Sendable {
    let provider: StepProvider
    let tool: ContributionTool
    let workspace: URL
    private let client: PluginHostProcessClient
    private let lock = NSLock()
    private var binding: PluginExecutionBinding?

    init(provider: StepProvider, tool: ContributionTool, workspace: URL, client: PluginHostProcessClient) {
        self.provider = provider
        self.tool = tool
        self.workspace = workspace
        self.client = client
    }

    /// One entry point call: the step request and a window of the last command's output.
    func invoke(_ request: String, stdout: String) throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: ["request": request, "stdout": stdout])
        let binding = try mounted()
        let result = try client.prepareCapability(binding: binding,
            capabilityID: binding.pluginID + "." + provider.entryPoint, input: input, querySnapshot: nil)
        guard case let .read(data) = result else { throw StepError.protocolViolation("The plugin returned host calls.") }
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
