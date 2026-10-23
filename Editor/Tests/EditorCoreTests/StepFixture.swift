@testable import EditorCore
import Foundation
import PluginRuntime
import Testing

/// Real component calls with recorded command output, without running tools.
func stepFixture(_ provider: StepProvider) throws -> StepPlugin {
    let client = PluginHostProcessClient(executableURL: try #require(EditorPluginHostLocator.resolve()))
    let tool = ContributionTool(executable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:])
    let workspace = FileManager.default.temporaryDirectory
    let inspection = try client.inspectPlugin(at: provider.package)
    var context = PluginProcessContext(workspace: workspace)
    context.executables = [provider.process.command: tool.executable]
    let binding = try client.loadPlugin(at: provider.package,
        authorization: PluginAuthorizationRecord(inspection: inspection), processContext: context)
    return StepPlugin(provider: provider, tool: tool, workspace: workspace, runtime: { (binding, client) })
}
