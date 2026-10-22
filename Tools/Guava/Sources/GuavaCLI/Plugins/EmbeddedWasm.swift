import Foundation

/// The selected Swift toolchain's Embedded Swift WebAssembly support: the
/// compiler, `wasm-ld` and the embedded runtime libraries beside it.
struct EmbeddedWasmToolchain {
    static let target = "wasm32-unknown-none-wasm"
    let compiler: URL
    let linker: URL
    let libraries: URL

    static func locate() throws -> EmbeddedWasmToolchain {
        let swift = try Shell.executable(GuavaSDK.swift)
        #if os(Windows)
        let compiler = swift.deletingLastPathComponent().appendingPathComponent("swiftc.exe")
        let linkerName = "wasm-ld.exe"
        #else
        let compiler = swift.deletingLastPathComponent().appendingPathComponent("swiftc")
        let linkerName = "wasm-ld"
        #endif
        struct TargetInfo: Decodable {
            struct Paths: Decodable { let runtimeResourcePath: String }
            let paths: Paths
        }
        let info = try Shell.run([compiler.path, "-print-target-info", "-target", target], capture: true, quiet: true)
        let resources = URL(fileURLWithPath: try JSONDecoder().decode(TargetInfo.self, from: Data(info.utf8)).paths.runtimeResourcePath)
        let toolchain = EmbeddedWasmToolchain(
            compiler: compiler,
            linker: resources.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/\(linkerName)"),
            libraries: resources.appendingPathComponent("embedded/\(target)"))
        guard FileManager.default.fileExists(atPath: toolchain.linker.path),
              FileManager.default.fileExists(atPath: toolchain.libraries.path) else {
            throw ToolError.invalid("\(compiler.path) has no Embedded Swift WebAssembly support; use a Swift 6.4.1 toolchain from swift.org")
        }
        return toolchain
    }

    /// Compiles one module to an object file in a single whole-module job.
    func compile(module: String, sources: [URL], object: URL, flags: [String]) throws {
        try Shell.run([compiler.path, "-target", Self.target, "-enable-experimental-feature", "Embedded",
                       "-wmo", "-O", "-enforce-exclusivity=unchecked", "-parse-as-library", "-Xfrontend", "-disable-stack-protector",
                       "-module-name", module, "-c", "-o", object.path] + flags + sources.map(\.path))
    }

    /// Links a reactor module: no start function, only the declared exports.
    func link(objects: [URL], output: URL) throws {
        try Shell.run([linker.path, "--no-entry", "--gc-sections", "--strip-all", "-o", output.path]
            + objects.map(\.path) + [libraries.appendingPathComponent("libswiftUnicodeDataTables.a").path])
    }
}
