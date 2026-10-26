import Foundation
internal import CoveProcess

final class LSPConnection: @unchecked Sendable {
    let id = UUID()
    let transport: LanguageServerTransport
    var consumer: Task<Void, Never>?
    private(set) var isRunning = true
    var events: AsyncThrowingStream<ProcessEvent, Error> { transport.events }
    init(configuration: LanguageServerConfiguration) throws {
        if let connect = configuration.connect {
            transport = try connect(configuration.command)
        } else {
            var budget = ProcessBudget()
            budget.lifetimeMilliseconds = nil
            budget.outputBytes = LSPMessageFramer.maximumBodyBytes
            let session = try ProcessSession(command: configuration.command, budget: budget)
            transport = LanguageServerTransport(events: session.events,
                write: { try session.write($0) }, stop: { session.cancel() })
        }
    }
    func close() { isRunning = false; consumer?.cancel(); consumer = nil; transport.stop() }
}

public struct LSPFailure: Sendable, Equatable {
    public let error: LSPClientError
    public let stderr: String

    public init(error: LSPClientError, stderr: String = "") {
        self.error = error
        self.stderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var message: String {
        let reason = error.localizedDescription
        return stderr.isEmpty ? reason : "\(reason)\n\(stderr)"
    }
}
