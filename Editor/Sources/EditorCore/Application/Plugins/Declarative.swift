import Foundation
import PluginRuntime
public import GuavaUICompose

extension EditorApplication {
    public var themeCatalog: ThemeCatalogSnapshot { pluginSession.themes.snapshot }

    public func resolvedTheme(dark: Bool) -> Theme {
        pluginSession.themes.theme(id: store.presentation.themeID, dark: dark)
    }

    var enabledPluginManifests: [String: GuavaPluginManifest] {
        pluginSession.bindings.mapValues(\.inspection.manifest)
            .merging(pluginSession.declarativePlugins.mapValues(\.package.manifest)) { first, _ in first }
    }

    @MainActor
    func enableDeclarativePackage(_ package: ValidatedPluginPackage,
                                  authorization: PluginAuthorizationRecord) throws -> PluginInspection {
        let inspection = PluginInspection(package: package, contracts: [])
        guard package.runtime == nil, authorization.isStillValid(for: inspection) else {
            throw PluginAuthorizationError.noLongerValid
        }
        try EditorThemeCatalog.validate(package)
        let id = package.manifest.id
        let binding = DeclarativePluginBinding(package: package, authorization: authorization)
        pluginSession.declarativePlugins[id] = binding
        do {
            try refreshDeclarativeContributions()
            try pluginSession.authorizationStore.record(authorization)
            if BundledPlugins.plugin(id: id) != nil {
                try BundledPlugins.setEnabled(true, id: id, in: projectDirectory)
            }
        } catch {
            pluginSession.declarativePlugins.removeValue(forKey: id)
            try? refreshDeclarativeContributions()
            throw error
        }
        pluginSession.packageMonitor?.setPackages(pluginPackageURLs())
        return inspection
    }

    @MainActor
    func disableDeclarativePackage(id: String) throws {
        let dependents = PluginRequirementResolver.dependents(of: id, providing: [],
                                                             among: enabledPluginManifests)
        guard dependents.isEmpty else { throw RequiredPluginStillNeeded(pluginID: id, dependents: dependents) }
        if BundledPlugins.plugin(id: id) != nil {
            try BundledPlugins.setEnabled(false, id: id, in: projectDirectory)
        }
        pluginSession.declarativePlugins.removeValue(forKey: id)
        try refreshDeclarativeContributions()
        pluginSession.packageMonitor?.setPackages(pluginPackageURLs())
    }

    @MainActor
    func reloadDeclarativePackage(_ binding: DeclarativePluginBinding) throws {
        let package = try PluginPackageLoader().load(at: binding.package.rootURL)
        let inspection = PluginInspection(package: package, contracts: [])
        guard package.runtime == nil, binding.authorization.isStillValid(for: inspection) else {
            throw EditorPluginCapabilityError.pluginAuthorizationStale(package.manifest.id)
        }
        try EditorThemeCatalog.validate(package)
        pluginSession.declarativePlugins[package.manifest.id] = DeclarativePluginBinding(
            package: package, authorization: binding.authorization)
        do {
            try refreshDeclarativeContributions()
        } catch {
            pluginSession.declarativePlugins[package.manifest.id] = binding
            try? refreshDeclarativeContributions()
            throw error
        }
    }
}
