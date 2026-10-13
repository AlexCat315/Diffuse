import Foundation

/// User installation state is independent of authored application configuration.
struct SDKStore {
    struct Selection: Codable { let path: String }
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["GUAVA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".guava")
    }

    var selected: URL? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("sdk.json")),
              let selection = try? JSONDecoder().decode(Selection.self, from: data) else { return nil }
        return URL(fileURLWithPath: selection.path)
    }

    func use(_ root: URL) throws {
        guard GuavaSDK.isSDK(root) else { throw ToolError.invalid("Not a Guava SDK: \(root.path)") }
        try Files.json(Selection(path: root.standardizedFileURL.path), to: directory.appendingPathComponent("sdk.json"))
        print("Selected Guava SDK: \(root.path). Existing projects keep their authored SDK selection.")
    }

    func list() throws {
        let installed = directory.appendingPathComponent("sdks")
        if FileManager.default.fileExists(atPath: installed.path) {
            for sdk in try Files.children(installed).filter({ GuavaSDK.isSDK($0) }) { print(sdk.path) }
        }
        print("Selected: \(selected?.path ?? "none; install a source SDK or use an existing checkout")")
    }

    func install(source: String, revision: String) throws {
        guard !source.hasPrefix("-"), !revision.hasPrefix("-"), !revision.isEmpty else {
            throw ToolError.invalid("Supply a repository URL/path and --revision COMMIT_OR_TAG")
        }
        let staging = directory.appendingPathComponent("downloads/" + UUID().uuidString)
        try Files.directory(staging.deletingLastPathComponent())
        defer { try? Files.remove(staging) }
        try Shell.run(["git", "clone", "--no-checkout", "--", source, staging.path])
        try Shell.run(["git", "checkout", "--detach", revision], at: staging)
        let commit = try Shell.run(["git", "rev-parse", "HEAD"], at: staging, capture: true, quiet: true)
        guard commit.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil,
              GuavaSDK.isSDK(staging) else { throw ToolError.invalid("Revision is not a Guava SDK") }
        let target = directory.appendingPathComponent("sdks/" + commit)
        if !FileManager.default.fileExists(atPath: target.path) {
            try Shell.run(["git", "submodule", "update", "--init", "--recursive"], at: staging)
            try Files.directory(target.deletingLastPathComponent())
            try FileManager.default.moveItem(at: staging, to: target)
        }
        try use(target)
        print("Source SDK installed at immutable revision \(commit). Run guava setup for your target platform.")
    }
}
