import Foundation
import PluginRuntime

/// What a step-driven contribution needs from its bundled package: the entry
/// point the editor calls and the one process permission its commands use.
struct StepProvider: Sendable {
    let pluginID: String
    let title: String
    let package: URL
    let entryPoint: String
    let activationEvent: String
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

/// Process adapters share the application's manager and authorized host.
final class StepPlugins: Sendable {
    let runtime: PluginRuntimeAccess
    init(runtime: PluginRuntimeAccess) { self.runtime = runtime }

    func plugin(for provider: StepProvider, workspace: URL) throws -> StepPlugin {
        guard let tool = ContributionTool.locate(provider.process.command) else { throw StepError.toolMissing(provider.process.command) }
        return StepPlugin(provider: provider, tool: tool, workspace: workspace,
            runtime: { [runtime] in try await runtime.resolve(provider.pluginID, event: provider.activationEvent) })
    }
}

final class StepPlugin: Sendable {
    let provider: StepProvider
    let tool: ContributionTool
    let workspace: URL
    private let runtime: @Sendable () async throws -> (PluginExecutionBinding, PluginHostProcessClient)

    init(provider: StepProvider, tool: ContributionTool, workspace: URL,
         runtime: @escaping @Sendable () async throws -> (PluginExecutionBinding, PluginHostProcessClient)) {
        self.provider = provider; self.tool = tool; self.workspace = workspace; self.runtime = runtime
    }

    func invoke(_ request: String, stdout: String) async throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: ["request": request, "stdout": stdout])
        let (binding, client) = try await runtime()
        return try await Task.detached {
            let result = try client.prepareCapability(binding: binding,
                capabilityID: binding.pluginID + "." + self.provider.entryPoint, input: input, querySnapshot: nil)
            guard case let .read(data) = result else { throw StepError.protocolViolation("The plugin returned host calls.") }
            return data
        }.value
    }
}
