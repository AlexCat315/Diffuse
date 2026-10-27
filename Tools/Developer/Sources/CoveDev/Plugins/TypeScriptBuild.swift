internal import ToolSupport
internal import Foundation

struct PluginBuild {
    let directory: URL
    let root: URL
    let output: URL?
    func run() throws {
        #if os(Windows)
        let name = "bun.exe"
        #else
        let name = "bun"
        #endif
        let bun = root.appendingPathComponent("Engine/Sources/PluginRuntime/Resources/bun/" + name)
        guard FileManager.default.isExecutableFile(atPath: bun.path) else {
            throw ToolError.message("Run cove studio plugins prepare first")
        }
        let destination = output ?? directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".coveplugin")
        try Shell.inherit([bun.path, root.appendingPathComponent("PluginSDK/src/cli.ts").path,
                           "build", directory.path, destination.path])
    }
}
