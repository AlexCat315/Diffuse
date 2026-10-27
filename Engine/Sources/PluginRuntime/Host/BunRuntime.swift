public import Foundation
private import CoveProcess
public import CapabilityRuntime

public enum BunRuntimeError: Error, CustomStringConvertible {
    case unavailable
    case rejected(String)
    case protocolFailure
    public var description: String {
        switch self {
        case .unavailable: "Bun runtime is missing. Run cove studio plugins prepare."
        case let .rejected(message): "Bun plugin: \(message)"
        case .protocolFailure: "Bun plugin protocol failed"
        }
    }
}

/// The native broker retains authorization and host services; Bun owns plugin state.
/// Bun is a trusted desktop extension process, not a WebAssembly security sandbox.
public final class BunPluginRuntime: @unchecked Sendable {
    public let runtimeVersion = "1.4.4"
    private let processes: PluginProcessService
    private let http: PluginHTTPService
    private var sessions: [String: BunSession] = [:]
    public var hostCall: ((PluginHostServiceCall) throws -> Data)?

    public init(processes: PluginProcessService, http: PluginHTTPService) {
        self.processes = processes; self.http = http
    }

    public func validateComponent(_ package: ValidatedPluginPackage, limits: PluginResourceLimits) throws {
        _ = try package.requireRuntime()
        guard package.manifest.runtime?.engine == "bun" else { throw BunRuntimeError.unavailable }
    }

    public func prepare(_ package: ValidatedPluginPackage, capabilityID: String, input: Data,
                        querySnapshot: PluginQuerySnapshot?, limits: PluginResourceLimits) throws -> Data {
        let component = try package.requireRuntime()
        guard let entry = component.contract.capabilityInputs.first(where: { package.manifest.id + "." + $0.name == capabilityID }) else {
            throw PluginCapabilityValidationError.unknownCapability(capabilityID)
        }
        try JSONSchemaValidator.validate(data: input, against: package.inputSchema(for: entry))
        let session: BunSession
        if let existing = sessions[package.manifest.id] { session = existing }
        else {
            session = try BunSession()
            let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Diffuse/Plugins/" + package.manifest.id).path
            let names = try session.call(["method": "load", "pluginID": package.manifest.id, "storageDirectory": storage,
                                          "sdkDirectory": (Bundle.module.url(forResource: "plugin-sdk", withExtension: nil, subdirectory: "Resources")?.path ?? ""),
                                          "entry": component.entryURL.path], limit: limits) { _, _ in
                throw BunRuntimeError.rejected("Host services are only available during an invocation")
            }
            let exported = try JSONDecoder().decode([String].self, from: names)
            guard exported.sorted() == component.contract.capabilityInputs.map(\.name).sorted() else {
                session.stop(); throw BunRuntimeError.rejected("Exports differ from capabilities.json")
            }
            sessions[package.manifest.id] = session
        }
        let value = try JSONSerialization.jsonObject(with: input, options: [.fragmentsAllowed])
        do {
            return try session.call(["method": "invoke", "name": entry.name, "input": value], limit: limits) { permission, request in
                guard let granted = PluginImportPermission(rawValue: permission), package.manifest.imports.contains(granted) else {
                    throw PluginQuerySnapshotError.importNotGranted(permission)
                }
                switch granted {
                case .process:
                    return try self.processes.response(pluginID: package.manifest.id, entryPoint: entry.name, request: request)
                case .http: return try self.http.response(pluginID: package.manifest.id, request: request)
                case .editor, .service:
                    guard let hostCall = self.hostCall else { throw BunRuntimeError.rejected("Host service is unavailable") }
                    return try hostCall(PluginHostServiceCall(permission: permission, request: request))
                default:
                    guard let querySnapshot else { throw PluginQuerySnapshotError.missingPayload(granted) }
                    return try querySnapshot.response(importName: permission, request: request, grantedImports: Set(package.manifest.imports))
                }
            }
        } catch {
            // A timed out or broken stream cannot be reused; never consume a late response as the next call.
            if session.failed { sessions.removeValue(forKey: package.manifest.id)?.stop() }
            throw error
        }
    }

    public func interrupt(pluginID: String) {
        sessions.removeValue(forKey: pluginID)?.shutdown()
    }
}

