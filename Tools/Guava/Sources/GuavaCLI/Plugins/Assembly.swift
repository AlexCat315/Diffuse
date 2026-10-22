import Foundation

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
        let sources = try swiftFiles(in: directory.appendingPathComponent("Sources"))
        guard FileManager.default.fileExists(atPath: manifest.path), FileManager.default.fileExists(atPath: contract.path),
              !sources.isEmpty else {
            throw ToolError.invalid("A plugin directory needs plugin.json, capabilities.wit and Swift files in Sources/")
        }
        let toolchain = try EmbeddedWasmToolchain.locate()
        let host = try pluginHost()
        let scratch = directory.appendingPathComponent(".guava/build/plugin")
        try Files.reset(scratch)

        try Shell.run([host.path, "--component-shell", contract.path, scratch.path])
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
        try Shell.run([host.path, "--link-component", scratch.appendingPathComponent("shell.wat").path, core.path, component.path])

        let package = output ?? scratch.deletingLastPathComponent().appendingPathComponent("\(moduleName).guavaplugin")
        guard package.pathExtension == "guavaplugin" else { throw ToolError.invalid("--output must end in .guavaplugin") }
        try Files.reset(package)
        for (source, name) in [(manifest, "plugin.json"), (contract, "capabilities.wit"), (component, "component.wasm")] {
            try Files.copy(source, to: package.appendingPathComponent(name))
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
        return try Files.files(directory).filter { $0.pathExtension == "swift" }
    }

    /// GuavaPluginHost owns WIT parsing and Component compilation, so the
    /// build uses the same contract rules the editor enforces at load time.
    private func pluginHost() throws -> URL {
        let command = SwiftPackage.command(directory: root.appendingPathComponent("Engine"), configuration: .debug)
        try Shell.run(command + ["--product", "GuavaPluginHost"], environment: SwiftPackage.environment(root: root))
        let products = try Shell.run(command + ["--show-bin-path"], environment: SwiftPackage.environment(root: root), capture: true)
        #if os(Windows)
        return URL(fileURLWithPath: products).appendingPathComponent("GuavaPluginHost.exe")
        #else
        return URL(fileURLWithPath: products).appendingPathComponent("GuavaPluginHost")
        #endif
    }
}
