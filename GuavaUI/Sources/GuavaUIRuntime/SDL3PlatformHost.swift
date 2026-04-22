import EngineKernel
import Foundation
import Logging
import PlatformShell

@MainActor
public final class PlatformWindowSession {
    public let id: WindowID
    public let tree: NodeTree
    public let recomposer: Recomposer
    public let inputContext: PlatformInputContext

    fileprivate let dispatcher: EventDispatcher
    fileprivate var didCallOnInit = false
    fileprivate var lastTextInputArea: TextInputArea?
    fileprivate var needsDisplay = true

    public private(set) var drawableSize: (width: UInt32, height: UInt32)
    public private(set) var logicalSize: (width: UInt32, height: UInt32)

    public var interactions: InteractionRegistry { inputContext.interactions }
    public var pointerCapture: PointerCapture { inputContext.pointerCapture }
    public var focusChain: FocusChain { inputContext.focusChain }

    public var contentScaleFactor: Float {
        let logicalWidth = max(logicalSize.width, 1)
        return Float(drawableSize.width) / Float(logicalWidth)
    }

    public var onFrame: (@MainActor (NativeRenderSurface) -> Void)?
    public var onInit: (@MainActor (NativeRenderSurface, _ widthPx: UInt32, _ heightPx: UInt32) -> Void)?
    public var onResize: (@MainActor (UInt32, UInt32) -> Void)?
    public var onEvent: (@MainActor (InputEvent) -> Void)?

    fileprivate init(id: WindowID,
                     tree: NodeTree,
                     recomposer: Recomposer,
                     inputContext: PlatformInputContext,
                     drawableSize: (width: UInt32, height: UInt32),
                     logicalSize: (width: UInt32, height: UInt32)) {
        self.id = id
        self.tree = tree
        self.recomposer = recomposer
        self.inputContext = inputContext
        self.drawableSize = drawableSize
        self.logicalSize = logicalSize
        self.dispatcher = EventDispatcher(
            tree: tree,
            interactions: inputContext.interactions,
            capture: inputContext.pointerCapture,
            focusChain: inputContext.focusChain,
            windowID: id
        )
    }

    @discardableResult
    public func withCurrent<R>(_ body: () throws -> R) rethrows -> R {
        try inputContext.withCurrent(body)
    }

    fileprivate func updateMetrics(from handle: any WindowHandle) -> Bool {
        let nextDrawable = handle.drawableSize
        let nextLogical = handle.logicalSize
        guard nextDrawable != drawableSize || nextLogical != logicalSize else {
            return false
        }
        drawableSize = nextDrawable
        logicalSize = nextLogical
        return true
    }
}

/// `PlatformHost` backed by SDL3 via Engine's `PlatformShell`.
///
/// The host keeps one runtime session per native window: each session owns its
/// own `NodeTree`, `Recomposer`, input registry, focus chain and capture state.
/// The main-window convenience properties remain for existing single-window
/// demos and tests.
@MainActor
public final class SDL3PlatformHost: PlatformHost {
    private let title: String
    private let shellFactory: @MainActor () throws -> any Shell
    private let mainInputContext: PlatformInputContext
    private let mainRecomposer: Recomposer

    private var shell: (any Shell)?
    private var sessions: [WindowID: PlatformWindowSession] = [:]
    private var sessionOrder: [WindowID] = []
    private var mainWindowID: WindowID?
    private var _isRunning: Bool = false

    public var recomposer: Recomposer { mainRecomposer }
    public var interactions: InteractionRegistry { mainInputContext.interactions }
    public var pointerCapture: PointerCapture { mainInputContext.pointerCapture }
    public var focusChain: FocusChain { mainInputContext.focusChain }

    public private(set) var drawableSize: (width: UInt32, height: UInt32) = (1, 1)
    public private(set) var logicalSize: (width: UInt32, height: UInt32) = (1, 1)

    public var isRunning: Bool { _isRunning }
    public var contentScaleFactor: Float {
        let logicalWidth = max(logicalSize.width, 1)
        return Float(drawableSize.width) / Float(logicalWidth)
    }

