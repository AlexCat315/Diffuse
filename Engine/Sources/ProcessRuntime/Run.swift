public import Foundation

public enum ProcessRunner {
    /// For synchronous host discovery hooks. Interactive work should use run
    /// so waiting and cancellation do not occupy the caller's thread.
    public static func runSynchronously(_ command: ProcessCommand, budget: ProcessBudget = .init()) throws -> ProcessOutput {
        guard let milliseconds = budget.lifetimeMilliseconds else { throw ProcessRuntimeError.invalidBudget }
        let result = BlockingProcessResult()
        let task = Task.detached {
            do { result.finish(.success(try await run(command, budget: budget))) }
            catch { result.finish(.failure(error)) }
        }
        guard result.ready.wait(timeout: .now() + .milliseconds(milliseconds + 1000)) == .success else {
            task.cancel()
            throw ProcessRuntimeError.timedOut
        }
        return try result.value().get()
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
                switch event {
                case let .stdout(data): result.stdout.append(data)
                case let .stderr(data): result.stderr.append(data)
                case let .exited(status): result.status = status
                case .stdoutClosed, .stderrClosed: break
                }
                guard result.stdout.count + result.stderr.count <= budget.outputBytes else {
                    session.cancel()
                    throw ProcessRuntimeError.outputLimit
                }
            }
            return result
        } onCancel: { session.cancel() }
    }
}

private final class BlockingProcessResult: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<ProcessOutput, Error>?
    func finish(_ result: Result<ProcessOutput, Error>) { lock.withLock { self.result = result }; ready.signal() }
    func value() -> Result<ProcessOutput, Error> { lock.withLock { result! } }
}
