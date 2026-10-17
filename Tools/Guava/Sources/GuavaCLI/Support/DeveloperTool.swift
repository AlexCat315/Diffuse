import Foundation

/// Bridges the application CLI to the repository tooling package.
///
/// Native dependency staging (FFmpeg, SDL3, Jolt, FreeType, HarfBuzz, Wasmtime)
/// lives in `Tools/Developer`; the CLI runs that first-party Swift tool instead
/// of carrying a second copy of the build recipes.
enum DeveloperTool {
    static func run(_ arguments: [String], root: URL,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    quiet: Bool = false) throws {
        let package = root.appendingPathComponent("Tools/Developer")
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("Package.swift").path) else {
            throw ToolError.invalid("Developer tooling not found at \(package.path); use a source checkout of the SDK")
        }
        let swift = environment["GUAVA_SWIFT_EXECUTABLE"] ?? "swift"
        var environment = environment
        environment["GUAVA_ROOT"] = root.path
        try Shell.run([swift, "run", "--package-path", package.path, "guava-dev"] + arguments,
                      at: root, environment: environment, quiet: quiet)
    }
}
