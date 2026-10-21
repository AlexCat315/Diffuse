import Foundation
import PluginRuntime

extension EditorApplication {
    /// The host resolves tools from its launch environment, never a package's
    /// environment or a project's bin directory. The approved permission still
    /// restricts command, arguments and environment on every invocation.
    func pluginProcessContext(for permissions: PluginHostPermissions) throws -> PluginProcessContext {
        let root = URL(fileURLWithPath: projectDirectory).resolvingSymlinksInPath()
        var context = PluginProcessContext(workspace: root)
        let separator: Character = ProcessInfo.processInfo.operatingSystemVersionString.contains("Windows") ? ";" : ":"
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: separator).compactMap { item -> URL? in
            let path = String(item)
            guard NSString(string: path).isAbsolutePath else { return nil }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard url.path != root.path, !url.path.hasPrefix(root.path + "/") else { return nil }
            return url
        }
        for rule in permissions.processes {
            if rule.command == "sourcekit-lsp" {
                let executable = try SwiftToolchainResolver.resolve().languageServerURL
                let resolved = executable.resolvingSymlinksInPath()
                guard resolved.path != root.path, !resolved.path.hasPrefix(root.path + "/") else {
                    throw PluginProcessError.commandNotBound(rule.command)
                }
                context.executables[rule.command] = executable
                continue
            }
            #if os(Windows)
            let names = [rule.command + ".exe", rule.command]
            #else
            let names = [rule.command]
            #endif
            let executable = directories.lazy.flatMap { directory in names.map { directory.appendingPathComponent($0) } }
                .first {
                    let resolved = $0.resolvingSymlinksInPath()
                    return FileManager.default.isExecutableFile(atPath: $0.path)
                        && resolved.path != root.path && !resolved.path.hasPrefix(root.path + "/")
                }
            guard let executable else { throw PluginProcessError.commandNotBound(rule.command) }
            context.executables[rule.command] = executable
        }
        return context
    }
}
