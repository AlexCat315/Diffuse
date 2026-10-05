import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private final class ScriptCompilerOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Cooperative cancellation bridge for a blocking `Process` compilation.
/// Cancelling terminates the currently registered swift driver process instead
/// of merely ignoring its eventual result.
public final class ScriptCompilationCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true {
            if let runningProcess { Self.stop(runningProcess) }
        }
    }

    fileprivate static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        #if os(macOS) || os(Linux)
        // A child can inherit an ignored or blocked SIGTERM (for example from
        // SDL). Bound cancellation time even when graceful termination fails.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(250)) {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        #endif
    }

    fileprivate func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    fileprivate func unregister(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }
}

/// Invokes the system `swiftc` compiler to turn a Swift script source file
/// into a dynamic library that `SwiftScriptLoader` can load.
///
/// The compiler is configured so the resulting library has **no direct link
/// dependency** on the engine: every engine symbol it references is resolved
/// at load time from the host process. This keeps script compilation fast
/// (single-file, no module merging) and avoids shipping engine static libraries
/// alongside every project.
///
/// ## Windows import library
///
/// On Windows the linker does not allow undefined symbols, so the engine's
/// `@_cdecl` exports must be declared in a `.def` file and turned into an
/// import library (`.lib`) via `llvm-dlltool`. Scripts then link against that
/// import library; at load time the symbols are resolved from the host
/// executable.
public final class SwiftScriptCompiler: @unchecked Sendable {

    /// Path to the `swiftc` executable. Defaults to `swiftc` on `PATH`.
    public var swiftcPath: String

    /// Path to the `llvm-dlltool` executable (Windows only). Defaults to
    /// `llvm-dlltool` on `PATH`.
    public var dlltoolPath: String

    /// Directories searched for `.swiftmodule` files (so scripts can
    /// `import SceneRuntime`, `import SIMDCompat`, etc.).
    public var includePaths: [String]

    /// Clang module maps and include directories needed by imported Swift modules.
    public var clangModuleMapPaths: [String]
    public var clangIncludePaths: [String]

    /// Directories searched for import libraries.
    public var libraryPaths: [String]

    /// Directory where compiled `.dylib`/`.so`/`.dll` files are written.
    public var outputDirectory: URL

    /// The name of the host module that exports the engine C ABI symbols.
    /// On Windows this is written into the `.def` file's `LIBRARY` line so
    /// the import library references the host executable.
    public var hostModuleName: String

    /// C ABI symbols exported by the host that scripts may call.
    ///
    /// These correspond to the `@_cdecl("guava_*")` functions declared in
    /// `ScriptCBridge*.swift`. The list is used to generate the Windows
    /// `.def` file. Keep it in sync with the bridge sources, or populate it
    /// automatically via ``scanExportedSymbols(in:)``.
    public var exportedSymbols: [String]

