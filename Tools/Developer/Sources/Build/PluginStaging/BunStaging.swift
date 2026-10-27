internal import Foundation
internal import ToolSupport

struct BunCatalog: Decodable {
    struct Platform: Decodable { var archive: String; var sha256: String }
    var version: String
    var platforms: [String: Platform]
    static func read() throws -> BunCatalog {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: Repository.path("PluginSDK/runtime.json")))
    }
}
private struct BunProvenance: Codable {
    var version: String
    var platform: String
    var archiveSHA256: String
    var executableSHA256: String
}

package enum PluginStaging {
    package static func run(_ arguments: [String]) throws {
        guard let operation = arguments.first else { throw ToolError.message(usage) }
        let flags = Array(arguments.dropFirst())
        switch operation {
        case "stage": try stage(flags)
        case "prepare":
            guard flags.isEmpty else { throw ToolError.message(usage) }
            try stage([])
            let bun = binary()
            try Shell.inherit([bun.path, "install", "--frozen-lockfile", "--ignore-scripts"], at: Repository.root)
            try Shell.inherit([bun.path, "PluginSDK/src/build-bundled.ts"], at: Repository.root)
            try Shell.inherit([bun.path, "--no-macros", "PluginSDK/src/build-tools.ts"], at: Repository.root)
            try Shell.inherit([bun.path, "build", "PluginSDK/src/runner.ts", "--target=bun", "--format=esm", "--outfile", "Engine/Sources/PluginRuntime/Resources/bun-runner.js"], at: Repository.root)
        case "verify":
            guard flags.isEmpty else { throw ToolError.message(usage) }
            try stage(["--check"])
            try Shell.inherit([binary().path, "run", "--cwd", "PluginSDK", "check"], at: Repository.root)
            try Shell.inherit([binary().path, "test", "PluginSDK/tests"], at: Repository.root)
        case "--help", "-h": print(usage)
        default: throw ToolError.message(usage)
        }
    }

    static let usage = """
    cove studio plugins stage [--platform NAME] [--cache PATH] [--check]
    cove studio plugins prepare
    cove studio plugins verify
    Stages the pinned Bun desktop runtime, builds TypeScript plugins, and verifies the public SDK.
    """

    static func host() -> String {
        #if arch(arm64)
        let arm = true
        #else
        let arm = false
        #endif
        #if os(macOS)
        return arm ? "macos-arm64" : "macos-x86_64"
        #elseif os(Windows)
        return arm ? "windows-arm64" : "windows-x86_64"
        #else
        return arm ? "linux-aarch64" : "linux-x86_64"
        #endif
    }
    static func binary() -> URL {
        #if os(Windows)
        Repository.path("Engine/Sources/PluginRuntime/Resources/bun/bun.exe")
        #else
        Repository.path("Engine/Sources/PluginRuntime/Resources/bun/bun")
        #endif
    }
    private static func stage(_ arguments: [String]) throws {
        var parser = FlagParser(arguments, valued: ["--platform", "--cache"], switches: ["--check"])
        try parser.parse()
        if parser.flags.contains("--help") { print(usage); return }
        guard parser.positionals.isEmpty else { throw ToolError.message(usage) }
        let catalog = try BunCatalog.read(), platform = parser.values["--platform"] ?? host()
        guard let variant = catalog.platforms[platform], platform == host() else {
            throw ToolError.message("Stage Bun on the matching desktop host; unsupported target \(platform)")
        }
        if parser.flags.contains("--check") {
            guard ready(binary(), version: catalog.version, platform: platform, archive: variant.sha256) else {
                throw ToolError.message("Bun \(catalog.version) is not staged; run cove studio plugins prepare")
            }
            return
        }
        if ready(binary(), version: catalog.version, platform: platform, archive: variant.sha256) { return }
        let cache = parser.values["--cache"].map(absolutePath) ?? Repository.path("Engine/build/native/bun")
        let installed = try SourceArchive.fetch("https://github.com/oven-sh/bun/releases/download/bun-v\(catalog.version)/\(variant.archive).zip", variant.sha256, cache)
        let source = installed.appendingPathComponent(binary().lastPathComponent)
        let destination = binary()
        try Fs.directory(destination.deletingLastPathComponent())
        try Fs.copy(source, to: destination)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        #endif
        let provenance = BunProvenance(version: catalog.version, platform: platform,
            archiveSHA256: variant.sha256, executableSHA256: try SHA256.hex(file: destination))
        try JSONEncoder().encode(provenance).write(to: destination.deletingLastPathComponent().appendingPathComponent("runtime.json"), options: .atomic)
    }
    static func ready(_ executable: URL, version: String, platform: String, archive: String) -> Bool {
        guard let data = try? Data(contentsOf: executable.deletingLastPathComponent().appendingPathComponent("runtime.json")),
              let record = try? JSONDecoder().decode(BunProvenance.self, from: data) else { return false }
        return record.version == version && record.platform == platform && record.archiveSHA256 == archive
            && (try? SHA256.hex(file: executable)) == record.executableSHA256
    }
}
