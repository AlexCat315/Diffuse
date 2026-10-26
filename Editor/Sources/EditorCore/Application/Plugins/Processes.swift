import Foundation
import PluginRuntime
private import CoveFileSystem
private import CoveProcess

extension EditorApplication {
    /// The host resolves tools from its launch environment, never a package's
    /// environment or a project's bin directory. The approved permission still
    /// restricts command, arguments and environment on every invocation.
    func pluginProcessContext(for authorization: PluginAuthorizationRecord) throws -> PluginProcessContext {
        let permissions = authorization.host
        let root = PathIdentity.canonicalURL(URL(fileURLWithPath: projectDirectory))
        var context = PluginProcessContext(workspace: root)
        let providers = pluginSession.runtime.versionControlProviders.filter { $0.pluginID == authorization.pluginID }
        if permissions.entryPoints.contains(VersionControlContribution.entryPoint),
           let repository = VersionControlProvider.repository(containing: root, among: providers) {
            context.workspace = repository.root
        }
        #if os(Windows)
        let separator: Character = ";"
        #else
        let separator: Character = ":"
        #endif
        let environment = ProcessInfo.processInfo.environment
        let directories = (ProcessEnvironment.value("PATH", in: environment) ?? "").split(separator: separator).compactMap { item -> URL? in
            let path = String(item)
            guard NSString(string: path).isAbsolutePath else { return nil }
            let url = PathIdentity.canonicalURL(URL(fileURLWithPath: path))
            guard !PathIdentity.contains(url, in: root) else { return nil }
            return url
        }
        for rule in permissions.processes {
            if rule.command == "sourcekit-lsp" {
                let executable = try dynamicScriptManager.swiftToolchain?.languageServerURL
                    ?? SwiftToolchainResolver.resolve().languageServerURL
                guard !PathIdentity.contains(executable, in: root) else {
                    throw PluginProcessError.commandNotBound(rule.command)
                }
                context.executables[rule.command] = executable
                continue
            }
            let search = ProcessEnvironment.setting(directories.map(\.path).joined(separator: String(separator)),
                                                     for: "PATH", in: environment)
            guard let executable = ToolLocator.executable(rule.command, environment: search),
                  !PathIdentity.contains(executable, in: root) else {
                throw PluginProcessError.commandNotBound(rule.command)
            }
            context.executables[rule.command] = executable
        }
        return context
    }
}
