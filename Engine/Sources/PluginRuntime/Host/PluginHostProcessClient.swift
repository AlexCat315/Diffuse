#if os(macOS) || os(Linux) || os(Windows)
public import Foundation
private import GuavaProcess
private import GuavaLogging

public enum PluginHostClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case launchFailed(String)
    case communicationFailed
    case timedOut
    case hostRestarted(generation: UInt64)
    case mismatchedResponse
    case requestRejected(String)

    public var description: String {
        switch self {
        case let .launchFailed(message): return "could not launch GuavaPluginHost: \(message)"
        case .communicationFailed: return "GuavaPluginHost pipe communication failed"
        case .timedOut: return "GuavaPluginHost did not respond before the request deadline"
        case let .hostRestarted(generation): return "GuavaPluginHost restarted; invalidate plugin plans at generation \(generation)"
        case .mismatchedResponse: return "GuavaPluginHost returned a mismatched response id"
        case let .requestRejected(reason): return "GuavaPluginHost rejected the request: \(reason)"
        }
    }
}

/// Owns the host lifetime. Framing consumes the shared process stream with one request deadline.
public final class PluginHostProcessClient: @unchecked Sendable {
    public let executableURL: URL
    public let launchArguments: [String]
    public var generation: UInt64 { lock.withLock { _generation } }
    public var onInvalidation: (@Sendable (UInt64) -> Void)?

    private let lock = NSLock()
    private var session: ProcessSession?
    private var pending = Data()
    private var diagnostics = PluginHostDiagnostics()
    private var didRestart = false
    private var _generation: UInt64 = 0

    public init(executableURL: URL, launchArguments: [String] = [],
                onInvalidation: (@Sendable (UInt64) -> Void)? = nil) {
        self.executableURL = executableURL
        self.launchArguments = launchArguments
        self.onInvalidation = onInvalidation
    }

    deinit { stop() }

    public func call(_ request: PluginHostRequest,
                     timeoutMilliseconds: UInt64 = 7_000) throws -> PluginHostResponse {
        var invalidation: ((@Sendable (UInt64) -> Void), UInt64)?
        do {
            return try lock.withLock {
                do {
                    if let session, !session.isRunning { throw PluginHostClientError.communicationFailed }
                    if session == nil { try launch() }
                    guard let session else { throw PluginHostClientError.communicationFailed }
                    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
                    try session.write(PluginHostFrameCodec.encode(request))
                    let header = try readExactly(4, until: deadline)
                    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard length <= PluginHostFrameCodec.maximumFrameBytes else {
                        throw PluginHostClientError.communicationFailed
                    }
                    var frame = header
                    frame.append(try readExactly(Int(length), until: deadline))
                    let response = try PluginHostFrameCodec.decode(PluginHostResponse.self, from: frame)
                    guard response.id == request.id else { throw PluginHostClientError.mismatchedResponse }
                    return response
                } catch {
                    stopLocked()
                    _generation &+= 1
                    if !didRestart { didRestart = true; try? launch() }
                    if let onInvalidation { invalidation = (onInvalidation, _generation) }
                    throw PluginHostClientError.hostRestarted(generation: _generation)
                }
            }
        } catch {
            if let (callback, generation) = invalidation { callback(generation) }
            throw error
        }
    }

    public func stop() {
        lock.withLock {
            if session != nil { _generation &+= 1 }
            stopLocked()
        }
    }

    private func launch() throws {
        var command = ProcessCommand(executable: executableURL,
            directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        command.arguments = launchArguments
        command.environment = ProcessInfo.processInfo.environment
        command.environment["GUAVA_LOG_RUN_ID"] = LogSystem.launch.runID
        var budget = ProcessBudget()
        budget.outputBytes = 33_554_432
        budget.pendingInputBytes = 33_554_432
        budget.lifetimeMilliseconds = nil
        do { session = try ProcessSession(command: command, budget: budget) }
        catch { throw PluginHostClientError.launchFailed(String(describing: error)) }
    }

    private func stopLocked() {
        session?.cancel()
        session = nil
        pending.removeAll(keepingCapacity: true)
        diagnostics.finish()
    }

    private func readExactly(_ count: Int, until deadline: Date) throws -> Data {
        guard let session else { throw PluginHostClientError.communicationFailed }
        while pending.count < count {
            guard Date() < deadline else { throw PluginHostClientError.timedOut }
            let event: ProcessEvent?
            do { event = try session.nextEvent(until: deadline) }
            catch ProcessError.timedOut { throw PluginHostClientError.timedOut }
            guard let event else { throw PluginHostClientError.communicationFailed }
            switch event {
            case let .stdout(data): pending.append(data)
            case let .stderr(data): diagnostics.consume(data, pid: session.processIdentifier)
            case .stderrClosed: diagnostics.finish()
            case .stdoutClosed, .exited: throw PluginHostClientError.communicationFailed
            }
        }
        let result = Data(pending.prefix(count))
        pending.removeFirst(count)
        return result
    }
}

extension PluginHostProcessClient: PluginCapabilityInvoking {
    public func inspectPlugin(at pluginURL: URL) throws -> PluginInspection {
        let response = try call(PluginHostRequest(method: .validatePackage,
                                                  pluginPath: pluginURL.path))
        let payload = try acceptedPayload(response)
        return try JSONDecoder().decode(PluginInspection.self, from: payload)
    }

    /// Loads only an already-authorised inspection and returns a binding to the
    /// exact host generation that accepted it.
    public func loadPlugin(at pluginURL: URL,
                           authorization: PluginAuthorizationRecord,
                           processContext: PluginProcessContext? = nil) throws
        -> PluginExecutionBinding {
        let response = try call(PluginHostRequest(method: .load,
                                                  pluginPath: pluginURL.path,
                                                  authorization: authorization,
                                                  processContext: processContext))
        let payload = try acceptedPayload(response)
        let inspection = try JSONDecoder().decode(PluginInspection.self, from: payload)
        return try PluginExecutionBinding(pluginPath: pluginURL.path,
                                          inspection: inspection,
                                          authorization: authorization,
                                          hostGeneration: generation)
    }

    public func unloadPlugin(at pluginURL: URL) throws {
        let response = try call(PluginHostRequest(method: .unload,
                                                  pluginPath: pluginURL.path))
        // The host answers a successful unload with an empty ok response.
        guard response.ok else {
            throw PluginHostClientError.requestRejected(response.error ?? "unknown error")
        }
    }

    public func prepareCapability(
        binding: PluginExecutionBinding,
        capabilityID: String,
        input: Data,
        querySnapshot: PluginQuerySnapshot?
    ) throws -> PluginPreparedCapabilityResult {
        try binding.validate(hostGeneration: generation)
        let response = try call(PluginHostRequest(method: .prepare,
                                                  pluginPath: binding.pluginPath,
                                                  capabilityID: capabilityID,
                                                  input: input,
                                                  querySnapshot: querySnapshot,
                                                  authorization: binding.authorization))
        let payload = try acceptedPayload(response)
        try binding.validate(hostGeneration: generation)
        if binding.inspection.manifest.access == .read {
            return .read(payload)
        }
        return .hostCalls(try JSONDecoder().decode([HostCapabilityCall].self,
                                                   from: payload))
    }

    private func acceptedPayload(_ response: PluginHostResponse) throws -> Data {
        guard response.ok else {
            throw PluginHostClientError.requestRejected(response.error ?? "unknown error")
        }
        guard let payload = response.payload else {
            throw PluginHostClientError.communicationFailed
        }
        return payload
    }
}

#endif
