import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

/// Editor-side owner of the isolated host process. A crash triggers one restart,
/// increments `generation`, and fails the interrupted request so every pending
/// plugin draft can be invalidated by the caller.
public final class PluginHostProcessClient: @unchecked Sendable {
    public let executableURL: URL
    public var generation: UInt64 { lock.withLock { _generation } }
    public var onInvalidation: (@Sendable (UInt64) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var didRestart = false
    private var _generation: UInt64 = 0

    public init(executableURL: URL,
                onInvalidation: (@Sendable (UInt64) -> Void)? = nil) {
        self.executableURL = executableURL
        self.onInvalidation = onInvalidation
    }

    deinit { stop() }

    public func call(_ request: PluginHostRequest,
                     timeoutMilliseconds: UInt64 = 7_000) throws -> PluginHostResponse {
        var invalidation: ((@Sendable (UInt64) -> Void), UInt64)?
        do {
            return try lock.withLock {
                do {
                    if process?.isRunning != true { try launch() }
                    guard let input, let output else { throw PluginHostClientError.communicationFailed }
                    let deadline = makeDeadline(timeoutMilliseconds: timeoutMilliseconds)
                    try writeExactly(PluginHostFrameCodec.encode(request),
                                     to: input,
                                     deadline: deadline)
                    let header = try readExactly(4, from: output, deadline: deadline)
                    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard length <= PluginHostFrameCodec.maximumFrameBytes else {
                        throw PluginHostClientError.communicationFailed
                    }
                    let payload = try readExactly(Int(length), from: output, deadline: deadline)
                    var frame = header
                    frame.append(payload)
                    let response = try PluginHostFrameCodec.decode(PluginHostResponse.self, from: frame)
                    guard response.id == request.id else { throw PluginHostClientError.mismatchedResponse }
                    return response
                } catch {
                    guard !didRestart else { throw error }
                    stopLocked()
                    didRestart = true
                    _generation &+= 1
                    try? launch()
                    if let onInvalidation {
                        invalidation = (onInvalidation, _generation)
                    }
                    throw PluginHostClientError.hostRestarted(generation: _generation)
                }
            }
        } catch {
            if let (callback, generation) = invalidation {
                callback(generation)
            }
            throw error
        }
    }

    public func stop() {
        lock.withLock { stopLocked() }
    }

    private func launch() throws {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executableURL
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch {
            throw PluginHostClientError.launchFailed(String(describing: error))
        }
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
#if canImport(Darwin)
        // A dead host must become a recoverable pipe error, never SIGPIPE the
        // Editor process while it is sending an RPC frame.
        _ = fcntl(input?.fileDescriptor ?? -1, F_SETNOSIGPIPE, 1)
#endif
    }

    private func stopLocked() {
        try? input?.close()
        try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
    }

    private func makeDeadline(timeoutMilliseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let (delta, multiplicationOverflow) = timeoutMilliseconds
            .multipliedReportingOverflow(by: 1_000_000)
        guard !multiplicationOverflow else { return UInt64.max }
        let (deadline, additionOverflow) = now.addingReportingOverflow(delta)
        return additionOverflow ? UInt64.max : deadline
    }

    private func writeExactly(_ data: Data,
                              to handle: FileHandle,
                              deadline: UInt64) throws {
        try data.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            var offset = 0
            while offset < rawBytes.count {
                try waitForDescriptor(handle.fileDescriptor,
                                      events: Int16(POLLOUT),
                                      deadline: deadline)
                let written = guavaSystemWrite(
                    handle.fileDescriptor,
                    baseAddress.advanced(by: offset),
                    min(rawBytes.count - offset, 16 * 1_024)
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw PluginHostClientError.communicationFailed
                }
                guard written > 0 else { throw PluginHostClientError.communicationFailed }
                offset += written
            }
        }
    }

    private func readExactly(_ count: Int,
                             from handle: FileHandle,
                             deadline: UInt64) throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        while result.count < count {
            try waitForDescriptor(handle.fileDescriptor,
                                  events: Int16(POLLIN),
                                  deadline: deadline)
            var buffer = [UInt8](repeating: 0,
                                 count: min(count - result.count, 16 * 1_024))
            let received = buffer.withUnsafeMutableBytes { bytes in
                guavaSystemRead(handle.fileDescriptor,
                                bytes.baseAddress,
                                bytes.count)
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw PluginHostClientError.communicationFailed
            }
            guard received > 0 else { throw PluginHostClientError.communicationFailed }
            result.append(contentsOf: buffer.prefix(received))
        }
        return result
    }

    private func waitForDescriptor(_ fileDescriptor: Int32,
                                   events: Int16,
                                   deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw PluginHostClientError.timedOut }
            let remainingNanoseconds = deadline - now
            let roundedMilliseconds = ((remainingNanoseconds - 1) / 1_000_000) + 1
            let timeout = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fileDescriptor, events: events, revents: 0)
            let result = guavaSystemPoll(&descriptor, timeout)
            if result == 0 { throw PluginHostClientError.timedOut }
            if result < 0 {
                if errno == EINTR { continue }
                throw PluginHostClientError.communicationFailed
            }
            if descriptor.revents & events != 0 { return }
            let failures = Int16(POLLERR | POLLHUP | POLLNVAL)
            if descriptor.revents & failures != 0 {
                throw PluginHostClientError.communicationFailed
            }
        }
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
                           authorization: PluginAuthorizationRecord) throws
        -> PluginExecutionBinding {
        let response = try call(PluginHostRequest(method: .load,
                                                  pluginPath: pluginURL.path,
                                                  authorization: authorization))
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
        _ = try acceptedPayload(response)
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

@inline(__always)
private func guavaSystemPoll(_ descriptor: UnsafeMutablePointer<pollfd>,
                             _ timeout: Int32) -> Int32 {
#if canImport(Darwin)
    Darwin.poll(descriptor, 1, timeout)
#elseif canImport(Glibc)
    Glibc.poll(descriptor, 1, timeout)
#endif
}

@inline(__always)
private func guavaSystemRead(_ fileDescriptor: Int32,
                             _ buffer: UnsafeMutableRawPointer?,
                             _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.read(fileDescriptor, buffer, count)
#elseif canImport(Glibc)
    Glibc.read(fileDescriptor, buffer, count)
#endif
}

@inline(__always)
private func guavaSystemWrite(_ fileDescriptor: Int32,
                              _ buffer: UnsafeRawPointer?,
                              _ count: Int) -> Int {
#if canImport(Darwin)
    Darwin.write(fileDescriptor, buffer, count)
#elseif canImport(Glibc)
    Glibc.write(fileDescriptor, buffer, count)
#endif
}
