import Foundation

public enum PluginHostClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case launchFailed(String)
    case communicationFailed
    case hostRestarted(generation: UInt64)
    case mismatchedResponse

    public var description: String {
        switch self {
        case let .launchFailed(message): return "could not launch GuavaPluginHost: \(message)"
        case .communicationFailed: return "GuavaPluginHost pipe communication failed"
        case let .hostRestarted(generation): return "GuavaPluginHost restarted; invalidate plugin plans at generation \(generation)"
        case .mismatchedResponse: return "GuavaPluginHost returned a mismatched response id"
        }
    }
}

/// Editor-side owner of the isolated host process. A crash triggers one restart,
/// increments `generation`, and fails the interrupted request so every pending
/// plugin draft can be invalidated by the caller.
public final class PluginHostProcessClient: @unchecked Sendable {
    public let executableURL: URL
    public private(set) var generation: UInt64 = 0
    public var onInvalidation: (@Sendable (UInt64) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var didRestart = false

    public init(executableURL: URL,
                onInvalidation: (@Sendable (UInt64) -> Void)? = nil) {
        self.executableURL = executableURL
        self.onInvalidation = onInvalidation
    }

    deinit { stop() }

    public func call(_ request: PluginHostRequest) throws -> PluginHostResponse {
        try lock.withLock {
            do {
                if process?.isRunning != true { try launch() }
                guard let input, let output else { throw PluginHostClientError.communicationFailed }
                try input.write(contentsOf: PluginHostFrameCodec.encode(request))
                guard let header = readExactly(4, from: output) else {
                    throw PluginHostClientError.communicationFailed
                }
                let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length <= PluginHostFrameCodec.maximumFrameBytes,
                      let payload = readExactly(Int(length), from: output) else {
                    throw PluginHostClientError.communicationFailed
                }
                var frame = header
                frame.append(payload)
                let response = try PluginHostFrameCodec.decode(PluginHostResponse.self, from: frame)
                guard response.id == request.id else { throw PluginHostClientError.mismatchedResponse }
                return response
            } catch {
                guard !didRestart else { throw error }
                stopLocked()
                didRestart = true
                generation &+= 1
                try? launch()
                onInvalidation?(generation)
                throw PluginHostClientError.hostRestarted(generation: generation)
            }
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
    }

    private func stopLocked() {
        try? input?.close()
        try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
    }

    private func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
        var result = Data()
        while result.count < count {
            let chunk = handle.readData(ofLength: count - result.count)
            if chunk.isEmpty { return nil }
            result.append(chunk)
        }
        return result
    }
}