    /// Scans a directory of Swift source files for `@_cdecl("symbol")`
    /// declarations and returns the symbol names.
    ///
    /// Pass the directory containing the `ScriptCBridge*.swift` files to
    /// populate ``exportedSymbols`` automatically, avoiding drift between
    /// the bridge sources and the `.def` file.
    public static func scanExportedSymbols(in directory: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var symbols: Set<String> = []
        let pattern = "@_cdecl\\(\\s*\"([^\"]+)\"\\s*\\)"
        let regex = try NSRegularExpression(pattern: pattern)

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            // Scan line by line so documentation comments like
            // `/// @_cdecl("guavaCreateScript")` are not picked up.
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                regex.enumerateMatches(in: line, range: range) { match, _, _ in
                    guard let match,
                          let nameRange = Range(match.range(at: 1), in: line) else { return }
                    symbols.insert(String(line[nameRange]))
                }
            }
        }

        return symbols.sorted()
    }

    public init(
        swiftcPath: String = "swiftc",
        dlltoolPath: String = "llvm-dlltool",
        includePaths: [String] = [],
        clangModuleMapPaths: [String] = [],
        clangIncludePaths: [String] = [],
        libraryPaths: [String] = [],
        outputDirectory: URL,
        hostModuleName: String = "GuavaEditor",
        exportedSymbols: [String] = []
    ) {
        self.swiftcPath = swiftcPath
        self.dlltoolPath = dlltoolPath
        self.includePaths = includePaths
        self.clangModuleMapPaths = clangModuleMapPaths
        self.clangIncludePaths = clangIncludePaths
        self.libraryPaths = libraryPaths
        self.outputDirectory = outputDirectory
        self.hostModuleName = hostModuleName
        self.exportedSymbols = exportedSymbols
    }

    // MARK: - Compilation

    /// Result of a successful compilation.
    public struct CompilationResult: Sendable {
        public let outputPath: String
        public let stdout: String
        public let stderr: String
    }

    /// Compiles a single Swift source file into a dynamic library.
    ///
    /// - Parameters:
    ///   - sourcePath: Absolute path to the `.swift` script file.
    ///   - scriptID: Stable identifier used as the output file name.
    public func compile(sourcePath: String,
                        scriptID: String,
                        cancellation: ScriptCompilationCancellationToken? = nil) throws -> CompilationResult {
        if cancellation?.isCancelled == true { throw ScriptCompileError.cancelled }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let shimURL = outputDirectory.appendingPathComponent(".guava-entrypoint-\(UUID().uuidString).swift")
        try Self.generatedEntryPointSource.write(to: shimURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: shimURL) }

        // Emit to a unique path on every compilation. The previous generation
        // is typically still mapped by `dlopen`, and re-emitting over a mapped
        // image makes the linker fail with `EEXIST`. The caller records the
        // returned path and removes the previous file after the loader swaps.
        let outputPath = outputDirectory
            .appendingPathComponent("\(scriptID)-\(UUID().uuidString).\(Self.dylibExtension)")
            .path

        // On Windows, ensure the import library exists before linking.
        #if os(Windows)
        let importLibPath = try ensureImportLibrary()
        #endif

        let sourcePaths = [sourcePath, shimURL.path]
        let args = try buildArguments(sourcePaths: sourcePaths, outputPath: outputPath)

        let process = Process()
        process.executableURL = try Self.resolveExecutableURL(for: swiftcPath)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let mayContinue = cancellation?.register(process) ?? true
        defer { cancellation?.unregister(process) }
        if !mayContinue { ScriptCompilationCancellationToken.stop(process) }

        // Drain both pipes while swiftc is running. Waiting first can deadlock
        // once either pipe fills its kernel buffer (large diagnostics are common
        // for generated or generic-heavy scripts).
        let stdoutBox = ScriptCompilerOutputBox()
        let stderrBox = ScriptCompilerOutputBox()
        let outputReaders = DispatchGroup()
        outputReaders.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutBox.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            outputReaders.leave()
        }
        outputReaders.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrBox.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            outputReaders.leave()
        }
        process.waitUntilExit()
        outputReaders.wait()

        if cancellation?.isCancelled == true {
            try? FileManager.default.removeItem(atPath: outputPath)
            throw ScriptCompileError.cancelled
        }

        let stdout = String(
            data: stdoutBox.load(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrBox.load(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: outputPath)
            throw ScriptCompileError.compilationFailed(
                exitCode: Int(process.terminationStatus),
                stderr: stderr,
                stdout: stdout
            )
        }

        return CompilationResult(outputPath: outputPath, stdout: stdout, stderr: stderr)
    }

    public static func resolveExecutableURL(for executable: String,
                                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let fileManager = FileManager.default
        let hasDirectory = executable.contains("/") || executable.contains("\\")
        if hasDirectory {
            let url = URL(fileURLWithPath: executable)
            guard fileManager.isExecutableFile(atPath: url.path) else {
                throw ScriptCompileError.executableNotFound(executable)
            }
            return url
        }

        func environmentValue(_ key: String) -> String? {
            #if os(Windows)
            return environment.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            #else
            return environment[key]
            #endif
        }
        let path = environmentValue("PATH") ?? ""
        #if os(Windows)
        let pathSeparator: Character = ";"
        let extensions = (environmentValue("PATHEXT") ?? ".EXE;.CMD;.BAT")
            .split(separator: ";")
            .map { executable + $0 }
        let candidates = [executable] + (URL(fileURLWithPath: executable).pathExtension.isEmpty ? extensions : [])
        #else
        let pathSeparator: Character = ":"
        let candidates = [executable]
        #endif

        for directory in path.split(separator: pathSeparator, omittingEmptySubsequences: false) {
            let directoryPath = directory.isEmpty ? "." : String(directory)
            for candidate in candidates {
                let url = URL(fileURLWithPath: directoryPath, isDirectory: true)
                    .appendingPathComponent(candidate)
                if fileManager.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }

        throw ScriptCompileError.executableNotFound(executable)
    }

    private static let generatedEntryPointSource = """
    import ScriptRuntime

    @_cdecl("guavaCreateScript")
    public func guavaCreateScript(_ output: UnsafeMutableRawPointer) {
        output.assumingMemoryBound(to: Script.self).pointee = Script(behavior: GameScript.self)
    }
    """

    // MARK: - Argument construction

    /// Finds generated C module maps in both SwiftPM build layouts. SwiftBuild
    /// can place them inside per-target intermediates on Linux and Windows.
    public static func discoverClangModuleMapPaths(in buildDirectory: URL) -> [String] {
        let buildDirectory = buildDirectory.resolvingSymlinksInPath()
        let intermediates = buildDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Intermediates.noindex", isDirectory: true)
        let configuration = buildDirectory.lastPathComponent.lowercased().split(separator: "-").first.map(String.init) ?? ""
        var maps = Set<String>()
        for root in [buildDirectory, intermediates] {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files where file.pathExtension == "modulemap" {
                let components = file.pathComponents.map { $0.lowercased() }
                if configuration == "debug", components.contains(where: { $0 == "release" || $0.hasPrefix("release-") }) { continue }
                if configuration == "release", components.contains(where: { $0 == "debug" || $0.hasPrefix("debug-") }) { continue }
                let parent = file.deletingLastPathComponent().lastPathComponent
                if file.lastPathComponent.hasPrefix("C") || (parent.hasPrefix("C") && parent.hasSuffix(".build")) {
                    maps.insert(file.path)
                }
            }
        }
        let declaration = try? NSRegularExpression(pattern: #"(?:^|\n)\s*(?:framework\s+)?module\s+(\w+)\s*\{"#)
        var byModule: [String: String] = [:]
        for path in maps.sorted() {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
                  !contents.contains("-Swift.h"),
                  let match = declaration?.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
                  let nameRange = Range(match.range(at: 1), in: contents) else { continue }
            let name = String(contents[nameRange])
            if byModule[name] == nil { byModule[name] = path }
        }
        return byModule.values.sorted()
    }

    private func buildArguments(sourcePaths: [String], outputPath: String) throws -> [String] {
        var args: [String] = []

        args.append("-O")

        for path in includePaths {
            args.append(contentsOf: ["-I", path])
        }

        for path in clangIncludePaths {
            args.append(contentsOf: ["-Xcc", "-I\(path)"])
        }

        for path in clangModuleMapPaths {
            args.append(contentsOf: ["-Xcc", "-fmodule-map-file=\(path)"])
        }

        for path in libraryPaths {
            args.append(contentsOf: ["-L", path])
        }
        // The output directory is always on the library search path so the
        // generated import library is found automatically.
        args.append(contentsOf: ["-L", outputDirectory.path])

        #if os(macOS)
        // Standalone Swift toolchains do not discover Xcode's SDK like the
        // Apple compiler does. SwiftPM sets it for its own builds, but scripts
        // are compiled by a separate swiftc process.
        args.append(contentsOf: ["-sdk", try Self.macOSSDKPath()])
        args.append(contentsOf: ["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])
        #elseif os(Linux)
        args.append(contentsOf: ["-Xlinker", "--allow-shlib-undefined"])
        #elseif os(Windows)
        // Link against the generated import library.
        args.append("-l\(importLibraryName)")
        #endif

        args.append(contentsOf: ["-emit-library", "-o", outputPath])
        args.append(contentsOf: sourcePaths)

        return args
    }

    // MARK: - Windows import library

    /// The file name (without extension) of the generated import library.
    private var importLibraryName: String { "guava_scripts" }

    /// Generates the `.def` file and runs `llvm-dlltool` to produce the
    /// import library. Returns the path to the resulting `.lib`.
    @discardableResult
    private func ensureImportLibrary() throws -> String {
        let defPath = outputDirectory
            .appendingPathComponent("\(importLibraryName).def")
            .path
        let libPath = outputDirectory
            .appendingPathComponent("\(importLibraryName).lib")
            .path

        // Always regenerate the .def so newly added bridge symbols are picked
        // up without a manual rebuild step.
        let defContent = buildDefFileContent()
        try defContent.write(toFile: defPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = try Self.resolveExecutableURL(for: dlltoolPath)
        process.arguments = ["-d", defPath, "-l", libPath]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw ScriptCompileError.importLibraryFailed(
                exitCode: Int(process.terminationStatus),
                stderr: stderr
            )
        }

        return libPath
    }

    /// Builds the contents of the `.def` file.
    ///
    /// ```
    /// LIBRARY GuavaEditor
    /// EXPORTS
    ///     guava_input_axis
    ///     guava_input_held
    ///     ...
    /// ```
    private func buildDefFileContent() -> String {
        var lines: [String] = []
        lines.append("LIBRARY \(hostModuleName)")
        lines.append("EXPORTS")
        for symbol in exportedSymbols.sorted() {
            lines.append("    \(symbol)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Platform helpers

    #if os(macOS)
    private static func macOSSDKPath() throws -> String {
        if let sdk = ProcessInfo.processInfo.environment["SDKROOT"],
           !sdk.isEmpty, FileManager.default.fileExists(atPath: sdk) {
            return sdk
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let sdk = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: sdk) else {
            throw ScriptCompileError.sdkNotFound(sdk)
        }
        return sdk
    }
    #endif

    /// The platform's dynamic library file extension.
    public static var dylibExtension: String {
        #if os(macOS)
        return "dylib"
        #elseif os(Linux)
        return "so"
        #elseif os(Windows)
        return "dll"
        #else
        return "so"
        #endif
    }
}

public enum ScriptCompileError: Error, LocalizedError, Equatable {
    case cancelled
    case compilationFailed(exitCode: Int, stderr: String, stdout: String)
    case importLibraryFailed(exitCode: Int, stderr: String)
    case executableNotFound(String)
    case sdkNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Swift script compilation was cancelled."
        case let .compilationFailed(exitCode, stderr, stdout):
            let output = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
            return output.isEmpty
                ? "Swift compilation failed with exit code \(exitCode)."
                : "Swift compilation failed with exit code \(exitCode):\n\(output)"
        case let .importLibraryFailed(exitCode, stderr):
            return "Swift script import library generation failed with exit code \(exitCode):\n\(stderr)"
        case let .executableNotFound(name):
            return "Could not find executable '\(name)' on PATH."
        case let .sdkNotFound(diagnostic):
            return "Could not find the macOS SDK with xcrun: \(diagnostic)"
        }
    }
}
