import Foundation
import PluginRuntime

/// Enabled task declarations with the permission their commands use.
struct TaskProvider: Sendable {
    let pluginID: String
    let contribution: TaskContribution
    let step: StepProvider

    /// The first enabled provider whose marker is in `root`.
    static func provider(for root: URL, among providers: [TaskProvider]) -> TaskProvider? {
        providers.first { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.contribution.marker).path) }
    }

    static func registered(in packages: [ValidatedPluginPackage]) -> [TaskProvider] {
        packages.flatMap { package in
            ((try? package.manifest.contributes.decode(TaskContributionPoint.self)) ?? []).compactMap { contribution in
                guard let process = package.manifest.host.processes.first(where: { $0.entryPoints.contains(TaskContribution.entryPoint) }) else { return nil }
                return TaskProvider(pluginID: package.manifest.id, contribution: contribution,
                    step: StepProvider(pluginID: package.manifest.id, title: contribution.title, package: package.rootURL,
                        entryPoint: TaskContribution.entryPoint, activationEvent: "onCommand:" + contribution.id, process: process))
            }
        }
    }
}
