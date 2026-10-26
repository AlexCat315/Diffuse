private import CoveFileSystem
import CapabilityRuntime
import Foundation
import PluginRuntime

/// Owns an immutable execution copy for in-process mobile hosts. Never execute
/// directly from an author-controlled package after checking its authority.
final class ExecutionPackage: @unchecked Sendable {
    let package: ValidatedPluginPackage
    private let directory: URL

    init(at source: URL, registry: CapabilityRegistry) throws {
        let loader = PluginPackageLoader(registry: registry)
        let original = try loader.load(at: source)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CovePlugin-\(UUID().uuidString).coveplugin", isDirectory: true)
        try FilePermissions.createPrivateDirectory(at: directory, withIntermediateDirectories: false)
        do {
            for name in ["plugin.json", "capabilities.wit", "component.wasm"] + (original.resourceHashes.isEmpty ? [] : ["resources"]) {
                try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                                to: directory.appendingPathComponent(name))
            }
            package = try loader.load(at: directory)
            guard original.manifest == package.manifest,
                  original.runtime?.witContract == package.runtime?.witContract,
                  original.runtime?.componentHash == package.runtime?.componentHash,
                  original.runtime?.witHash == package.runtime?.witHash,
                  original.resourceHashes == package.resourceHashes else { throw PluginAuthorizationError.noLongerValid }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
