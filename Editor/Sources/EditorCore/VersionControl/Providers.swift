import Foundation
import PluginRuntime

/// A bundled version control plugin and what its manifest contributes: the
/// system, the marker that finds its working trees and the command it runs.
struct VersionControlProvider: Sendable {
    let system: VersionControlSystem
    let manifest: GuavaPluginManifest
    let contribution: VersionControlContribution
    let package: URL
    let process: PluginProcessPermission

    var pluginID: String { manifest.id }

    /// In detection order: when one folder holds several markers, the higher
    /// `priority` wins (Lore over Git: it is the deliberate choice for assets).
    static let bundled: [VersionControlProvider] = BundledPlugins.catalog.compactMap { plugin in
        guard case let .versionControl(system) = plugin.host,
              let contribution = plugin.manifest.contributes.versionControl,
              let process = plugin.manifest.host.processes.first else { return nil }
        return VersionControlProvider(system: system, manifest: plugin.manifest, contribution: contribution,
                                      package: plugin.package, process: process)
    }.sorted { ($0.contribution.priority ?? 0) > ($1.contribution.priority ?? 0) }

    static func provider(for system: VersionControlSystem) -> VersionControlProvider? {
        bundled.first { $0.system == system }
    }

    /// The nearest working tree containing `directory` of a system not `excluding`.
    static func repository(containing directory: URL,
                           excluding disabled: Set<VersionControlSystem> = []) -> VersionControlRepository? {
        let fileManager = FileManager.default
        let providers = bundled.filter { !disabled.contains($0.system) }
        var components = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        while !components.isEmpty {
            let current = URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: true)
            // `.git` is a file inside worktrees and submodules.
            for provider in providers
            where fileManager.fileExists(atPath: current.appendingPathComponent(provider.contribution.marker).path) {
                return VersionControlRepository(system: provider.system, root: current.standardizedFileURL)
            }
            components.removeLast()
        }
        return nil
    }
}

