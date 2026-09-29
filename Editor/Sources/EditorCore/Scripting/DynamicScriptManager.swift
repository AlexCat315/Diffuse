import Foundation
import ScriptRuntime

/// Manages dynamically compiled Swift scripts in a project.
///
/// Responsibilities:
/// - Scan `Scripts/*.swift` files in the project directory
/// - Read / write / create script sources
/// - Compile scripts via `SwiftScriptCompiler` (off the main thread)
/// - Load compiled libraries via `SwiftScriptLoader`
/// - Register scripts with the `ScriptRuntime` (hot-reload via generation bump)
/// - Track compilation status and diagnostics
public final class DynamicScriptManager: @unchecked Sendable {

    // MARK: - Public types

    /// A script source file in the project's `Scripts/` directory.
    public struct ScriptFile: Sendable, Equatable {
        public let url: URL
        /// Stable identifier used to register the script with the runtime,
        /// e.g. `scripts.player-movement`.
        public let identifier: String
        /// Display name derived from the file name, e.g. `PlayerMovement`.
        public let displayName: String

        public init(url: URL) {
            self.url = url
            let stem = url.deletingPathExtension().lastPathComponent
            self.displayName = stem
            self.identifier = "scripts.\(Self.sanitize(stem))"
        }

        private static func sanitize(_ name: String) -> String {
            name.lowercased().replacingOccurrences(of: " ", with: "-")
        }
    }

    /// Outcome of the most recent compilation attempt for a script.
    public enum CompilationStatus: Sendable, Equatable {
        case idle
        case compiling
        case succeeded
        case failed(message: String)
    }

    // MARK: - Dependencies

    private let projectDirectory: String
    private let scriptRuntime: ScriptRuntime
    private let compiler: SwiftScriptCompiler
    private let loader: SwiftScriptLoader
    private let languageSupport: ScriptLanguageSupport?
    private let languageSupportUnavailableMessage: String?

    /// Tracks the file the loader currently has mapped per script, so the next
    /// compilation can remove the previous generation instead of accumulating
    /// one uniquely-named dylib per hot reload.
    @MainActor private var previousDylibPaths: [String: String] = [:]
    @MainActor private var statusByScriptID: [String: CompilationStatus] = [:]

    // MARK: - Init

    /// Creates a script manager.
    ///
    /// - Parameters:
    ///   - projectDirectory: Absolute path to the project root. Scripts live
    ///     in `<projectDirectory>/Scripts/`.
    ///   - scriptRuntime: The runtime that scripts will be registered with.
    ///   - engineModulePaths: Directories containing engine `.swiftmodule`
    ///     files so scripts can `import SceneRuntime`, `import SIMDCompat`,
    ///     etc.
    public init(projectDirectory: String,
                scriptRuntime: ScriptRuntime,
                engineModulePaths: [String],
                clangModuleMapPaths: [String] = [],
            clangIncludePaths: [String] = [],
            enginePackageDirectory: String? = nil) {
        self.projectDirectory = projectDirectory
        self.scriptRuntime = scriptRuntime
        self.compiler = SwiftScriptCompiler(
            includePaths: engineModulePaths,
            clangModuleMapPaths: clangModuleMapPaths,
            clangIncludePaths: clangIncludePaths,
            outputDirectory: Self.scriptsBuildDirectory(projectDirectory: projectDirectory)
        )
        self.loader = SwiftScriptLoader()

        if let enginePackageDirectory {
            do {
                let executable = try SourceKitLSPExecutableLocator.resolveExecutableURL()
                self.languageSupport = ScriptLanguageSupport(
                    scriptsDirectoryURL: Self.scriptsDirectory(projectDirectory: projectDirectory),
                    engineModulePaths: engineModulePaths,
                    clangModuleMapPaths: clangModuleMapPaths,
                    clangIncludePaths: clangIncludePaths,
                    executableURL: executable
                )
                self.languageSupportUnavailableMessage = nil
            } catch {
                self.languageSupport = nil
                self.languageSupportUnavailableMessage = error.localizedDescription
            }
        } else {
            self.languageSupport = nil
            self.languageSupportUnavailableMessage = "Could not locate the Engine Swift package for script analysis."
        }
    }

    // MARK: - Directory layout

    /// `<projectDirectory>/Scripts/`
    public var scriptsDirectoryURL: URL {
        Self.scriptsDirectory(projectDirectory: projectDirectory)
    }

