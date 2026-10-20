internal import Foundation
internal import GuavaUIRuntime

/// A terminal emulator bound to one program.
///
/// Create it once (for example in `@State`) and show it with `TerminalView`,
/// which starts the program when it first appears. The session outlives view
/// updates, so recomposition never restarts the program. Like every GuavaUI
/// model it is used from the UI thread; program output is read in the
/// background and applied there.
///
/// ```swift
/// @State private var shell = TerminalSession()
///
/// TerminalView(session: shell)
///     .frame(height: 320)
/// ```
public final class TerminalSession {
    public enum Status: Equatable, Sendable {
        case idle
        case running
        case exited(code: Int32)
        case failed(TerminalError)
    }

    public enum Event: Equatable, Sendable {
        case titleChanged(String)
        case bell
        case exited(code: Int32)
    }

    public let command: TerminalCommand
    public private(set) var status: Status = .idle
    /// Window title set by the program (OSC 0/2); empty until one is set.
    public private(set) var title = ""
    /// Called on the UI thread.
    public var onEvent: ((Event) -> Void)?

    let engine: TerminalEngine
    private var process: PseudoTerminal?
    private let inbox = OutputInbox()
    private let schedule: ((@escaping () -> Void) -> Void)?
    private var cachedFrame: TerminalFrame?
    private var cellSize = (width: 0, height: 0)
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    public convenience init(command: TerminalCommand = .loginShell, scrollbackLines: Int = 10_000) {
        self.init(command: command, scrollbackLines: scrollbackLines, schedule: nil)
    }

    /// `schedule` runs work on the thread that owns the session; `nil` uses
    /// the host's UI scheduler as installed when `start()` runs.
    init(command: TerminalCommand, scrollbackLines: Int, schedule: ((@escaping () -> Void) -> Void)?) {
        self.command = command
        self.schedule = schedule
        engine = TerminalEngine(columns: 80, rows: 24, scrollbackLines: scrollbackLines)
        inbox.session = self
        engine.onReply = { [weak self] bytes in self?.process?.write(bytes) }
        engine.onBell = { [weak self] in self?.onEvent?(.bell) }
        engine.onTitleChange = { [weak self] title in
            guard let self, self.title != title else { return }
            self.title = title
            self.onEvent?(.titleChanged(title))
        }
    }

    deinit {
        process?.terminate()
    }

    /// Launches the program. `TerminalView` calls this when it first shows an
    /// idle session. A session runs one program once; create a new session to
    /// run again. Failures are also shown in the terminal itself.
    public func start() throws {
        guard status == .idle else { throw TerminalError.alreadyStarted }
        inbox.schedule = schedule ?? UIWorkSchedulerHolder.enqueue ?? { DispatchQueue.main.async(execute: $0) }
        let inbox = inbox
        do {
            process = try PseudoTerminal.spawn(
                command,
                size: .init(columns: engine.columns, rows: engine.rows,
                            cellWidth: cellSize.width, cellHeight: cellSize.height),
                onOutput: { inbox.append($0) },
                onExit: { inbox.finish(code: $0) })
        } catch let error as TerminalError {
            status = .failed(error)
            feed(Array("[\(error)]\r\n".utf8))
            throw error
        }
        status = .running
    }

    /// Sends text as if typed, e.g. `send("ls\r")`.
    public func send(_ text: String) {
        write(Array(text.utf8))
    }

    /// Pastes text using the program's bracketed-paste mode when enabled.
    public func paste(_ text: String) {
        write(engine.encodePaste(text))
    }

    /// Hangs up the program (SIGHUP). `status` becomes `.exited` once it quits.
    public func terminate() {
        process?.terminate()
    }

    // MARK: Internal (view and tests)

    var frame: TerminalFrame {
        if let cachedFrame { return cachedFrame }
        let frame = engine.snapshot()
        cachedFrame = frame
        return frame
    }

    func feed(_ bytes: [UInt8]) {
        engine.feed(bytes)
        invalidate()
    }

    /// Writes user input. Like typing in any terminal, input returns the
    /// viewport to the live screen and drops the selection.
    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let scrolled = !frame.scroll.isAtBottom
        if scrolled { engine.scrollToBottom() }
        if engine.clearSelection() || scrolled { invalidate() }
        process?.write(bytes)
    }

    /// Bytes the program asked for (mouse reports) that are not user typing.
    func report(_ bytes: [UInt8]) {
        process?.write(bytes)
    }

    @discardableResult
    func press(_ key: TerminalKey) -> Bool {
        let bytes = engine.encode(key)
        write(bytes)
        return !bytes.isEmpty
    }

    func scroll(rows: Int) {
        guard rows != 0 else { return }
        engine.scroll(rows: rows)
        invalidate()
    }

    var isAlternateScreen: Bool { engine.isAlternateScreen }

    func fit(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard columns != engine.columns || rows != engine.rows
              || cellWidth != cellSize.width || cellHeight != cellSize.height else { return }
        cellSize = (cellWidth, cellHeight)
        engine.resize(columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        process?.resize(.init(columns: engine.columns, rows: engine.rows,
                              cellWidth: cellWidth, cellHeight: cellHeight))
        cachedFrame = nil
    }

    func setDefaultColors(foreground: TerminalRGB, background: TerminalRGB) {
        engine.setDefaultColors(foreground: foreground, background: background)
        cachedFrame = nil
    }

    func observe(_ owner: AnyObject, _ onChange: @escaping () -> Void) {
        observers[ObjectIdentifier(owner)] = onChange
    }

    func removeObserver(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    fileprivate func finish(code: Int32) {
        process = nil
        status = .exited(code: code)
        feed(Array("\r\n[Process exited with code \(code)]\r\n".utf8))
        onEvent?(.exited(code: code))
    }

    func invalidate() {
        cachedFrame = nil
        for observer in observers.values { observer() }
    }
}

/// Collects output from the PTY read queue and applies it on the UI thread in
/// one batch, however many reads arrived since the last frame.
private final class OutputInbox: @unchecked Sendable {
    weak var session: TerminalSession?
    /// Set on the UI thread before the process exists; read on the PTY queue.
    var schedule: (@escaping () -> Void) -> Void = { _ in }
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var exitCode: Int32?
    private var isScheduled = false

    func append(_ bytes: [UInt8]) {
        enqueue { $0.pending += bytes }
    }

    func finish(code: Int32) {
        enqueue { $0.exitCode = code }
    }

    private func enqueue(_ change: (OutputInbox) -> Void) {
        let needsSchedule = lock.withLock { () -> Bool in
            change(self)
            defer { isScheduled = true }
            return !isScheduled
        }
        if needsSchedule { schedule { self.drain() } }
    }

    private func drain() {
        let (bytes, code) = lock.withLock { () -> ([UInt8], Int32?) in
            defer { pending.removeAll(keepingCapacity: true); exitCode = nil; isScheduled = false }
            return (pending, exitCode)
        }
        guard let session else { return }
        if !bytes.isEmpty { session.feed(bytes) }
        if let code { session.finish(code: code) }
    }
}
