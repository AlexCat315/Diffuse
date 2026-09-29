import Foundation

struct ScriptLanguageWorkspace {
    struct Document: Sendable, Equatable {
        let scriptID: String
        let sourceURL: URL
        let analysisURL: URL
        let targetName: String
    }

    let scriptsDirectoryURL: URL
    let enginePackageURL: URL

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

    private func manifest(for documents: [Document]) -> String {
        let dependencies = [
            ".product(name: \"ScriptRuntime\", package: \"GuavaEngine\")",
            ".product(name: \"SceneRuntime\", package: \"GuavaEngine\")",
            ".product(name: \"SIMDCompat\", package: \"GuavaEngine\")",
        ].joined(separator: ",\n                ")
        let targets = documents.map { document in
            """
                    .target(
                        name: \(String(reflecting: document.targetName)),
                        dependencies: [\(dependencies)],
                        path: \(String(reflecting: "Sources/\(document.targetName)"))
                    )
            """
        }.joined(separator: ",\n")

        return """
        // swift-tools-version: 6.1
        import PackageDescription

        let package = Package(
            name: "GuavaScriptAnalysis",
            platforms: [.macOS(.v13)],
            dependencies: [
                .package(name: "GuavaEngine", path: \(String(reflecting: enginePackageURL.path)))
            ],
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