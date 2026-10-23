import Foundation
import PluginRuntime

/// Bundled plugins that contribute tasks, with the permission their commands use.
struct TaskProvider: Sendable {
    let pluginID: String
    let contribution: TaskContribution
    let step: StepProvider

    static let bundled: [TaskProvider] = BundledPlugins.catalog.compactMap { plugin in
        guard let contribution = ((try? plugin.manifest.contributes.decode(TaskContributionPoint.self)) ?? []).first,
              let process = plugin.manifest.host.processes.first(where: { $0.entryPoints.contains(TaskContribution.entryPoint) })
        else { return nil }
        return TaskProvider(pluginID: plugin.id, contribution: contribution,
                            step: StepProvider(title: contribution.title, package: plugin.package,
                                               entryPoint: TaskContribution.entryPoint, process: process))
    }

    /// The first enabled provider whose marker is in `root`.
    static func provider(for root: URL) -> TaskProvider? {
        let disabled = (try? BundledPlugins.disabled(in: root.path)) ?? []
        return bundled.first { provider in
            !disabled.contains(provider.pluginID)
                && FileManager.default.fileExists(atPath: root.appendingPathComponent(provider.contribution.marker).path)
        }
    }
}
