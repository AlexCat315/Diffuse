public import Foundation
import ProcessRuntime

extension SwiftToolchain {
    public func validateAnalysis(engineModulePaths: [String], clangModuleMapPaths: [String],
                                 clangIncludePaths: [String]) async throws {
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
        let moduleCache = SwiftToolchainPreferences.directory.appendingPathComponent("ModuleCache", isDirectory: true)
        try fileManager.createDirectory(at: moduleCache, withIntermediateDirectories: true)
        var arguments = ["-typecheck", "-module-cache-path", moduleCache.path]
        if let sdkURL { arguments.append(contentsOf: ["-sdk", sdkURL.path]) }
        for path in engineModulePaths { arguments.append(contentsOf: ["-I", path]) }
        for path in clangModuleMapPaths { arguments.append(contentsOf: ["-Xcc", "-fmodule-map-file=\(path)"]) }
        for path in clangIncludePaths { arguments.append(contentsOf: ["-Xcc", "-I\(path)"]) }
        arguments.append(source.path)
        do {
            var command = ProcessCommand(executable: compilerURL, directory: directory)
            command.arguments = arguments
            command.environment = environment
            var budget = ProcessBudget()
            budget.lifetimeMilliseconds = 120_000
            let output = try await ProcessRunner.run(command, budget: budget)
            guard output.status == 0 else {
                throw SwiftToolchainError.unavailable(String(decoding: output.stderr + output.stdout, as: UTF8.self))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SwiftToolchainError.unavailable("Swift analysis environment validation failed. The selected compiler, platform SDK and Guava modules must match.\n\(error.localizedDescription)")
        }
    }
}