    private static func scriptsDirectory(projectDirectory: String) -> URL {
        URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent("Scripts", isDirectory: true)
    }

    /// `<projectDirectory>/Scripts/.build/` — compiled libraries go here.
    public static func scriptsBuildDirectory(projectDirectory: String) -> URL {
        URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
    }

    // MARK: - File operations

    /// Returns all `.swift` files in the project's `Scripts/` directory,
    /// sorted by name.
    public func scanScriptFiles() throws -> [ScriptFile] {
        let fm = FileManager.default
        let dir = scriptsDirectoryURL
        guard fm.fileExists(atPath: dir.path) else { return [] }
        let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return contents
            .filter { $0.pathExtension == "swift" }
            .map { ScriptFile(url: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func startLanguageService(
        onDiagnostics: @escaping ScriptLanguageSupport.DiagnosticsHandler
    ) async throws {
        guard let languageSupport else {
            throw ScriptLanguageSupportError.unavailable(languageSupportUnavailableMessage ?? "Unknown setup error.")
        }
        let sources = try scanScriptFiles().map { file in
            ScriptLanguageSource(file: file, text: try readSource(at: file.url))
        }
        try await languageSupport.start(sources: sources, onDiagnostics: onDiagnostics)
    }

    public func updateLanguageSource(scriptID: String, text: String) async throws {
        guard let languageSupport else {
            throw ScriptLanguageSupportError.unavailable(languageSupportUnavailableMessage ?? "Unknown setup error.")
        }
        try await languageSupport.update(scriptID: scriptID, text: text)
    }

    public func refreshLanguageWorkspace() async throws {
        guard let languageSupport else {
            throw ScriptLanguageSupportError.unavailable(languageSupportUnavailableMessage ?? "Unknown setup error.")
        }
        let sources = try scanScriptFiles().map { file in
            ScriptLanguageSource(file: file, text: try readSource(at: file.url))
        }
        try await languageSupport.restart(sources: sources)
    }

    /// True when a SourceKit-LSP session can answer semantic queries. The UI
    /// uses this to hide hover affordances rather than reporting failures for
    /// every mouse pause on machines without a Swift toolchain.
    public var isLanguageServiceAvailable: Bool { languageSupport != nil }

    public var languageServiceUnavailableReason: String? { languageSupportUnavailableMessage }

    // MARK: - Semantic queries

    public func hover(scriptID: String,
                      at position: ScriptLanguagePosition) async throws -> ScriptHoverResult? {
        try await performOnLanguageService { try await $0.hover(scriptID: scriptID, at: position) }
    }

    public func completion(scriptID: String,
                           at position: ScriptLanguagePosition,
                           triggerCharacter: String? = nil) async throws -> ScriptCompletionResult {
        try await performOnLanguageService {
            try await $0.completion(scriptID: scriptID,
                                    at: position,
                                    triggerCharacter: triggerCharacter)
        }
    }

    public func definition(scriptID: String,
                           at position: ScriptLanguagePosition) async throws -> [ScriptDefinitionLocation] {
        try await performOnLanguageService { try await $0.definition(scriptID: scriptID, at: position) }
    }

    private func performOnLanguageService<T: Sendable>(
        _ body: (ScriptLanguageSupport) async throws -> T
    ) async throws -> T {
        guard let languageSupport else {
            throw ScriptLanguageSupportError.unavailable(languageSupportUnavailableMessage ?? "Unknown setup error.")
        }
        return try await body(languageSupport)
    }

    /// Reads the UTF-8 source of a script file.
    public func readSource(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Writes source back to disk. The caller is responsible for calling
    /// ``compileAndLoad(scriptID:sourceURL:)`` afterwards if a hot-reload is
    /// desired.
    public func writeSource(_ source: String, at url: URL) throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Creates a new script file with the given name (without extension) and
    /// initial source. Returns the file URL.
    @discardableResult
    public func createScript(name: String, source: String) throws -> URL {
        let fm = FileManager.default
        let dir = scriptsDirectoryURL
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty,
              normalizedName != ".",
              normalizedName != "..",
              normalizedName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:")) == nil else {
            throw ScriptFileError.invalidName(name)
        }

        let url = dir.appendingPathComponent("\(normalizedName).swift")
        guard !fm.fileExists(atPath: url.path) else {
            throw ScriptFileError.alreadyExists(normalizedName)
        }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw ScriptFileError.alreadyExists(normalizedName)
        }
        do {
            try Data(source.utf8).write(to: url, options: .atomic)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return url
    }

    /// Deletes a script file and unregisters it from the runtime.
    public func deleteScript(_ file: ScriptFile) throws {
        unload(scriptID: file.identifier)
        try FileManager.default.removeItem(at: file.url)
    }

    // MARK: - Compile & load

    /// Compiles a script, loads the resulting library, and registers it with
    /// the runtime. Runs on a background task; completion is delivered on the
    /// main actor.
    ///
    /// Registering an existing identifier bumps the runtime's generation,
    /// which tears down and re-creates all active instances — this is the
    /// hot-reload path.
    public func compileAndLoad(scriptID: String,
                               sourceURL: URL,
                               completion: @escaping @Sendable (CompilationStatus) -> Void) {
        Task { @MainActor in
            self.statusByScriptID[scriptID] = .compiling
        }

        let compiler = self.compiler
        let loader = self.loader
        let scriptRuntime = self.scriptRuntime

        Task.detached(priority: .userInitiated) { [weak self] in
            let status: CompilationStatus
            do {
                let result = try compiler.compile(sourcePath: sourceURL.path, scriptID: scriptID)
                // The previous generation is still mapped by `dlopen`. Unload
                // it so its inode is released, drop the stale file, then map
                // the fresh one (the compiler emitted a unique path).
                loader.unload(scriptID: scriptID)
                let previousPath = await MainActor.run { self?.previousDylibPaths[scriptID] }
                if let previousPath, previousPath != result.outputPath {
                    try? FileManager.default.removeItem(atPath: previousPath)
                }
                let makeScript = try loader.loadFactory(scriptID: scriptID, libraryPath: result.outputPath)
                await MainActor.run { self?.previousDylibPaths[scriptID] = result.outputPath }
                // Register on the main actor — the runtime mutates shared state.
                _ = await MainActor.run { scriptRuntime.register(named: scriptID, makeScript) }
                await self?.updateStatus(.succeeded, for: scriptID)
                status = .succeeded
            } catch {
                status = .failed(message: error.localizedDescription)
                await self?.updateStatus(status, for: scriptID)
            }

            await MainActor.run {
                completion(status)
            }
        }
    }

    @MainActor
    private func updateStatus(_ status: CompilationStatus, for scriptID: String) {
        statusByScriptID[scriptID] = status
    }

    /// Compiles project scripts one at a time so the shared dynamic loader is
    /// never mutated concurrently.
    public func compileAllScripts(
        onScriptCompletion: @escaping @Sendable (ScriptFile, CompilationStatus) -> Void,
        completion: @escaping @Sendable () -> Void
    ) throws {
        compileNext(try scanScriptFiles(), at: 0,
                    onScriptCompletion: onScriptCompletion,
                    completion: completion)
    }

    private func compileNext(
        _ files: [ScriptFile],
        at index: Int,
        onScriptCompletion: @escaping @Sendable (ScriptFile, CompilationStatus) -> Void,
        completion: @escaping @Sendable () -> Void
    ) {
        guard files.indices.contains(index) else {
            completion()
            return
        }
        let file = files[index]
        compileAndLoad(scriptID: file.identifier, sourceURL: file.url) { [weak self] status in
            onScriptCompletion(file, status)
            self?.compileNext(files, at: index + 1,
                              onScriptCompletion: onScriptCompletion,
                              completion: completion)
        }
    }

    /// Unregisters a script from the runtime, unloads its library, and removes
    /// the on-disk dylib the loader was mapping.
    public func unload(scriptID: String) {
        scriptRuntime.unregister(named: scriptID)
        loader.unload(scriptID: scriptID)
        Task { @MainActor in
            self.statusByScriptID[scriptID] = .idle
            if let previous = self.previousDylibPaths.removeValue(forKey: scriptID) {
                try? FileManager.default.removeItem(atPath: previous)
            }
        }
    }

    // MARK: - Status tracking

    /// Returns the compilation status for a script identifier. Must be called
    /// on the main actor.
    @MainActor
    public func status(for scriptID: String) -> CompilationStatus {
        statusByScriptID[scriptID] ?? .idle
    }
}

public enum ScriptFileError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidName(name):
            return "Invalid script name '\(name)'. Use a file name without path separators."
        case let .alreadyExists(name):
            return "A script named '\(name)' already exists."
        }
    }
}

extension DynamicScriptManager.CompilationStatus {
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var message: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
