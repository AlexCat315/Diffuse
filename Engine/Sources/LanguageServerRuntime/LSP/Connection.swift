import Foundation
import ProcessRuntime

final class LSPConnection: @unchecked Sendable {
    let id = UUID()
    let session: ProcessSession
    var consumer: Task<Void, Never>?
    var isRunning: Bool { session.isRunning }
    var events: AsyncThrowingStream<ProcessEvent, Error> { session.events }
    init(command: ProcessCommand) throws {
        var budget = ProcessBudget()
        budget.lifetimeMilliseconds = nil
        budget.outputBytes = LSPMessageFramer.maximumBodyBytes
        session = try ProcessSession(command: command, budget: budget)
    }
    func close() { consumer?.cancel(); consumer = nil; session.cancel() }
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
