public import Foundation

public enum ProcessRunner {
    /// For synchronous host discovery hooks. Interactive work should use run
    /// so waiting and cancellation do not occupy the caller's thread.
    public static func runSynchronously(_ command: ProcessCommand, budget: ProcessBudget = .init()) throws -> ProcessOutput {
        guard budget.lifetimeMilliseconds != nil else { throw ProcessRuntimeError.invalidBudget }
        let session = try ProcessSession(command: command, budget: budget)
        session.closeInput()
        var result = ProcessOutput()
        do {
            while let event = try session.nextSynchronously() {
                result.append(event)
                guard result.stdout.count + result.stderr.count <= budget.outputBytes else {
                    throw ProcessRuntimeError.outputLimit
                }
            }
            return result
        } catch {
            session.cancel()
            throw error
        }
    }

    public static func run(_ command: ProcessCommand, input: Data = Data(),
                           budget: ProcessBudget = .init()) async throws -> ProcessOutput {
        let session = try ProcessSession(command: command, budget: budget)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if !input.isEmpty { try session.write(input) }
            session.closeInput()
            var result = ProcessOutput()
            for try await event in session.events {
                try Task.checkCancellation()
                result.append(event)
                guard result.stdout.count + result.stderr.count <= budget.outputBytes else {
                    session.cancel()
                    throw ProcessRuntimeError.outputLimit
                }
            }
            return result
        } onCancel: { session.cancel() }
    }
}

private extension ProcessOutput {
    mutating func append(_ event: ProcessEvent) {
        switch event {
        case let .stdout(data): stdout.append(data)
        case let .stderr(data): stderr.append(data)
        case let .exited(code): status = code
        case .stdoutClosed, .stderrClosed: break
        }
    }
}
