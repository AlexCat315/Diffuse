import Foundation

struct ScriptLanguageWorkspace {
    struct Document: Sendable, Equatable {
        let scriptID: String
        let sourceURL: URL
        let analysisURL: URL
        let targetName: String
    }

    let scriptsDirectoryURL: URL
    /// `-I` paths to already-built `.swiftmodule` files, matching exactly what
    /// `SwiftScriptCompiler` passes for script compilation.
    let engineModulePaths: [String]
    let clangModuleMapPaths: [String]
    let clangIncludePaths: [String]

    var rootURL: URL {
        scriptsDirectoryURL
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("sourcekit-lsp", isDirectory: true)
    }

    var packageManifestURL: URL {
        rootURL.appendingPathComponent("Package.swift")
    }

    func synchronize(_ scripts: [(DynamicScriptManager.ScriptFile, String)]) throws -> [String: Document] {
        let fileManager = FileManager.default
        let sourcesURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourcesURL, withIntermediateDirectories: true)

        let documents = scripts.map { file, _ in
            let targetName = Self.targetName(for: file.identifier)
            let targetDirectory = sourcesURL.appendingPathComponent(targetName, isDirectory: true)
            return Document(scriptID: file.identifier,
                            sourceURL: file.url,
                            analysisURL: targetDirectory.appendingPathComponent("GameScript.swift"),
                            targetName: targetName)
        }
        let activeTargets = Set(documents.map(\.targetName))

        for (file, source) in scripts {
            guard let document = documents.first(where: { $0.scriptID == file.identifier }) else { continue }
            try fileManager.createDirectory(at: document.analysisURL.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
            try writeIfChanged(source, to: document.analysisURL)
        }

        if let children = try? fileManager.contentsOfDirectory(at: sourcesURL,
                                                               includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children where child.lastPathComponent.hasPrefix("Script_")
                && !activeTargets.contains(child.lastPathComponent) {
                try? fileManager.removeItem(at: child)
            }
        }

        try writeIfChanged(manifest(for: documents), to: packageManifestURL)
        return Dictionary(uniqueKeysWithValues: documents.map { ($0.scriptID, $0) })
    }

    func writeAnalysisSource(_ source: String, to document: Document) throws {
        try writeIfChanged(source, to: document.analysisURL)
    }

    static func targetName(for scriptID: String) -> String {
        let base = scriptID.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
        let stableHash = scriptID.utf8.reduce(UInt64(0xcbf29ce484222325)) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "Script_\(base)_\(String(stableHash, radix: 16))"
    }

    /// `-I` / `-Xcc` flags each analysis target needs to resolve engine modules
    /// without building them. This is the same include set ``SwiftScriptCompiler``
    /// uses, so the language server sees *exactly* the same modules as the
    /// dynamic-script compiler — instead of trying to build the whole engine
    /// package (which pulls wgpu/SDL3/Jolt and never finishes).
    private var includeFlags: [String] {
        var flags: [String] = []
        for path in engineModulePaths { flags.append(contentsOf: ["-I", path]) }
        for path in clangIncludePaths { flags.append(contentsOf: ["-Xcc", "-I\(path)"]) }
        for path in clangModuleMapPaths { flags.append(contentsOf: ["-Xcc", "-fmodule-map-file=\(path)"]) }
        return flags
    }

    private func manifest(for documents: [Document]) -> String {
        let settings = ".unsafeFlags([\(includeFlags.map(String.init(reflecting:)).joined(separator: ", "))])"
        let targets = documents.map { document in
            """
                    .target(
                        name: \(String(reflecting: document.targetName)),
                        path: \(String(reflecting: "Sources/\(document.targetName)")),
                        swiftSettings: [\(settings)]
                    )
            """
        }.joined(separator: ",\n")

        return """
        // swift-tools-version: 6.1
        import PackageDescription

        let package = Package(
            name: "GuavaScriptAnalysis",
            platforms: [.macOS(.v13)],
            targets: [
        \(targets)
            ]
        )
        """
    }

    private func writeIfChanged(_ contents: String, to url: URL) throws {
        if let current = try? String(contentsOf: url, encoding: .utf8), current == contents {
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
    }
}