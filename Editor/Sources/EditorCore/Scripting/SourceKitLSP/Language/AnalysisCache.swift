private import CoveFileSystem
import Foundation

private struct ScriptAnalysisCacheIdentity: Codable, Equatable {
    struct File: Codable, Equatable {
        let path: String
        let modified: Date?
        let size: UInt64?

        init(_ url: URL) {
            path = url.resolvingSymlinksInPath().path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            modified = attributes?[.modificationDate] as? Date
            size = attributes?[.size] as? UInt64
        }
    }

    let workspace: String
    let executable: File
    let compiler: File?
    let sdk: File?
    let modules: [File]
    let flags: [String]

    static func moduleFiles(at url: URL) -> [File] {
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return [File(url)] + children.sorted { $0.path < $1.path }.map(File.init)
    }
}

extension ScriptLanguageWorkspace {
    func prepareScratch(executableURL: URL, environment: [String: String]) throws -> URL {
        let manager = FileManager.default
        let root = rootURL.resolvingSymlinksInPath()
        let scratch = rootURL.appendingPathComponent(".build", isDirectory: true)
        try validateGeneratedLocation(scratch)
        guard (try? scratch.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ScriptLanguageSupportError.unavailable("The generated Swift analysis cache must not be a symbolic link.")
        }
        let identity = ScriptAnalysisCacheIdentity(workspace: root.path, executable: .init(executableURL),
            compiler: environment["SWIFT_EXEC"].map { .init(URL(fileURLWithPath: $0)) },
            sdk: sdkURL.map { .init($0.appendingPathComponent("SDKSettings.json")) },
            modules: engineModulePaths.flatMap { path in
                ["ScriptRuntime.swiftmodule", "SceneRuntime.swiftmodule"].flatMap {
                    ScriptAnalysisCacheIdentity.moduleFiles(at: URL(fileURLWithPath: path).appendingPathComponent($0))
                }
            } + clangModuleMapPaths.map { .init(URL(fileURLWithPath: $0)) }, flags: includeFlags)
        let identityURL = rootURL.appendingPathComponent("analysis-environment.json")
        try validateGeneratedLocation(identityURL)
        let previous = (try? Data(contentsOf: identityURL)).flatMap { try? JSONDecoder().decode(ScriptAnalysisCacheIdentity.self, from: $0) }
        if previous != identity, manager.fileExists(atPath: scratch.path) { try manager.removeItem(at: scratch) }
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        try AtomicFile.write(JSONEncoder().encode(identity), to: identityURL)
        // The server also serves the project folder, so the scratch path is this
        // package's own setting rather than a command-line flag for every package.
        let configuration = rootURL.appendingPathComponent(".sourcekit-lsp/config.json")
        try validateGeneratedLocation(configuration)
        try manager.createDirectory(at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: ["swiftPM": ["scratchPath": scratch.path]], options: [.sortedKeys]), to: configuration)
        // Generated and machine-local: keep it out of the project's version control.
        try AtomicFile.write(Data("*\n".utf8), to: rootURL.appendingPathComponent(".gitignore"))
        return scratch
    }
}
