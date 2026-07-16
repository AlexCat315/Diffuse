import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum WasmtimeCLIError: Error, Sendable, Equatable, CustomStringConvertible {
    case executableNotFound
    case versionMismatch(expected: String, actual: String)
    case timedOut
    case invocationFailed(String)
    case unsupportedHostImports([String])
    case inputTooLarge
    case outputTooLarge
    case invalidWAVEOutput
    case typedComponentABIRequiresEmbeddedRuntime

    public var description: String {
        switch self {
        case .executableNotFound: return "pinned Wasmtime executable was not found"
        case let .versionMismatch(expected, actual): return "expected Wasmtime \(expected), got \(actual)"
        case .timedOut: return "Wasmtime component invocation timed out"
        case let .invocationFailed(message): return "Wasmtime component invocation failed: \(message)"
        case let .unsupportedHostImports(imports):
            return "Wasmtime CLI cannot link Guava host imports: \(imports.joined(separator: ", "))"
        case .inputTooLarge: return "Wasmtime component input exceeds 1 MiB"
        case .outputTooLarge: return "Wasmtime component output exceeds 1 MiB"
        case .invalidWAVEOutput: return "Wasmtime component did not return a WAVE string"
        case .typedComponentABIRequiresEmbeddedRuntime:
            return "typed Guava Component capabilities require the embedded Wasmtime runtime"
        }
    }
}

/// Concrete Component Model runner for the separately sandboxed PluginHost.
/// It accepts only the pinned Wasmtime version and passes arguments directly to
/// Process (never through a shell). Package WIT validation rejects all ambient
/// WASI imports before this runner is reached.
public final class WasmtimeCLIComponentRuntime: WASIComponentRuntime, @unchecked Sendable {
    public static let pinnedVersion = "45.0.0"
    public let runtimeVersion = pinnedVersion
    public let executableURL: URL

    private let lock = NSLock()
    private var processesByPluginID: [String: Process] = [:]

    public init(executableURL: URL? = nil) throws {
        guard let url = executableURL ?? Self.locateExecutable() else {
            throw WasmtimeCLIError.executableNotFound
        }
        self.executableURL = url
        let version = try Self.readVersion(at: url)
        guard Self.isPinnedVersionOutput(version) else {
            throw WasmtimeCLIError.versionMismatch(expected: Self.pinnedVersion, actual: version)
        }
    }

    public func validateComponent(_ package: ValidatedPluginPackage,
                                  limits: PluginResourceLimits) throws {
        throw WasmtimeCLIError.typedComponentABIRequiresEmbeddedRuntime
    }

    public func prepare(_ package: ValidatedPluginPackage,
                        capabilityID: String,
                        input: Data,
                        querySnapshot: PluginQuerySnapshot?,
                        limits: PluginResourceLimits) throws -> Data {
        throw WasmtimeCLIError.typedComponentABIRequiresEmbeddedRuntime
    }

    public func interrupt(pluginID: String) {
        let process = lock.withLock { processesByPluginID[pluginID] }
        if let process, process.isRunning { forceStop(process) }
    }

    private func invoke(package: ValidatedPluginPackage,
                        expression: String,
                        timeoutMilliseconds: UInt64,
                        limits: PluginResourceLimits) throws -> Data {
        try Self.validateSupportedImports(package.witContract.imports)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = Self.invocationArguments(componentPath: package.componentURL.path,
                                                     expression: expression,
                                                     timeoutMilliseconds: timeoutMilliseconds,
                                                     limits: limits)
        // Do not inherit stdin. stdout is the single typed return value and
        // stderr is diagnostic only; neither is forwarded to the Editor.
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        lock.withLock { processesByPluginID[package.manifest.id] = process }
        defer { _ = lock.withLock { processesByPluginID.removeValue(forKey: package.manifest.id) } }

        try process.run()
        // Drain both pipes while the child runs. Waiting for termination before
        // reading lets an untrusted component fill an OS pipe buffer and block
        // forever. Readers retain at most their configured limit but continue
        // draining excess bytes until Wasmtime exits or is killed.
        let outputReader = BoundedPipeReader(
            handle: stdout.fileHandleForReading,
            limit: limits.maximumOutputBytes
        )
        let diagnosticReader = BoundedPipeReader(
            handle: stderr.fileHandleForReading,
            limit: 4_096
        )
        outputReader.start()
        diagnosticReader.start()
        let deadline = DispatchTime.now() + .milliseconds(Int(timeoutMilliseconds) + 250)
        guard finished.wait(timeout: deadline) == .success else {
            forceStop(process)
            _ = finished.wait(timeout: .now() + .milliseconds(250))
            _ = outputReader.result()
            _ = diagnosticReader.result()
            throw WasmtimeCLIError.timedOut
        }
        let output = outputReader.result()
        let diagnostic = diagnosticReader.result()
        guard process.terminationStatus == 0 else {
            let message = String(data: diagnostic.prefix(4_096), encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw WasmtimeCLIError.invocationFailed(message)
        }
        guard !outputReader.exceededLimit else { throw WasmtimeCLIError.outputTooLarge }
        return try decodeWAVEString(output)
    }

    public static func invocationArguments(componentPath: String,
                                           expression: String,
                                           timeoutMilliseconds: UInt64,
                                           limits: PluginResourceLimits) -> [String] {
        [
            "run",
            "-W", "component-model=y",
            "-W", "fuel=\(limits.fuelPerInvocation)",
            "-W", "max-memory-size=\(limits.maximumMemoryBytes)",
            "-W", "timeout=\(timeoutMilliseconds)ms",
            "-W", "max-instances=64,max-memories=16,max-tables=16,max-table-elements=100000",
            // The CLI normally wires common WASI imports automatically. Turn
            // that linker surface off explicitly so a component cannot hide an
            // ambient import that is absent from capabilities.wit.
            "-S", "common=n,cli=n,http=n,inherit-env=n,inherit-network=n,tcp=n,udp=n",
            "--invoke", expression,
            componentPath,
        ]
    }

    private func decodeWAVEString(_ output: Data) throws -> Data {
        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let quoted = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: quoted) else {
            throw WasmtimeCLIError.invalidWAVEOutput
        }
        return Data(value.utf8)
    }

