import Foundation
import PluginRuntime

/// A plugin that ships in the editor's resources. Each is found by listing
/// `Resources/Plugins`; its manifest decides where it runs.
public struct BundledPlugin: Sendable, Equatable, Identifiable {
    public enum Host: Sendable, Equatable {
        /// Loaded into the shared plugin host, beside plugins the user adds.
        case application
        /// Drives a version control system from its own plugin host.
        case versionControl(VersionControlSystem)
    }

    public let id: String
    public let name: String
    public let description: String
    public let version: Int
    public let access: String
    public let host: Host
    /// Command-line tools its process permissions run.
    public let commands: [String]
    let package: URL
    let manifest: GuavaPluginManifest
}

enum BundledPlugins {
    /// Every package in `Resources/Plugins` whose manifest is valid.
    static let catalog: [BundledPlugin] = {
        let root = (EditorCoreResourceBundle.bundle.resourceURL ?? EditorCoreResourceBundle.bundle.bundleURL)
            .appendingPathComponent("Plugins", isDirectory: true)
        let packages = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return packages.filter { $0.pathExtension == "guavaplugin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { package in
                guard let data = try? Data(contentsOf: package.appendingPathComponent("plugin.json")),
                      let manifest = try? PluginManifestValidator.decodeAndValidate(data) else { return nil }
                let host: BundledPlugin.Host
                if let contribution = manifest.contributes.versionControl {
                    guard let system = VersionControlSystem(rawValue: contribution.id) else { return nil }
                    host = .versionControl(system)
                } else {
                    host = .application
                }
                return BundledPlugin(id: manifest.id, name: manifest.name, description: manifest.description,
                                     version: manifest.version, access: manifest.access.rawValue, host: host,
                                     commands: manifest.host.processes.map(\.command), package: package, manifest: manifest)
            }
    }()

    static func plugin(id: String) -> BundledPlugin? { catalog.first { $0.id == id } }

    static var swiftSupport: URL { plugin(id: PluginLanguageService.pluginID)!.package }

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
    /// Every bundled plugin, wherever it runs, in the order Settings lists them.
    public var bundledPlugins: [BundledPlugin] { BundledPlugins.catalog }

    /// Whether a bundled plugin is on for this project.
    @MainActor
    public func isBundledPluginEnabled(_ plugin: BundledPlugin) -> Bool {
        switch plugin.host {
        case .application: pluginSession.bindings[plugin.id] != nil
        case let .versionControl(system): !workstation.versionControl.snapshot.disabledSystems.contains(system)
        }
    }

    /// Loads every application-hosted bundled plugin the project has not switched off.
    public func enableBundledPlugins() {
        guard pluginSession.bundledStartup == nil else { return }
        pluginSession.bundledStartup = Task { @MainActor [weak self] in
            guard let self, !self.isShuttingDown else { return }
            let disabled = (try? BundledPlugins.disabled(in: self.projectDirectory)) ?? []
            for plugin in BundledPlugins.catalog where plugin.host == .application && !disabled.contains(plugin.id) {
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                await self.enableBundledPlugin(plugin)
            }
        }
    }

    /// Turns a bundled plugin on or off for this project, wherever it runs.
    @MainActor
    public func setBundledPlugin(_ plugin: BundledPlugin, enabled: Bool) async {
        switch plugin.host {
        case .application:
            if enabled {
                await enableBundledPlugin(plugin)
            } else {
                await disablePluginFromManagement(id: plugin.id)
            }
        case let .versionControl(system):
            await workstation.versionControl.setEnabled(enabled, system: system)
        }
    }

    /// Bundled packages ship with the editor, so they are trusted as built and
    /// skip the review a package from disk gets.
    @MainActor
    private func enableBundledPlugin(_ plugin: BundledPlugin) async {
        guard pluginSession.bindings[plugin.id] == nil else { return }
        do {
            let client = try resolvedPluginHostClient()
            let inspection = try await Task.detached { try client.inspectPlugin(at: plugin.package) }.value
            guard inspection.manifest.id == plugin.id else { throw PluginAuthorizationError.noLongerValid }
            try await enablePlugin(at: plugin.package, authorization: PluginAuthorizationRecord(inspection: inspection))
            publishPluginManagement(phase: .idle, candidate: nil, message: nil)
        } catch {
            guard !isShuttingDown else { return }
            logConsole("\(plugin.name) could not start", severity: .warning, detail: Self.pluginManagementErrorMessage(error))
            publishPluginManagement(phase: .failed, candidate: nil,
                                    message: plugin.name + ": " + Self.pluginManagementErrorMessage(error))
        }
    }
}