private final class BunSession {
    let process: ProcessSession
    var pending = Data()
    var failed = false

    init() throws {
        let binary = try Self.executable()
        guard let runner = Bundle.module.url(forResource: "bun-runner", withExtension: "js", subdirectory: "Resources") else {
            throw BunRuntimeError.unavailable
        }
        var command = ProcessCommand(executable: binary, directory: runner.deletingLastPathComponent())
        command.arguments = ["--no-install", runner.path]
        // Never inherit Bun preloads, NODE_OPTIONS or project search paths.
        command.environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("BUN_") && !key.hasPrefix("NODE_")
        }
        var budget = ProcessBudget()
        budget.outputBytes = 384 * 1_024 * 1_024
        budget.pendingInputBytes = 384 * 1_024 * 1_024
        budget.lifetimeMilliseconds = nil
        process = try ProcessSession(command: command, budget: budget)
    }
    deinit { stop() }
    func stop() { process.cancel() }
    func shutdown() {
        if !failed, process.isRunning {
            var limits = PluginResourceLimits.secureDefault
            limits.preparationTimeoutMilliseconds = 1_000
            _ = try? call(["method": "unload"], limit: limits) { _, _ in throw BunRuntimeError.protocolFailure }
        }
        stop()
    }

    func call(_ arguments: [String: Any], limit: PluginResourceLimits,
              host: (String, Data) throws -> Data) throws -> Data {
        let id = UUID().uuidString
        var message = arguments; message["id"] = id
        let deadline = Date().addingTimeInterval(Double(limit.preparationTimeoutMilliseconds) / 1000)
        try write(message)
        do {
            while true {
                let reply = try read(until: deadline, maximum: limit.maximumOutputBytes)
                if reply["type"] as? String == "host" {
                    guard let requestID = reply["id"], let permission = reply["permission"] as? String,
                          let request = reply["request"] else { throw BunRuntimeError.protocolFailure }
                    do {
                        let data = try host(permission, JSONSerialization.data(withJSONObject: request, options: [.fragmentsAllowed]))
                        try write(["type": "hostResult", "id": requestID,
                                   "value": JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])])
                    } catch { try write(["type": "hostResult", "id": requestID, "error": String(describing: error)]) }
                } else {
                    guard reply["id"] as? String == id else { throw BunRuntimeError.protocolFailure }
                    if let error = reply["error"] as? String { throw BunRuntimeError.rejected(error) }
                    let payload = try JSONSerialization.data(withJSONObject: reply["value"] ?? NSNull(), options: [.fragmentsAllowed])
                    guard payload.count <= limit.maximumOutputBytes else { throw PluginHostFrameError.frameTooLarge }
                    return payload
                }
            }
        } catch let error as BunRuntimeError {
            if case .protocolFailure = error { failed = true; stop() }
            throw error
        } catch { failed = true; stop(); throw error }
    }

    private func write(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        data.append(10); try process.write(data)
    }
    private func read(until deadline: Date, maximum: Int) throws -> [String: Any] {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw BunRuntimeError.protocolFailure }
                return object
            }
            guard pending.count <= maximum + 65_536 else { throw PluginHostFrameError.frameTooLarge }
            guard let event = try process.nextEvent(until: deadline) else { throw BunRuntimeError.protocolFailure }
            switch event {
            case let .stdout(bytes): pending.append(bytes)
            case let .stderr(bytes): FileHandle.standardError.write(bytes)
            case .stderrClosed: break
            case .stdoutClosed, .exited: throw BunRuntimeError.protocolFailure
            }
        }
    }

    private static func executable() throws -> URL {
        #if os(Windows)
        let name = "bun.exe"
        #else
        let name = "bun"
        #endif
        let executable = Bundle.main.executableURL?.deletingLastPathComponent()
        var candidates = [executable?.appendingPathComponent(name), executable?.appendingPathComponent("Tools/" + name)].compactMap { $0 }
        if let bundled = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/bun") {
            candidates.insert(bundled, at: 0)
        }
        #if DEBUG
        var engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<3 { engine.deleteLastPathComponent() }
        candidates.append(engine.appendingPathComponent("vendor/bun/" + name))
        #endif
        guard let resolved = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw BunRuntimeError.unavailable
        }
        return resolved
    }
}
