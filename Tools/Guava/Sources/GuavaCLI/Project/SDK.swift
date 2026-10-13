import Foundation

enum GuavaSDK {
    static func locate(_ arguments: Arguments, project: AppProject? = nil) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let root = arguments.url(.engineRoot)
            ?? environment["GUAVA_ENGINE_ROOT"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? project.map { URL(fileURLWithPath: $0.configuration.toolchain.enginePath, relativeTo: $0.directory).standardizedFileURL }
            ?? checkout(containing: URL(fileURLWithPath: #filePath))
        guard let root, isSDK(root) else {
            throw ToolError.invalid("Set GUAVA_ENGINE_ROOT or --engine-root to the Guava-Engine checkout")
        }
        return root
    }

    private static func isSDK(_ root: URL) -> Bool {
        ["Engine/Package.swift", "GuavaUI/Package.swift"].allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    private static func checkout(containing source: URL) -> URL? {
        var directory = source.deletingLastPathComponent()
        while directory.path != directory.deletingLastPathComponent().path {
            if isSDK(directory) { return directory }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    static var swift: String { ProcessInfo.processInfo.environment["GUAVA_SWIFT_EXECUTABLE"] ?? "swift" }
}
