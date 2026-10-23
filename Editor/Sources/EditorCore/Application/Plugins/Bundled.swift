import Foundation
import PluginRuntime

/// A plugin that ships in the editor's resources. Each is found by listing
/// `Resources/Plugins`; its manifest decides where it runs.
public struct BundledPlugin: Sendable, Equatable, Identifiable {
    public enum Host: Sendable, Equatable {
        /// Loaded into the shared plugin host, beside plugins the user adds.
        case application
        /// Declarative package with no component or WIT: registered in-process.
        case declarative
        /// Contributes a version control system.
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
    public var categories: [PluginCategory] {
        PluginCategory.categories(points: manifest.contributes.pointIDs, hasCapabilities: host != .declarative)
    }
}

enum BundledPlugins {
    /// Every package in `Resources/Plugins` whose manifest is valid.
    static let catalog: [BundledPlugin] = {
        let root = (EditorCoreResourceBundle.bundle.resourceURL ?? EditorCoreResourceBundle.bundle.bundleURL)
            .appendingPathComponent("Plugins", isDirectory: true)
        let packages = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return packages.filter { $0.pathExtension == "guavaplugin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { package in
                guard let validated = try? PluginPackageLoader().load(at: package) else { return nil }
                let manifest = validated.manifest
                let host: BundledPlugin.Host
                if let contribution = ((try? manifest.contributes.decode(VersionControlContributionPoint.self)) ?? []).first {
                    guard let system = VersionControlSystem(rawValue: contribution.id) else { return nil }
                    host = .versionControl(system)
                } else {
                    host = validated.runtime == nil ? .declarative : .application
                }
                return BundledPlugin(id: manifest.id, name: manifest.name, description: manifest.description,
                                     version: manifest.version, access: manifest.access.rawValue, host: host,
                                     commands: manifest.host.processes.map(\.command), package: package, manifest: manifest)
            }
    }()

    static func plugin(id: String) -> BundledPlugin? { catalog.first { $0.id == id } }

    /// The package whose language server the editor's language session drives.
    static var languageServer: URL? { plugin(id: PluginLanguageService.pluginID)?.package }

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
        pluginSession.manager.enabledManifests[plugin.id] != nil
    }

    /// Loads every bundled plugin the project has not switched off. Declarative
    /// packages register in-process; runtime packages enter the plugin host.
    public func enableBundledPlugins() {
        guard pluginSession.bundledStartup == nil else { return }
        pluginSession.bundledStartup = Task { @MainActor [weak self] in
            guard let self, !self.isShuttingDown else { return }
            let disabled = (try? BundledPlugins.disabled(in: self.projectDirectory)) ?? []
            for plugin in BundledPlugins.catalog where !disabled.contains(plugin.id) {
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                await self.enableBundledPlugin(plugin)
            }
            try? await self.activatePlugins(event: "onStartup")
            self.refreshContributionSnapshots()
            self.rebuildAgentSurfaces()
            await self.workstation.versionControl.refresh()
            await self.workstation.tasks.refresh()
        }
    }

    /// Turns a bundled plugin on or off for this project, wherever it runs.
    @MainActor
    public func setBundledPlugin(_ plugin: BundledPlugin, enabled: Bool) async {
        if enabled { await enableBundledPlugin(plugin) }
        else { await disablePluginFromManagement(id: plugin.id) }
        rebuildAgentSurfaces()
        await workstation.versionControl.refresh()
        await workstation.tasks.refresh()
    }

    /// Replaces data-domain snapshots without touching unrelated AI sessions.
    @MainActor
    func refreshContributionSnapshots() {
        let contributions = pluginSession.contributions
        let themes = contributions.themes.snapshot
        if pluginSession.themeRevision != themes.revision {
            pluginSession.themeRevision = themes.revision
            store.dispatch(.themeCatalogChanged)
        }
        let providers = contributions.providers.snapshot
        if pluginSession.providerRevision != providers.revision {
            pluginSession.providers = AIProviderCatalog(packages: providers.values.map(\.value))
            pluginSession.providerRevision = providers.revision
            pluginSession.aiProvider = pluginSession.providers.provider(
                id: store.state.assistant.aiSettings.providerID)
        }
        let languages = contributions.languages.snapshot
        if pluginSession.languageRevision != languages.revision {
            pluginSession.languages = LanguageCatalog(packages: languages.values.map(\.value))
            pluginSession.languageRevision = languages.revision
        }
        let agents = contributions.agents.snapshot
        if pluginSession.agentRevision != agents.revision {
            pluginSession.agents = AgentCatalog(packages: agents.values.map(\.value))
            pluginSession.agentRevision = agents.revision
        }
        displayInvalidationHandler?()
    }


    /// Bundled packages ship with the editor, so they are trusted as built and
    /// skip the review a package from disk gets.
    @MainActor
    private func enableBundledPlugin(_ plugin: BundledPlugin) async {
        guard pluginSession.manager.enabledManifests[plugin.id] == nil else { return }
        do {
            let inspection = try inspectPlugin(at: plugin.package)
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
