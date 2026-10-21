public import Foundation

extension SwiftToolchain {
    public func validateAnalysis(engineModulePaths: [String], clangModuleMapPaths: [String],
                                 clangIncludePaths: [String]) throws {
        let fileManager = FileManager.default
        for module in ["ScriptRuntime", "SceneRuntime"] {
            guard engineModulePaths.contains(where: {
                fileManager.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent("\(module).swiftmodule").path)
            }) else {
                throw SwiftToolchainError.unavailable("The Guava SDK is missing \(module).swiftmodule. Build the Editor with guava or configure GUAVA_ENGINE_MODULE_PATHS.")
            }
        }
        for path in clangModuleMapPaths where !fileManager.fileExists(atPath: path) {
            throw SwiftToolchainError.unavailable("A Guava SDK Clang module map is missing: \(path)")
        }
        for path in clangIncludePaths where !fileManager.fileExists(atPath: path) {
            throw SwiftToolchainError.unavailable("A Guava SDK include directory is missing: \(path)")
        }
        let directory = fileManager.temporaryDirectory.appendingPathComponent("guava-swift-preflight-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Environment.swift")
        try Data("import Swift\nimport ScriptRuntime\nimport SceneRuntime\nlet guavaStandardLibraryProbe: String = \"ready\"\n".utf8)
            .write(to: source)
        var arguments = ["-typecheck", "-module-cache-path", directory.appendingPathComponent("Modules").path]
        if let sdkURL { arguments.append(contentsOf: ["-sdk", sdkURL.path]) }
        for path in engineModulePaths { arguments.append(contentsOf: ["-I", path]) }
        for path in clangModuleMapPaths { arguments.append(contentsOf: ["-Xcc", "-fmodule-map-file=\(path)"]) }
        for path in clangIncludePaths { arguments.append(contentsOf: ["-Xcc", "-I\(path)"]) }
        arguments.append(source.path)
        do {
            _ = try SwiftToolchainResolver.probe(compilerURL, arguments: arguments, environment: environment)
        } catch {
            throw SwiftToolchainError.unavailable("Swift analysis environment validation failed. The selected compiler, macOS SDK and Guava modules must match.\n\(error.localizedDescription)")
        }
    }
}
