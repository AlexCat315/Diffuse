import EditorCore
import Foundation
import ScriptRuntime

public enum GameProjectScriptLoadError: Error, CustomStringConvertible, Equatable {
    case unsupportedVersion(Int)
    case incompatibleTarget(String)
    case invalidIdentifier(String)
    case invalidLibraryPath(String)
    case corruptedLibrary(String)
    case missingBindings([String])

    public var description: String {
        switch self {
        case let .unsupportedVersion(version): return "unsupported compiled script version: \(version)"
        case let .incompatibleTarget(target): return "compiled scripts target \(target), expected \(ProjectCompiledScripts.currentTarget)"
        case let .invalidIdentifier(identifier): return "invalid or duplicate compiled script identifier: \(identifier)"
        case let .invalidLibraryPath(path): return "compiled script library escapes the project: \(path)"
        case let .corruptedLibrary(path): return "compiled script library checksum mismatch: \(path)"
        case let .missingBindings(bindings): return "unresolved game script bindings: \(bindings.joined(separator: ", "))"
        }
    }
}

/// Loads only precompiled artifacts; Player never invokes a compiler or executes sources.
public final class GameProjectScriptLoader {
    private let loader = SwiftScriptLoader()

    public init() {}

    @discardableResult
    public func load(projectDirectory: URL, into runtime: ScriptRuntime) throws -> [ProjectCompiledScripts.Entry] {
        let manifestURL = projectDirectory.appendingPathComponent(ProjectCompiledScripts.relativePath)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let manifest = try JSONDecoder().decode(ProjectCompiledScripts.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == ProjectCompiledScripts.currentVersion else {
            throw GameProjectScriptLoadError.unsupportedVersion(manifest.version)
        }
        guard manifest.target == ProjectCompiledScripts.currentTarget else {
            throw GameProjectScriptLoadError.incompatibleTarget(manifest.target)
        }
        let root = projectDirectory.resolvingSymlinksInPath().standardizedFileURL
        var identifiers = Set(runtime.registeredScriptIdentifiers)
        var libraries: [(ProjectCompiledScripts.Entry, URL)] = []
        for entry in manifest.entries {
            for identifier in [entry.identifier] + entry.legacyIdentifiers {
                guard identifier.hasPrefix("scripts."), identifiers.insert(identifier).inserted else {
                    throw GameProjectScriptLoadError.invalidIdentifier(identifier)
                }
            }
            guard let relativePath = AssetImportResolver.sanitizedRelativePath(entry.libraryPath),
                  relativePath.hasPrefix("Scripts/Compiled/") else {
                throw GameProjectScriptLoadError.invalidLibraryPath(entry.libraryPath)
            }
            let library = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
            guard library.path.hasPrefix(root.path + "/") else {
                throw GameProjectScriptLoadError.invalidLibraryPath(entry.libraryPath)
            }
            guard ProjectCompiledScripts.digest(of: try Data(contentsOf: library)) == entry.sha256 else {
                throw GameProjectScriptLoadError.corruptedLibrary(entry.libraryPath)
            }
            libraries.append((entry, library))
        }
        // Validate the entire document before mapping any project code. Register
        // factories only after all libraries have loaded successfully.
        let factories = try libraries.map { entry, library in
            (entry, try loader.loadFactory(scriptID: entry.identifier, libraryPath: library.path))
        }
        for (entry, factory) in factories {
            for identifier in [entry.identifier] + entry.legacyIdentifiers {
                runtime.register(named: identifier, definition: loader.definition(scriptID: entry.identifier), factory)
            }
        }
        return manifest.entries
    }
}
