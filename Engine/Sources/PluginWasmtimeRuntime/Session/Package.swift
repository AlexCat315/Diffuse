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
            .appendingPathComponent("GuavaPlugin-\(UUID().uuidString).guavaplugin", isDirectory: true)
        #if os(Windows)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #endif
        do {
            for name in ["plugin.json", "capabilities.wit", "component.wasm"] {
                try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                                to: directory.appendingPathComponent(name))
            }
            package = try loader.load(at: directory)
            guard original.manifest == package.manifest,
                  original.witContract == package.witContract,
                  original.componentHash == package.componentHash,
                  original.witHash == package.witHash else { throw PluginAuthorizationError.noLongerValid }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
