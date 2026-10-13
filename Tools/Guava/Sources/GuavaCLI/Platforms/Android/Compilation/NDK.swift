import Foundation

extension AndroidToolchain {
    /// Resolve the NDK for this invocation instead of changing the installed Swift SDK.
    func compilerOptions() throws -> [String] {
        struct Tool: Encodable {
            var path: String? = nil
            var extraCLIOptions: [String] = []
        }
        struct Toolset: Encodable {
            var schemaVersion = "1.0"
            let cCompiler: Tool
            let cxxCompiler: Tool
            let swiftCompiler: Tool
        }
        let host = try ndkHost()
        let resources = try Files.children(host.appendingPathComponent("lib/clang"))
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("include/stddef.h").path) }
        guard resources.count == 1 else { throw ToolError.invalid("Expected one NDK Clang resource directory") }
        let bin = host.appendingPathComponent("bin")
        let toolset = Toolset(cCompiler: Tool(path: bin.appendingPathComponent("clang").path),
            cxxCompiler: Tool(path: bin.appendingPathComponent("clang++").path),
            swiftCompiler: Tool(extraCLIOptions: ["-Xcc", "-resource-dir=\(resources[0].path)", "-tools-directory", bin.path, "-Xclang-linker", "-resource-dir=\(resources[0].path)",
                "-L", resources[0].appendingPathComponent("lib/linux/aarch64").path]))
        let directory = try AndroidSDKOverlay(toolchain: self, host: host).prepare(overrides: JSONEncoder().encode(toolset))
        return ["--swift-sdks-path", directory.path]
    }
}
