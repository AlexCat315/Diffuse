#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#endif
internal import Foundation

/// Errors raised while starting a terminal program.
public enum TerminalError: Error, Equatable, CustomStringConvertible {
    case executableNotFound(String)
    case spawnFailed(errno: Int32)
    case unsupportedPlatform
    case alreadyStarted

    public var description: String {
        switch self {
        case .executableNotFound(let name): "Executable not found: \(name)"
        case .spawnFailed(let code): "Could not start the terminal program (errno \(code))"
        case .unsupportedPlatform: "Pseudo terminals are not available on this platform"
        case .alreadyStarted: "The terminal session is already running"
        }
    }
}

/// A child process attached to a pseudo terminal.
///
/// Output is read on a private queue and handed to `onOutput` there; callers
/// hop to their own thread. Writes are serialised on a second queue so a slow
/// program can't stall the UI.
final class PseudoTerminal: @unchecked Sendable {
    struct Size: Equatable, Sendable {
        var columns: Int
        var rows: Int
        var cellWidth: Int = 0
        var cellHeight: Int = 0
    }

    let processID: Int32
    private let channel: Channel
    private let readSource: any DispatchSourceRead
    private let writeQueue = DispatchQueue(label: "guava.terminal.pty.write")

    static func spawn(_ command: TerminalCommand,
                      size: Size,
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws -> PseudoTerminal {
        #if canImport(Darwin) || canImport(Glibc)
        let environment = command.resolvedEnvironment()
        guard let path = command.resolvedExecutable(path: environment["PATH"]) else {
            throw TerminalError.executableNotFound(command.executable)
        }
        // Everything the child touches is allocated before fork: between fork
        // and exec only async-signal-safe calls are allowed.
        let argv = CStringArray([path] + command.arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" }.sorted())
        let directory = command.workingDirectory.map { strdup($0.path) } ?? nil
        defer { free(directory) }

        var window = windowSize(size)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &window)
        if pid < 0 { throw TerminalError.spawnFailed(errno: errno) }
        if pid == 0 {
            if let directory { _ = chdir(directory) }
            execve(argv.pointers[0], argv.pointers, envp.pointers)
            _exit(127)
        }
        return PseudoTerminal(processID: pid, master: master, onOutput: onOutput, onExit: onExit)
        #else
        throw TerminalError.unsupportedPlatform
        #endif
    }

    private init(processID: Int32, master: Int32,
                 onOutput: @escaping @Sendable ([UInt8]) -> Void,
                 onExit: @escaping @Sendable (Int32) -> Void) {
        self.processID = processID
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        let channel = Channel(descriptor: master)
        self.channel = channel
        let source = DispatchSource.makeReadSource(fileDescriptor: master,
                                                   queue: DispatchQueue(label: "guava.terminal.pty.read"))
        readSource = source
        source.setEventHandler { [unowned source] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            if count > 0 {
                onOutput(Array(buffer.prefix(count)))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // EOF (macOS) or EIO (Linux): every slave descriptor closed.
                source.cancel()
            }
        }
        source.setCancelHandler {
            channel.close()
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0, errno == EINTR {}
            onExit(Self.exitCode(status))
        }
        source.resume()
    }

    deinit {
        terminate()
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let channel = channel
        writeQueue.async { channel.write(bytes) }
    }

    func resize(_ size: Size) {
        channel.resize(windowSize(size))
    }

    /// Hang up the program, as closing a terminal window does.
    func terminate() {
        channel.signal(processID, SIGHUP)
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}

/// Owns the master descriptor. Every use happens under the lock, so nothing
/// touches the descriptor (or a later reuse of its number) after `close`.
private final class Channel: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) { self.descriptor = descriptor }

    func write(_ bytes: [UInt8]) {
        lock.withLock {
            guard let descriptor else { return }
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Foundation.write(descriptor, $0.baseAddress, $0.count) }
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR || errno == EAGAIN { continue }
                return
            }
        }
    }

    func resize(_ window: winsize) {
        lock.withLock {
            guard let descriptor else { return }
            var window = window
            _ = ioctl(descriptor, UInt(TIOCSWINSZ), &window)
        }
    }

    /// Signals the child while it is still unreaped, so a recycled pid is never hit.
    func signal(_ processID: Int32, _ signal: Int32) {
        lock.withLock {
            guard descriptor != nil else { return }
            kill(processID, signal)
        }
    }

    func close() {
        lock.withLock {
            guard let descriptor else { return }
            _ = Foundation.close(descriptor)
            self.descriptor = nil
        }
    }
}

private func windowSize(_ size: PseudoTerminal.Size) -> winsize {
    winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns),
            ws_xpixel: UInt16(clamping: size.columns * size.cellWidth),
            ws_ypixel: UInt16(clamping: size.rows * size.cellHeight))
}

/// NULL-terminated `char *[]` that outlives a fork.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointers = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() { pointers[index] = strdup(string) }
        pointers[count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}
