import Foundation

/// Resources and ordered read events belonging to a single process lifetime.
/// One consumer preserves stdout byte order, including when actor scheduling
/// is delayed. Its identity prevents old EOF/termination events stopping a
/// replacement process.
final class SourceKitLSPConnection: @unchecked Sendable {
    enum Event: Sendable {
        case stdout(Data)
        case stderr(Data)
        case stdoutClosed
        case terminated(Int32)
    }
    let id = UUID()
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    var consumer: Task<Void, Never>?

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func installPipes() {
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let continuation = continuation
        process.terminationHandler = { process in
            continuation.yield(.terminated(process.terminationStatus))
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.yield(.stdoutClosed)
            } else {
                continuation.yield(.stdout(data))
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { continuation.yield(.stderr(data)) }
        }
    }

    func close() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        continuation.finish()
        consumer?.cancel()
        consumer = nil
        process.terminationHandler = nil
        try? stdin.fileHandleForWriting.close()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
    }
}

public struct SourceKitLSPFailure: Sendable, Equatable {
    public let error: SourceKitLSPClientError
    public let stderr: String

    public init(error: SourceKitLSPClientError, stderr: String = "") {
        self.error = error
        self.stderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var message: String {
        let reason = error.localizedDescription
        return stderr.isEmpty ? reason : "\(reason)\n\(stderr)"
    }
}
