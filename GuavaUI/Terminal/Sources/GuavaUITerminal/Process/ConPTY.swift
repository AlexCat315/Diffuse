#if os(Windows)
internal import Foundation
internal import WinSDK

/// Windows backend: a ConPTY pseudo console (Windows 10 1809+).
///
/// ConPTY keeps its output pipe open after the program exits, so a watcher
/// thread waits for the process, closes the console, and the reader thread
/// then drains the remaining output and sees end-of-file.
final class ConPTY: PseudoTerminalBackend, @unchecked Sendable {
    let processID: Int32
    private let lock = NSLock()
    private var console: HPCON?
    private let input: HANDLE
    private let process: HANDLE

    /// `ProcThreadAttributeValue(22, FALSE, TRUE, FALSE)`; the macro is not imported.
    private static let pseudoConsoleAttribute = DWORD_PTR(0x0002_0016)

    static func spawn(_ command: TerminalCommand,
                      size: PseudoTerminal.Size,
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws -> ConPTY {
        let environment = command.resolvedEnvironment()
        guard let path = command.resolvedExecutable(path: environment["Path"] ?? environment["PATH"]) else {
            throw TerminalError.executableNotFound(command.executable)
        }

        var inputRead: HANDLE?, inputWrite: HANDLE?, outputRead: HANDLE?, outputWrite: HANDLE?
        guard CreatePipe(&inputRead, &inputWrite, nil, 0), CreatePipe(&outputRead, &outputWrite, nil, 0),
              let inputRead, let inputWrite, let outputRead, let outputWrite else {
            throw TerminalError.spawnFailed(code: Int32(bitPattern: GetLastError()))
        }
        var console: HPCON?
        let created = CreatePseudoConsole(coord(size), inputRead, outputWrite, 0, &console)
        // The console holds its own references to these ends.
        CloseHandle(inputRead)
        CloseHandle(outputWrite)
        guard created == S_OK, let console else {
            CloseHandle(inputWrite); CloseHandle(outputRead)
            throw TerminalError.spawnFailed(code: created)
        }

        var listSize: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &listSize)
        let listStorage = UnsafeMutableRawPointer.allocate(byteCount: Int(listSize), alignment: 16)
        let attributes = LPPROC_THREAD_ATTRIBUTE_LIST(OpaquePointer(listStorage))
        defer { DeleteProcThreadAttributeList(attributes); listStorage.deallocate() }
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &listSize),
              UpdateProcThreadAttribute(attributes, 0, pseudoConsoleAttribute, console,
                                        SIZE_T(MemoryLayout<HPCON>.size), nil, nil) else {
            let error = Int32(bitPattern: GetLastError())
            ClosePseudoConsole(console); CloseHandle(inputWrite); CloseHandle(outputRead)
            throw TerminalError.spawnFailed(code: error)
        }

        var startup = STARTUPINFOEXW()
        startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        startup.lpAttributeList = attributes
        var information = PROCESS_INFORMATION()
        var commandLine = Array(WindowsCommandLine.commandLineString([path] + command.arguments).utf16) + [0]
        var environmentBlock = WindowsCommandLine.environmentBlockUTF16(environment)
        let directory = command.workingDirectory.map { Array($0.path.utf16) + [0] }
        let flags = DWORD(EXTENDED_STARTUPINFO_PRESENT) | DWORD(CREATE_UNICODE_ENVIRONMENT)
        let launched = withUnsafeMutablePointer(to: &startup) { startupPointer in
            startupPointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startupInfo in
                environmentBlock.withUnsafeMutableBufferPointer { block in
                    if let directory {
                        return directory.withUnsafeBufferPointer { cwd in
                            CreateProcessW(nil, &commandLine, nil, nil, false, flags, block.baseAddress,
                                           cwd.baseAddress, startupInfo, &information)
                        }
                    }
                    return CreateProcessW(nil, &commandLine, nil, nil, false, flags, block.baseAddress,
                                          nil, startupInfo, &information)
                }
            }
        }
        guard launched, let process = information.hProcess else {
            let error = Int32(bitPattern: GetLastError())
            ClosePseudoConsole(console); CloseHandle(inputWrite); CloseHandle(outputRead)
            throw TerminalError.spawnFailed(code: error)
        }
        if let thread = information.hThread { CloseHandle(thread) }

        let terminal = ConPTY(processID: Int32(bitPattern: information.dwProcessId),
                              console: console, input: inputWrite, process: process)
        terminal.startReading(outputRead, onOutput: onOutput, onExit: onExit)
        return terminal
    }

    private init(processID: Int32, console: HPCON, input: HANDLE, process: HANDLE) {
        self.processID = processID
        self.console = console
        self.input = input
        self.process = process
    }

    private func startReading(_ output: HANDLE, onOutput: @escaping @Sendable ([UInt8]) -> Void,
                              onExit: @escaping @Sendable (Int32) -> Void) {
        let process = process
        let reader = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                var count: DWORD = 0
                let ok = buffer.withUnsafeMutableBytes { ReadFile(output, $0.baseAddress, DWORD($0.count), &count, nil) }
                guard ok, count > 0 else { break }
                onOutput(Array(buffer.prefix(Int(count))))
            }
            CloseHandle(output)
            var code: DWORD = 0
            WaitForSingleObject(process, INFINITE)
            GetExitCodeProcess(process, &code)
            self.closeConsole()
            lock.withLock { CloseHandle(input) }
            CloseHandle(process)
            onExit(Int32(bitPattern: code))
        }
        reader.name = "guava.terminal.conpty.read"
        reader.start()
        let watcher = Thread { [self] in
            WaitForSingleObject(process, INFINITE)
            // Lets the reader drain the last output and reach end-of-file.
            self.closeConsole()
        }
        watcher.name = "guava.terminal.conpty.exit"
        watcher.start()
    }

    func write(_ bytes: [UInt8]) {
        lock.withLock {
            guard console != nil else { return }
            var offset = 0
            while offset < bytes.count {
                var written: DWORD = 0
                let ok = bytes[offset...].withUnsafeBytes {
                    WriteFile(input, $0.baseAddress, DWORD($0.count), &written, nil)
                }
                guard ok, written > 0 else { return }
                offset += Int(written)
            }
        }
    }

    func resize(_ size: PseudoTerminal.Size) {
        lock.withLock {
            guard let console else { return }
            _ = ResizePseudoConsole(console, Self.coord(size))
        }
    }

    /// Closing the console sends console programs CTRL_CLOSE_EVENT, as
    /// closing a console window does.
    func terminate() {
        closeConsole()
    }

    private func closeConsole() {
        let closing: HPCON? = lock.withLock {
            defer { console = nil }
            return console
        }
        if let closing { ClosePseudoConsole(closing) }
    }

    private static func coord(_ size: PseudoTerminal.Size) -> COORD {
        COORD(X: SHORT(clamping: max(1, size.columns)), Y: SHORT(clamping: max(1, size.rows)))
    }
}
#endif