    public var onFrame: (@MainActor (NativeRenderSurface) -> Void)?
    public var onInit: (@MainActor (NativeRenderSurface, _ widthPx: UInt32, _ heightPx: UInt32) -> Void)?
    public var onResize: (@MainActor (UInt32, UInt32) -> Void)?
    public var onEvent: (@MainActor (InputEvent) -> Void)?

    public init(title: String = "GuavaUI",
                recomposer: Recomposer = Recomposer(),
                inputContext: PlatformInputContext = PlatformInputContext(),
                shellFactory: @escaping @MainActor () throws -> any Shell = { try makeDefaultShell() }) {
        self.title = title
        self.mainRecomposer = recomposer
        self.mainInputContext = inputContext
        self.shellFactory = shellFactory
    }

    /// Open an additional window and register a runtime session for it.
    @discardableResult
    public func openWindow(title: String,
                           tree: NodeTree,
                           recomposer: Recomposer = Recomposer(),
                           inputContext: PlatformInputContext = PlatformInputContext(),
                           options: WindowOptions = WindowOptions()) throws -> PlatformWindowSession {
        let shell = try resolveShell()
        let handle = try shell.createWindow(title: title, options: options)
        let session = makeSession(handle: handle,
                                  tree: tree,
                                  recomposer: recomposer,
                                  inputContext: inputContext,
                                  isMain: mainWindowID == nil)
        return session
    }

    public func session(for windowID: WindowID) -> PlatformWindowSession? {
        sessions[windowID]
    }

    public var windowIDs: [WindowID] {
        sessionOrder.filter { sessions[$0] != nil }
    }

    /// Desktop position of `windowID`'s upper-left corner, in window-manager
    /// coordinates. Returns `nil` if the shell is not yet initialised or the
    /// window has been closed.
    public func windowPosition(_ windowID: WindowID) -> (x: Float, y: Float)? {
        shell?.windowPosition(windowID)
    }

    /// Move `windowID` to a desktop position.
    public func setWindowPosition(_ windowID: WindowID, x: Float, y: Float) {
        shell?.setWindowPosition(windowID, x: x, y: y)
    }

    /// Destroy a window. The matching `PlatformWindowSession` is dropped on
    /// the next iteration of the run loop via `pruneClosedSessions`.
    public func closeWindow(_ windowID: WindowID) {
        shell?.destroyWindow(windowID)
    }

    /// Open the main window and block until all registered windows close or
    /// `stop()` is called.
    public func run(tree: NodeTree) {
        do {
            _ = try ensureMainSession(tree: tree)
            runLoop()
        } catch {
            Logger.runtime.error("window open failed: \(error)")
        }
    }

    /// Enter the run loop after windows were created through `openWindow`.
    public func run() {
        guard !sessions.isEmpty else {
            Logger.runtime.error("run() called without any registered windows")
            return
        }
        runLoop()
    }

    public func stop() {
        _isRunning = false
    }

