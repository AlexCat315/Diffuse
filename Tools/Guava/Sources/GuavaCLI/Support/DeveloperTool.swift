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
        // SwiftPM expands @file response arguments even after the product name.
        // Build first, then pass session/event files literally to the executable.
        let build = [swift, "build", "--package-path", package.path, "--jobs", "4"]
        try Shell.run(build + ["--product", "guava-dev"], at: root, environment: environment, quiet: quiet)
        let products = try Shell.run(build + ["--show-bin-path"], at: root, environment: environment, capture: true, quiet: true)
        #if os(Windows)
        let name = "guava-dev.exe"
        #else
        let name = "guava-dev"
        #endif
        let executable = URL(fileURLWithPath: products).appendingPathComponent(name)
        try Shell.run([executable.path] + arguments, at: root, environment: environment, quiet: quiet)
    }
}
