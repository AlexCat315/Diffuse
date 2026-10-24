import Foundation
import ProcessRuntime
import Testing

#if os(macOS) || os(Linux)
@Suite("Host process service", .timeLimit(.minutes(1)))
struct ProcessTests {
    private func command(_ script: String) -> ProcessCommand {
        var command = ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"),
                                     directory: FileManager.default.temporaryDirectory)
        command.arguments = ["-c", script]
        return command
    }

    @Test("parallel synchronous discovery does not starve the cooperative executor")
    func parallelSynchronousDiscovery() async throws {
        let count = min(32, max(8, ProcessInfo.processInfo.activeProcessorCount * 2))
        try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
            for _ in 0..<count {
                group.addTask {
                    var budget = ProcessBudget(); budget.lifetimeMilliseconds = 3000
                    return try ProcessRunner.runSynchronously(command("printf ready"), budget: budget)
                }
            }
            for try await result in group {
                #expect(result.status == 0 && String(decoding: result.stdout, as: UTF8.self) == "ready")
            }
        }
    }

    @Test("stdout and stderr are drained through exit, including final bytes")
    func output() async throws {
        let result = try await ProcessRunner.run(command("printf stdout; printf stderr >&2; exit 7"))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "stdout")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "stderr")
        #expect(result.status == 7)
    }

    @Test("stdin is delivered before EOF without inheriting environment variables")
    func input() async throws {
        let result = try await ProcessRunner.run(command("/bin/cat; printf '%s' \"${GUAVA_PROCESS_SECRET-unset}\""), input: Data("hello".utf8))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hellounset")
    }

    @Test("interactive output arrives while standard input remains open")
    func interactiveOutput() async throws {
        let session = try ProcessSession(command: command("printf ready; /bin/cat"))
        defer { session.cancel() }
        var events = session.events.makeAsyncIterator()
        var output = Data()
        while output.count < 5, let event = try await events.next() {
            if case let .stdout(data) = event { output.append(data) }
        }
        #expect(String(decoding: output, as: UTF8.self) == "ready")
        try session.write(Data("ping".utf8))
        while output.count < 9, let event = try await events.next() {
            if case let .stdout(data) = event { output.append(data) }
        }
        #expect(String(decoding: output, as: UTF8.self) == "readyping")
        session.closeInput()
        var status: Int32?
        while let event = try await events.next() {
            if case let .exited(value) = event { status = value }
        }
        #expect(status == 0)
    }

    @Test("output is bounded even when the child never exits")
    func outputLimit() async throws {
        var budget = ProcessBudget(); budget.outputBytes = 100
        await #expect(throws: ProcessRuntimeError.outputLimit) {
            try await ProcessRunner.run(command("while :; do printf 1234567890; done"), budget: budget)
        }
    }

    @Test("a process ignoring TERM is killed after its deadline")
    func deadline() async throws {
        var budget = ProcessBudget(); budget.lifetimeMilliseconds = 100
        let session = try ProcessSession(command: command("trap '' TERM; while :; do :; done"), budget: budget)
        await #expect(throws: ProcessRuntimeError.timedOut) {
            for try await _ in session.events {}
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!session.isRunning)
    }

    @Test("cancellation terminates a long running command")
    func cancellation() async throws {
        let session = try ProcessSession(command: command("while :; do :; done"))
        session.cancel()
        await #expect(throws: CancellationError.self) { for try await _ in session.events {} }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!session.isRunning)
    }

    @Test("pending stdin has a separate budget")
    func inputLimit() throws {
        var budget = ProcessBudget(); budget.pendingInputBytes = 8
        let session = try ProcessSession(command: command("while :; do :; done"), budget: budget)
        defer { session.cancel() }
        #expect(throws: ProcessRuntimeError.inputLimit) { try session.write(Data(repeating: 1, count: 9)) }
    }
}
#endif
