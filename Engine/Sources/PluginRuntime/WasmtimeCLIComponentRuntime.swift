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
    case outputTooLarge
    case invalidWAVEOutput

    public var description: String {
        switch self {
        case .executableNotFound: return "pinned Wasmtime executable was not found"
        case let .versionMismatch(expected, actual): return "expected Wasmtime \(expected), got \(actual)"
        case .timedOut: return "Wasmtime component invocation timed out"
        case let .invocationFailed(message): return "Wasmtime component invocation failed: \(message)"
        case .outputTooLarge: return "Wasmtime component output exceeds 1 MiB"
        case .invalidWAVEOutput: return "Wasmtime component did not return a WAVE string"
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
        guard version.contains("wasmtime \(Self.pinnedVersion)") else {
            throw WasmtimeCLIError.versionMismatch(expected: Self.pinnedVersion, actual: version)
        }
    }

    public func validateComponent(_ package: ValidatedPluginPackage,
                                  limits: PluginResourceLimits) throws {
        _ = try invoke(package: package,
                       expression: "discover()",
                       timeoutMilliseconds: limits.discoveryTimeoutMilliseconds,
                       limits: limits)
    }

    public func discover(_ package: ValidatedPluginPackage,
                         limits: PluginResourceLimits) throws -> Data {
        try invoke(package: package,
                   expression: "discover()",
                   timeoutMilliseconds: limits.discoveryTimeoutMilliseconds,
                   limits: limits)
    }

    public func prepare(_ package: ValidatedPluginPackage,
                        capabilityID: String,
                        input: Data,
                        limits: PluginResourceLimits) throws -> Data {
        guard input.count <= limits.maximumOutputBytes,
              let inputString = String(data: input, encoding: .utf8) else {
            throw WasmtimeCLIError.outputTooLarge
        }
        let expression = "prepare(\(waveString(capabilityID)), \(waveString(inputString)))"
        return try invoke(package: package,
                          expression: expression,
                          timeoutMilliseconds: limits.preparationTimeoutMilliseconds,
                          limits: limits)
    }

    public func interrupt(pluginID: String) {
        let process = lock.withLock { processesByPluginID[pluginID] }
        if let process, process.isRunning { forceStop(process) }
    }

    private func invoke(package: ValidatedPluginPackage,
                        expression: String,
                        timeoutMilliseconds: UInt64,
                        limits: PluginResourceLimits) throws -> Data {
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
        let deadline = DispatchTime.now() + .milliseconds(Int(timeoutMilliseconds) + 250)
        guard finished.wait(timeout: deadline) == .success else {
            forceStop(process)
            _ = finished.wait(timeout: .now() + .milliseconds(250))
            throw WasmtimeCLIError.timedOut
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: diagnostic.prefix(4_096), encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw WasmtimeCLIError.invocationFailed(message)
        }
        guard output.count <= limits.maximumOutputBytes else { throw WasmtimeCLIError.outputTooLarge }
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

    private static func readVersion(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
    }
}
