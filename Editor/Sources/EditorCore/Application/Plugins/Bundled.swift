import Foundation
import PluginRuntime

enum BundledPlugins {
    static var swiftSupport: URL {
        (EditorCoreResourceBundle.bundle.resourceURL ?? EditorCoreResourceBundle.bundle.bundleURL)
            .appendingPathComponent("Plugins/SwiftSupport.guavaplugin", isDirectory: true)
    }

    static func disabled(in project: String) throws -> Set<String> {
        let url = preferences(in: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))
    }

    static func setEnabled(_ enabled: Bool, id: String, in project: String) throws {
        var disabled = try disabled(in: project)
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        let url = preferences(in: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(disabled.sorted()).write(to: url, options: .atomic)
    }

    private static func preferences(in project: String) -> URL {
        URL(fileURLWithPath: project).appendingPathComponent(".guava/disabled_bundled_plugins.json")
    }
}

extension EditorApplication {
    public func enableBundledPlugins() {
        guard pluginSession.bundledStartup == nil else { return }
        pluginSession.bundledStartup = Task { @MainActor [weak self] in
            guard let self, !self.isShuttingDown else { return }
            do {
                guard try !BundledPlugins.disabled(in: self.projectDirectory).contains(PluginLanguageService.pluginID) else { return }
                let client = try self.resolvedPluginHostClient()
                let url = BundledPlugins.swiftSupport
                let inspection = try await Task.detached { try client.inspectPlugin(at: url) }.value
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                guard inspection.manifest.id == PluginLanguageService.pluginID else { throw PluginAuthorizationError.noLongerValid }
                let authorization = try PluginAuthorizationRecord(inspection: inspection)
                try await self.enablePlugin(at: url, authorization: authorization)
                self.publishPluginManagement(phase: .idle, candidate: nil, message: nil)
            } catch {
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                self.logConsole("Swift Support could not start", severity: .warning,
                    detail: Self.pluginManagementErrorMessage(error))
                self.publishPluginManagement(phase: .failed, candidate: nil,
                    message: "Swift Support: " + Self.pluginManagementErrorMessage(error))
            }
        }
    }

    @MainActor
    public func inspectBundledSwiftSupport() async {
        await inspectPluginForManagement(at: BundledPlugins.swiftSupport)
    }
}
