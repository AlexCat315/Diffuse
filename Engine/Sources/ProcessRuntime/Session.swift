public import Foundation

#if os(macOS) || os(Linux) || os(Windows)
/// One native process lifetime, shared by LSP, tasks and extension imports.
/// Pipe readers drain concurrently; queued writes never block the caller.
public final class ProcessSession: @unchecked Sendable {
    public let id = UUID()
    public let events: AsyncThrowingStream<ProcessEvent, Error>
    private let eventBuffer: ProcessEventBuffer
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writer = DispatchQueue(label: "guava.process.input")
    private let state = ProcessIOState()
    private let budget: ProcessBudget

    public init(command: ProcessCommand, budget: ProcessBudget = .init()) throws {
        guard command.executable.isFileURL, command.directory.isFileURL,
              !command.executable.path.isEmpty,
              !command.arguments.contains(where: { $0.contains("\0") }),
              command.environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw ProcessRuntimeError.invalidCommand
        }
        guard budget.outputBytes > 0, budget.outputBytes <= 33_554_432,
              budget.pendingInputBytes > 0, budget.pendingInputBytes <= 33_554_432,
              budget.lifetimeMilliseconds.map({ $0 > 0 && $0 <= 86_400_000 }) ?? true else {
            throw ProcessRuntimeError.invalidBudget
        }
        self.budget = budget
        let eventBuffer = ProcessEventBuffer(maximumBytes: budget.outputBytes)
        self.eventBuffer = eventBuffer
        events = AsyncThrowingStream(unfolding: { try await eventBuffer.next() })
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.directory
        process.environment = command.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        ProcessPlatform.prepareInput(input.fileHandleForWriting)
        process.terminationHandler = { [weak self] process in self?.terminated(process.terminationStatus) }
        do { try process.run() } catch {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            close()
            throw error
        }
        installReader(output.fileHandleForReading, isError: false)
        installReader(errors.fileHandleForReading, isError: true)
        ProcessPlatform.isolate(process.processIdentifier)
        if let milliseconds = budget.lifetimeMilliseconds {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(milliseconds))
            timer.setEventHandler { [weak self] in self?.fail(ProcessRuntimeError.timedOut) }
            state.installTimer(timer)
            timer.resume()
        }
    }

    deinit { close() }

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    public func write(_ data: Data) throws {
        try state.enqueue(data.count, maximum: budget.pendingInputBytes)
        writer.async { [self] in
            defer { state.wrote(data.count) }
            do { try ProcessPlatform.write(data, to: input.fileHandleForWriting) }
            catch { fail(error) }
        }
    }

    public func closeInput() {
        writer.async { [self] in try? input.fileHandleForWriting.close() }
    }

    public func cancel() { fail(CancellationError()) }

    func nextSynchronously() throws -> ProcessEvent? { try eventBuffer.nextSynchronously() }

    private func installReader(_ handle: FileHandle, isError: Bool) {
        let thread = Thread { [weak self] in
            // The reader owns this handle until its blocking read completes.
            // Closing it from deinit races fileDescriptor access on macOS.
            defer { try? handle.close() }
            do {
                while true {
                    let data = try ProcessPlatform.read(from: handle)
                    if data.isEmpty { break }
                    guard let self else { return }
                    if !eventBuffer.append(isError ? .stderr(data) : .stdout(data)) {
                        fail(ProcessRuntimeError.outputLimit)
                        return
                    }
                }
                guard let self else { return }
                _ = eventBuffer.append(isError ? .stderrClosed : .stdoutClosed)
                if let status = state.closedPipe() { finish(status) }
            } catch { self?.fail(error) }
        }
        thread.name = isError ? "guava.process.stderr" : "guava.process.stdout"
        thread.start()
    }

    private func terminated(_ status: Int32) {
        state.cancelTimer()
        if state.terminated(status) { finish(status) }
    }

    private func finish(_ status: Int32) {
        _ = eventBuffer.append(.exited(status))
        eventBuffer.finish()
    }

    private func fail(_ error: Error) {
        guard state.stop() else { return }
        eventBuffer.finish(throwing: error)
        state.cancelTimer()
        ProcessPlatform.terminate(process, force: false)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(300)) { [process] in
            ProcessPlatform.terminate(process, force: true)
        }
    }

    private func close() {
        state.cancelTimer()
        _ = state.stop()
        eventBuffer.finish()
        process.terminationHandler = nil
        ProcessPlatform.terminate(process, force: true)
        try? input.fileHandleForWriting.close()
    }
}
#else
public final class ProcessSession: @unchecked Sendable {
    public let id = UUID()
    public let events = AsyncThrowingStream<ProcessEvent, Error> { $0.finish(throwing: ProcessRuntimeError.unavailable) }
    public init(command: ProcessCommand, budget: ProcessBudget = .init()) throws { throw ProcessRuntimeError.unavailable }
    public var isRunning: Bool { false }
    public var processIdentifier: Int32 { 0 }
    public func write(_ data: Data) throws { throw ProcessRuntimeError.unavailable }
    public func closeInput() {}
    public func cancel() {}
}
#endif