    private func waveString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }

    private func forceStop(_ process: Process) {
        process.terminate()
        guard process.isRunning else { return }
#if canImport(Darwin) || canImport(Glibc)
        _ = kill(process.processIdentifier, SIGKILL)
#else
        process.interrupt()
#endif
    }

    private static func locateExecutable() -> URL? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["GUAVA_WASMTIME_PATH"] {
            candidates.append(configured)
        }
        candidates += [
            "/opt/homebrew/bin/wasmtime",
            "/usr/local/bin/wasmtime",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".wasmtime/bin/wasmtime").path,
        ]
        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }).map(URL.init(fileURLWithPath:))
    }

    /// The CLI runner intentionally supports components without custom host
    /// imports. Guava query imports require an embedded Component linker; until
    /// that adapter is present, rejecting them is safer than silently linking
    /// ambient WASI or pretending the grant is executable.
    static func validateSupportedImports(_ imports: [String]) throws {
        guard imports.isEmpty else {
            throw WasmtimeCLIError.unsupportedHostImports(imports.sorted())
        }
    }

    static func isPinnedVersionOutput(_ output: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pinnedVersion)
        return output.range(
            of: "^wasmtime[ ]+\(escaped)(?:[[:space:]]|$)",
            options: .regularExpression
        ) != nil
    }

    private static func readVersion(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let reader = BoundedPipeReader(handle: output.fileHandleForReading, limit: 4_096)
        reader.start()
        guard finished.wait(timeout: .now() + .seconds(2)) == .success else {
            process.terminate()
#if canImport(Darwin) || canImport(Glibc)
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
#else
            if process.isRunning { process.interrupt() }
#endif
            _ = reader.result()
            throw WasmtimeCLIError.timedOut
        }
        let data = reader.result()
        return String(data: data, encoding: .utf8) ?? "unknown"
    }
}

/// Concurrently drains one child-process pipe while retaining bounded output.
/// `Data` growth is capped at `limit + 1` so callers can distinguish an exact
/// limit-sized response from an oversized response without buffering attacker
/// controlled output.
private final class BoundedPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var retained = Data()
    private var didStart = false
    private var didExceedLimit = false

    init(handle: FileHandle, limit: Int) {
        self.handle = handle
        self.limit = max(0, limit)
    }

    var exceededLimit: Bool {
        lock.withLock { didExceedLimit }
    }

    func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !didStart else { return false }
            didStart = true
            return true
        }
        guard shouldStart else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunk = handle.readData(ofLength: 16 * 1_024)
                if chunk.isEmpty { break }
                lock.withLock {
                    let remaining = max(0, limit + 1 - retained.count)
                    if remaining > 0 { retained.append(chunk.prefix(remaining)) }
                    if retained.count > limit || chunk.count > remaining {
                        didExceedLimit = true
                    }
                }
            }
            finished.signal()
        }
    }

    func result() -> Data {
        if finished.wait(timeout: .now() + .seconds(1)) != .success {
            try? handle.close()
            _ = finished.wait(timeout: .now() + .seconds(1))
        }
        return lock.withLock { retained }
    }
}