    private func runLoop() {
        guard let shell else { return }

        _isRunning = true
        Logger.runtime.info("running — \(title)")
        var lastFrameTime = Date()

        while _isRunning && shell.isRunning && !sessions.isEmpty {
            let now = Date()
            let deltaTime = now.timeIntervalSince(lastFrameTime)
            lastFrameTime = now

            var handledEvents = false
            for routed in shell.pollWindowEvents() {
                guard let session = sessions[routed.windowID] else { continue }
                handledEvents = true
                session.withCurrent {
                    session.dispatcher.dispatch(routed.event)
                    session.onEvent?(routed.event)
                    if routed.windowID == mainWindowID {
                        onEvent?(routed.event)
                    }
                }
            }

            var committedAny = false
            for id in sessionOrder {
                guard let session = sessions[id] else { continue }
                let didCommit = session.withCurrent {
                    session.recomposer.commitAll()
                }
                if didCommit {
                    session.needsDisplay = true
                    committedAny = true
                }
            }

            let hadAnimations = AnimatorScheduler.current.hasActiveAnimations
            AnimatorScheduler.current.tick(deltaTime: deltaTime)
            let animationsActive = hadAnimations || AnimatorScheduler.current.hasActiveAnimations

            var renderedAnyFrame = false

            for id in sessionOrder {
                guard let session = sessions[id],
                      let handle = shell.window(for: id)
                else { continue }

                if session.updateMetrics(from: handle) {
                    session.needsDisplay = true
                    session.onResize?(session.drawableSize.width, session.drawableSize.height)
                    if id == mainWindowID {
                        drawableSize = session.drawableSize
                        logicalSize = session.logicalSize
                        onResize?(session.drawableSize.width, session.drawableSize.height)
                    }
                }

                if !session.didCallOnInit, let surface = handle.renderSurface {
                    session.didCallOnInit = true
                    session.needsDisplay = true
                    session.onInit?(surface, session.drawableSize.width, session.drawableSize.height)
                    if id == mainWindowID {
                        onInit?(surface, session.drawableSize.width, session.drawableSize.height)
                    }
                }

                let shouldRender = session.needsDisplay
                    || animationsActive
                    || (session.tree.root?.isDirty ?? false)

                if shouldRender, let surface = handle.renderSurface {
                    session.onFrame?(surface)
                    if id == mainWindowID {
                        onFrame?(surface)
                    }
                    session.withCurrent {
                        session.tree.flush()
                    }
                    session.needsDisplay = false
                    renderedAnyFrame = true
                }

                syncTextInputArea(for: session, shell: shell)
            }

            pruneClosedSessions(using: shell)

            if !handledEvents && !committedAny && !animationsActive && !renderedAnyFrame {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        _isRunning = false
        shell.shutdown()
        self.shell = nil
        sessions.removeAll()
        sessionOrder.removeAll()
        mainWindowID = nil
        drawableSize = (1, 1)
        logicalSize = (1, 1)
        Logger.runtime.info("stopped")
    }

    private func resolveShell() throws -> any Shell {
        if let shell {
            return shell
        }
        let created = try shellFactory()
        shell = created
        return created
    }

    private func ensureMainSession(tree: NodeTree) throws -> PlatformWindowSession {
        if let mainWindowID, let session = sessions[mainWindowID] {
            return session
        }

        let shell = try resolveShell()
        try shell.initializeWindow(title: title)
        guard let mainWindowID = shell.mainWindowID,
              let handle = shell.window(for: mainWindowID) else {
            throw ShellError.initializationFailed("main window was not registered after initializeWindow")
        }

        let session = makeSession(handle: handle,
                                  tree: tree,
                                  recomposer: mainRecomposer,
                                  inputContext: mainInputContext,
                                  isMain: true)
        return session
    }

    private func makeSession(handle: any WindowHandle,
                             tree: NodeTree,
                             recomposer: Recomposer,
                             inputContext: PlatformInputContext,
                             isMain: Bool) -> PlatformWindowSession {
        let session = PlatformWindowSession(
            id: handle.id,
            tree: tree,
            recomposer: recomposer,
            inputContext: inputContext,
            drawableSize: handle.drawableSize,
            logicalSize: handle.logicalSize
        )
        session.dispatcher.cursorSink = { [weak self] cursor in
            self?.shell?.setCursor(windowID: handle.id, cursor)
        }

        sessions[handle.id] = session
        sessionOrder.removeAll { $0 == handle.id }
        sessionOrder.append(handle.id)

        if isMain {
            mainWindowID = handle.id
            drawableSize = handle.drawableSize
            logicalSize = handle.logicalSize
        }

        return session
    }

    private func pruneClosedSessions(using shell: any Shell) {
        let liveIDs = Set(shell.windowIDs)
        let staleIDs = sessions.keys.filter { !liveIDs.contains($0) }
        for id in staleIDs {
            sessions.removeValue(forKey: id)
            sessionOrder.removeAll { $0 == id }
            if mainWindowID == id {
                mainWindowID = sessionOrder.first
                if let replacement = mainWindowID.flatMap({ sessions[$0] }) {
                    drawableSize = replacement.drawableSize
                    logicalSize = replacement.logicalSize
                } else {
                    drawableSize = (1, 1)
                    logicalSize = (1, 1)
                }
            }
        }
    }

    private func syncTextInputArea(for session: PlatformWindowSession,
                                   shell: any Shell) {
        let area = session.focusChain.focused?.attachments[TextInputAttachmentKey.area] as? TextInputArea
        guard area != session.lastTextInputArea else { return }

        shell.setTextInputArea(windowID: session.id, area)
        session.lastTextInputArea = area
    }
}