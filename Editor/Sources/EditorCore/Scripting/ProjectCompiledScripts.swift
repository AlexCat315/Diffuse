import CapabilityRuntime
import Foundation
import ScriptRuntime

/// Host-owned compiler configuration. It is never read from project files.
public struct ProjectScriptBuildConfiguration: Sendable {
    public var engineModulePaths: [String]
    public var clangModuleMapPaths: [String]
    public var clangIncludePaths: [String]
    public var swiftCompilerPath: String

    public init(engineModulePaths: [String],
                clangModuleMapPaths: [String] = [],
                clangIncludePaths: [String] = [],
                swiftCompilerPath: String = "swiftc") {
        self.engineModulePaths = engineModulePaths
        self.clangModuleMapPaths = clangModuleMapPaths
        self.clangIncludePaths = clangIncludePaths
        self.swiftCompilerPath = swiftCompilerPath
    }

    /// Finds the SDK beside a development host (both SwiftPM build layouts).
    /// Installed SDKs can supply the existing GUAVA_ENGINE_* host overrides.
    public static func discover(for executableURL: URL,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        func configuredPaths(_ key: String) -> [String]? {
            guard let value = environment[key], !value.isEmpty else { return nil }
            return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let buildDirectory = executableURL.deletingLastPathComponent()
        let modulePaths = configuredPaths("GUAVA_ENGINE_MODULE_PATHS") ??
            [buildDirectory, buildDirectory.appendingPathComponent("Modules", isDirectory: true)]
                .filter { directory in
                    ["SceneRuntime", "ScriptRuntime"].allSatisfy {
                        FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0).swiftmodule").path)
                    }
                }.map(\.path)
        var discoveredMaps: [String] = []
        let generatedMaps = buildDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Intermediates.noindex/GeneratedModuleMaps", isDirectory: true)
        for directory in [buildDirectory, generatedMaps] {
            for child in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                if child.pathExtension == "modulemap", child.lastPathComponent.hasPrefix("C") {
                    discoveredMaps.append(child.path)
                } else if child.pathExtension == "build", child.lastPathComponent.hasPrefix("C") {
                    let moduleMap = child.appendingPathComponent("module.modulemap")
                    if FileManager.default.fileExists(atPath: moduleMap.path) { discoveredMaps.append(moduleMap.path) }
                }
            }
        }
        var moduleMaps = configuredPaths("GUAVA_ENGINE_CLANG_MODULE_MAP_PATHS") ?? discoveredMaps.sorted()
        var includePaths = Set(moduleMaps.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        let regex = try? NSRegularExpression(pattern: #"umbrella\s+"([^"]+)""#)
        for path in moduleMaps {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
                  let match = regex?.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
                  let range = Range(match.range(at: 1), in: contents) else { continue }
            let includeDirectory = URL(fileURLWithPath: String(contents[range]),
                                       relativeTo: URL(fileURLWithPath: path).deletingLastPathComponent()).standardizedFileURL
            includePaths.insert(includeDirectory.path)
            if configuredPaths("GUAVA_ENGINE_CLANG_MODULE_MAP_PATHS") == nil {
                let bridgeRoot = includeDirectory.deletingLastPathComponent().deletingLastPathComponent()
                for bridge in (try? FileManager.default.contentsOfDirectory(at: bridgeRoot, includingPropertiesForKeys: nil)) ?? [] {
                    let moduleMap = bridge.appendingPathComponent("include/module.modulemap")
                    if FileManager.default.fileExists(atPath: moduleMap.path) { moduleMaps.append(moduleMap.path) }
                }
            }
        }
        moduleMaps = Array(Set(moduleMaps)).sorted()
        includePaths.formUnion(moduleMaps.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        return Self(engineModulePaths: modulePaths,
                    clangModuleMapPaths: moduleMaps,
                    clangIncludePaths: configuredPaths("GUAVA_ENGINE_CLANG_INCLUDE_PATHS") ?? includePaths.sorted(),
                    swiftCompilerPath: DynamicScriptManager.resolvedCompilerPath(environment: environment))
    }
}

/// Precompiled game code: Player loads these artifacts without a Swift toolchain.
public struct ProjectCompiledScripts: Codable, Sendable, Equatable {
    public static let relativePath = "Scripts/compiled-scripts.json"
    public static let currentVersion = 1
    public static var currentTarget: String {
        #if os(macOS)
        let platform = "macos"
        #elseif os(Linux)
        let platform = "linux"
        #elseif os(Windows)
        let platform = "windows"
        #else
        let platform = "unknown"
        #endif
        #if arch(arm64)
        return "\(platform)-arm64"
        #elseif arch(x86_64)
        return "\(platform)-x86_64"
        #else
        return "\(platform)-unknown"
        #endif
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var identifier: String
        public var displayName: String
        public var legacyIdentifiers: [String]
        public var libraryPath: String
        public var sha256: String

        public init(identifier: String, displayName: String,
                    legacyIdentifiers: [String] = [], libraryPath: String, sha256: String) {
            self.identifier = identifier
            self.displayName = displayName
            self.legacyIdentifiers = legacyIdentifiers
            self.libraryPath = libraryPath
            self.sha256 = sha256
        }
    }

    public var version: Int
    public var target: String
    public var entries: [Entry]

    public init(entries: [Entry], version: Int = currentVersion, target: String = currentTarget) {
        self.version = version
        self.target = target
        self.entries = entries
    }

    public static func digest(of data: Data) -> String { CapabilityDigest.sha256(data) }

    static func build(from projectDirectory: URL,
                      configuration: ProjectScriptBuildConfiguration?,
                      into outputDirectory: URL) throws -> Set<String> {
        let fileManager = FileManager.default
        let scriptsDirectory = projectDirectory.appendingPathComponent("Scripts", isDirectory: true)
        guard fileManager.fileExists(atPath: scriptsDirectory.path) else { return [] }
        let sources = try fileManager.contentsOfDirectory(at: scriptsDirectory,
                                                         includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension.lowercased() == "swift" }
        guard !sources.isEmpty else { return [] }
        guard let configuration, !configuration.engineModulePaths.isEmpty else {
            throw ProjectExporterError.missingScriptBuildConfiguration
        }
        // The existing Windows script bridge exports only a subset of C operations;
        // Swift ScriptBehavior libraries need the full host Swift symbol surface.
        #if os(Windows)
        throw ProjectExporterError.unsupportedScriptExportTarget(currentTarget)
        #else
        let assets = try ScriptAssetRegistry(projectDirectory: projectDirectory.path).resolve(sources)
        let aliasCounts = assets.flatMap(\.legacyIdentifiers).reduce(into: [String: Int]()) {
            $0[$1, default: 0] += 1
        }
        let compiledDirectory = outputDirectory.appendingPathComponent("Scripts/Compiled", isDirectory: true)
        let compiler = SwiftScriptCompiler(swiftcPath: configuration.swiftCompilerPath,
                                            includePaths: configuration.engineModulePaths,
                                            clangModuleMapPaths: configuration.clangModuleMapPaths,
                                            clangIncludePaths: configuration.clangIncludePaths,
                                            outputDirectory: compiledDirectory,
                                            hostModuleName: "GuavaPlayer")
        var entries: [Entry] = []
        for asset in assets {
            let result = try compiler.compile(sourcePath: asset.url.path, scriptID: asset.id.runtimeIdentifier)
            let library = URL(fileURLWithPath: result.outputPath)
            entries.append(Entry(identifier: asset.id.runtimeIdentifier,
                                 displayName: asset.url.deletingPathExtension().lastPathComponent,
                                 legacyIdentifiers: asset.legacyIdentifiers.filter {
                                     $0 != asset.id.runtimeIdentifier && aliasCounts[$0] == 1
                                 },
                                 libraryPath: "Scripts/Compiled/\(library.lastPathComponent)",
                                 sha256: digest(of: try Data(contentsOf: library))))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ProjectCompiledScripts(entries: entries))
            .write(to: outputDirectory.appendingPathComponent(relativePath), options: .atomic)
        return Set(entries.flatMap { [$0.identifier] + $0.legacyIdentifiers })
        #endif
    }
}
