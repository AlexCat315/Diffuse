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
              let contribution = ((try? plugin.manifest.contributes.decode(VersionControlContributionPoint.self)) ?? []).first,
              let process = plugin.manifest.host.processes.first else { return nil }
        return VersionControlProvider(system: system, manifest: plugin.manifest, contribution: contribution,
                                      package: plugin.package, process: process)
    }.sorted { ($0.contribution.priority ?? 0) > ($1.contribution.priority ?? 0) }

    static func provider(for system: VersionControlSystem) -> VersionControlProvider? {
        bundled.first { $0.system == system }
    }

    var step: StepProvider {
        StepProvider(title: contribution.title, package: package, entryPoint: VersionControlContribution.entryPoint, process: process)
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


extension StepPlugins {
    /// Systems whose command-line tool is installed.
    var installedSystems: Set<VersionControlSystem> {
        Set(VersionControlProvider.bundled.filter { ContributionTool.locate($0.process.command) != nil }.map(\.system))
    }

    func backend(for repository: VersionControlRepository) throws -> any VersionControlBackend {
        PluginBackend(repository: repository, plugin: try plugin(for: repository.system, workspace: repository.root))
    }

    /// The plugin for `system`, running its commands in `workspace`.
    func plugin(for system: VersionControlSystem, workspace: URL) throws -> StepPlugin {
        guard let provider = VersionControlProvider.provider(for: system) else {
            throw VersionControlError.unsupported("The \(system.rawValue) plugin is missing from this build.")
        }
        do {
            return try plugin(for: provider.step, workspace: workspace)
        } catch StepError.toolMissing {
            throw VersionControlError.toolMissing(system)
        }
    }
}
