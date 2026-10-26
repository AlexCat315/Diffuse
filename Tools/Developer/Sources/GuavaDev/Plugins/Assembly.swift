internal import ToolSupport
internal import Foundation

/// `guava plugin build`: compiles a plugin's Swift sources with GuavaPluginKit
/// into an Embedded Swift core module, wraps it in the Component its
/// `capabilities.wit` describes and assembles the `.guavaplugin` package.
///
/// A plugin directory holds `plugin.json`, `capabilities.wit` and `Sources/`.
struct PluginBuild {
    let directory: URL
    let root: URL
    let output: URL?

    func run() throws {
        let manifest = directory.appendingPathComponent("plugin.json")
        let contract = directory.appendingPathComponent("capabilities.wit")
        guard FileManager.default.fileExists(atPath: manifest.path),
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else {
            throw ToolError.message("A plugin directory needs plugin.json")
        }
        let hasContract = FileManager.default.fileExists(atPath: contract.path)
        if !hasContract && object["runtime"] == nil {
            let package = output ?? directory.appendingPathComponent(".build/\(moduleName).guavaplugin")
            try assemble(manifest: manifest, runtime: [], package: package, object: object)
            return
        }
        let sources = try swiftFiles(in: directory.appendingPathComponent("Sources"))
        guard hasContract,
              !sources.isEmpty else {
            throw ToolError.message("A plugin directory needs plugin.json, capabilities.wit and Swift files in Sources/")
        }
        let toolchain = try EmbeddedWasmToolchain.locate()
        let host = try pluginHost()
        let scratch = directory.appendingPathComponent(".build/plugin")
        try Fs.reset(scratch)

        try Shell.inherit([host.path, "--component-shell", contract.path, scratch.path])
        let kit = scratch.appendingPathComponent("GuavaPluginKit.o")
        try toolchain.compile(module: "GuavaPluginKit", sources: swiftFiles(in: root.appendingPathComponent("Engine/PluginKit")),
            object: kit, flags: ["-enable-experimental-feature", "Extern", "-parse-stdlib",
                                 "-emit-module-path", scratch.appendingPathComponent("GuavaPluginKit.swiftmodule").path])
        let plugin = scratch.appendingPathComponent("Plugin.o")
        try toolchain.compile(module: moduleName, sources: sources + [scratch.appendingPathComponent("Exports.swift")],
                              object: plugin, flags: ["-I", scratch.path])
        let core = scratch.appendingPathComponent("core.wasm")
        try toolchain.link(objects: [kit, plugin], output: core)
        let component = scratch.appendingPathComponent("component.wasm")
        try Shell.inherit([host.path, "--link-component", scratch.appendingPathComponent("shell.wat").path, core.path, component.path])

        let package = output ?? scratch.deletingLastPathComponent().appendingPathComponent("\(moduleName).guavaplugin")
        try assemble(manifest: manifest, runtime: [(contract, "capabilities.wit"), (component, "component.wasm")],
                     package: package, object: object)
    }

    private func assemble(manifest: URL, runtime: [(URL, String)], package: URL,
                          object: [String: Any]) throws {
        guard package.pathExtension == "guavaplugin", package.standardizedFileURL != directory.standardizedFileURL else {
            throw ToolError.message("--output must be a separate .guavaplugin directory")
        }
        let resources = try (object["resources"] as? [[String: Any]] ?? []).map { resource -> (URL, String) in
            guard let path = resource["path"] as? String else { throw ToolError.message("A resource needs a path") }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.first == "resources", !path.contains("\\"), !path.contains(":"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw ToolError.message("Invalid resource path: \(path)")
            }
            var source = directory
            for part in parts {
                source.appendPathComponent(String(part))
                guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw ToolError.message("Symbolic links are not allowed in plugin resources")
                }
            }
            return (source, path)
        }
        try Fs.reset(package)
        for (source, name) in [(manifest, "plugin.json")] + runtime + resources {
            try FileManager.default.createDirectory(at: package.appendingPathComponent(name).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Fs.copy(source, to: package.appendingPathComponent(name))
        }
        print("Built plugin: \(package.path)")
    }

    /// The plugin's Swift module, named after its directory.
    private var moduleName: String {
        let name = directory.lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.first?.isLetter == true ? name : "Plugin"
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try Fs.files(in: directory).filter { $0.pathExtension == "swift" }
    }

    /// GuavaPluginHost owns WIT parsing and Component compilation, so the
    /// build uses the same contract rules the editor enforces at load time.
    private func pluginHost() throws -> URL {
        let command = [ProcessInfo.processInfo.environment["GUAVA_SWIFT_EXECUTABLE"] ?? "swift", "build", "--package-path", root.appendingPathComponent("Engine").path, "--jobs", "4"]
        try Shell.inherit(command + ["--product", "GuavaPluginHost"])
        let products = try Shell.output(command + ["--show-bin-path"])
        #if os(Windows)
        return URL(fileURLWithPath: products).appendingPathComponent("GuavaPluginHost.exe")
        #else
        return URL(fileURLWithPath: products).appendingPathComponent("GuavaPluginHost")
        #endif
    }
}
