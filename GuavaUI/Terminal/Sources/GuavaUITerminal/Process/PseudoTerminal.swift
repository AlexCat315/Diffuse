internal import Foundation

/// Errors raised while starting a terminal program.
public enum TerminalError: Error, Equatable, CustomStringConvertible {
    case executableNotFound(String)
    /// `code` is `errno` on macOS/Linux and a Win32 error / HRESULT on Windows.
    case spawnFailed(code: Int32)
    case unsupportedPlatform
    case alreadyStarted

    public var description: String {
        switch self {
        case .executableNotFound(let name): "Executable not found: \(name)"
        case .spawnFailed(let code): "Could not start the terminal program (error \(code))"
        case .unsupportedPlatform: "Pseudo terminals are not available on this platform"
        case .alreadyStarted: "The terminal session is already running"
        }
    }
}

/// One platform's pseudo terminal: `forkpty` on macOS/Linux, ConPTY on Windows.
protocol PseudoTerminalBackend: AnyObject, Sendable {
    var processID: Int32 { get }
    /// May block until the program reads; called on a serial background queue.
    func write(_ bytes: [UInt8])
    func resize(_ size: PseudoTerminal.Size)
    /// Hang up the program, as closing a terminal window does.
    func terminate()
}

/// A child process attached to a pseudo terminal.
///
/// Output is read in the background and handed to `onOutput` there; callers
/// hop to their own thread. Writes are serialised on a second queue so a slow
/// program can't stall the UI.
final class PseudoTerminal: @unchecked Sendable {
    struct Size: Equatable, Sendable {
        var columns: Int
        var rows: Int
        var cellWidth: Int = 0
        var cellHeight: Int = 0
    }

    private let backend: any PseudoTerminalBackend
    private let writeQueue = DispatchQueue(label: "guava.terminal.pty.write")

    var processID: Int32 { backend.processID }

    static func spawn(_ command: TerminalCommand,
                      size: Size,
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws -> PseudoTerminal {
        #if os(Windows)
        PseudoTerminal(backend: try ConPTY.spawn(command, size: size, onOutput: onOutput, onExit: onExit))
        #elseif canImport(Darwin) || canImport(Glibc)
        PseudoTerminal(backend: try POSIXPseudoTerminal.spawn(command, size: size, onOutput: onOutput, onExit: onExit))
        #else
        throw TerminalError.unsupportedPlatform
        #endif
    }

    private init(backend: any PseudoTerminalBackend) {
        self.backend = backend
    }

    deinit {
        backend.terminate()
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let backend = backend
        writeQueue.async { backend.write(bytes) }
    }

    func resize(_ size: Size) {
        backend.resize(size)
    }

    func terminate() {
        backend.terminate()
    }
}
