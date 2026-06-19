import EngineKernel
import Foundation
import Logging
import PlatformShell
#if canImport(WinSDK)
import WinSDK
#endif

@MainActor
public final class PlatformWindowSession {
    public let id: WindowID
    public let tree: NodeTree
    public let recomposer: Recomposer
    public let inputContext: PlatformInputContext

    fileprivate let dispatcher: EventDispatcher
    fileprivate var didCallOnInit = false
    fileprivate var lastTextInputArea: TextInputArea?
    fileprivate var lastTextCursorAnimationTick: Double = 0
    fileprivate var needsDisplay = true

    public private(set) var drawableSize: (width: UInt32, height: UInt32)
    public private(set) var logicalSize: (width: UInt32, height: UInt32)
    public private(set) var contentScaleFactor: Float

    public var interactions: InteractionRegistry { inputContext.interactions }
    public var pointerCapture: PointerCapture { inputContext.pointerCapture }
    public var focusChain: FocusChain { inputContext.focusChain }

    public var onFrame: (@MainActor (NativeRenderSurface) -> Bool)?
    public var onInit: (@MainActor (NativeRenderSurface, _ widthPx: UInt32, _ heightPx: UInt32) -> Void)?
    public var onResize: (@MainActor (UInt32, UInt32) -> Void)?
    public var onEvent: (@MainActor (InputEvent) -> Void)?

    fileprivate init(id: WindowID,
                     tree: NodeTree,
                     recomposer: Recomposer,
                     inputContext: PlatformInputContext,
                     drawableSize: (width: UInt32, height: UInt32),
                     logicalSize: (width: UInt32, height: UInt32),
                     contentScaleFactor: Float) {
        self.id = id
        self.tree = tree
        self.recomposer = recomposer
        self.inputContext = inputContext
        self.drawableSize = drawableSize
        self.logicalSize = logicalSize
        self.contentScaleFactor = contentScaleFactor
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

    public func requestDisplay() {
        needsDisplay = true
    }

    /// Inject a synthesized `InputEvent` into this session as if it had been
    /// polled from the native shell. Used by `GuavaUIDevTools` to forward
    /// pointer / keyboard events from the mirror viewport.
    public func injectEvent(_ event: InputEvent) {
        withCurrent {
            dispatcher.dispatch(event)
            onEvent?(event)
        }
        needsDisplay = true
    }

    fileprivate func updateMetrics(from handle: any WindowHandle) -> Bool {
        let nextDrawable = handle.drawableSize
        let nextLogical = handle.logicalSize
        let nextScale = handle.contentScaleFactor
        guard nextDrawable != drawableSize || nextLogical != logicalSize || nextScale != contentScaleFactor else {
            return false
        }
        drawableSize = nextDrawable
        logicalSize = nextLogical
        contentScaleFactor = nextScale
        return true
    }
}

public enum PlatformFrameRateMode: Sendable, Equatable {
    case eventDriven
    case displayRefresh
    case fixed(Double)
}

/// `PlatformHost` backed by SDL3 via Engine's `PlatformShell`.
///
/// The host keeps one runtime session per native window: each session owns its
/// own `NodeTree`, `Recomposer`, input registry, focus chain and capture state.
/// The main-window convenience properties remain for existing single-window
/// demos and tests.
@MainActor
public final class SDL3PlatformHost: PlatformHost {
    private static let focusedTextRefreshInterval: Double = 0.25
    private static let frameTimingLogStride: Int = {
        guard let raw = ProcessInfo.processInfo.environment["GUAVAUI_FRAME_TIMING_LOG_STRIDE"],
              let value = Int(raw) else {
            return 0
        }
        return max(0, value)
    }()

    private let title: String
    private let mainWindowOptions: WindowOptions
    private let shellFactory: @MainActor () throws -> any Shell
    private let mainInputContext: PlatformInputContext
    private let mainRecomposer: Recomposer

    private var shell: (any Shell)?
    private var sessions: [WindowID: PlatformWindowSession] = [:]
    private var sessionOrder: [WindowID] = []
    private var mainWindowID: WindowID?
    private var _isRunning: Bool = false

    /// Thread-safe inbox for closures that must run on the main loop thread.
    /// Native callbacks (e.g. SDL's file-dialog thread) cannot rely on Swift
    /// concurrency here — the custom SDL run loop never services the MainActor
    /// executor — so they hand work back through this queue, which `runLoop`
    /// drains every iteration on the main thread.
    private final class MainThreadInbox: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [() -> Void] = []

        func enqueue(_ work: @escaping () -> Void) {
            lock.lock(); pending.append(work); lock.unlock()
        }

        func drain() -> [() -> Void] {
            lock.lock()
            let items = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()
            return items
        }
    }

    private let mainThreadInbox = MainThreadInbox()

    public var recomposer: Recomposer { mainRecomposer }
    public var interactions: InteractionRegistry { mainInputContext.interactions }
    public var pointerCapture: PointerCapture { mainInputContext.pointerCapture }
    public var focusChain: FocusChain { mainInputContext.focusChain }
    public var tooltips: TooltipStore { mainInputContext.tooltips }

    public private(set) var drawableSize: (width: UInt32, height: UInt32) = (1, 1)
    public private(set) var logicalSize: (width: UInt32, height: UInt32) = (1, 1)
    public private(set) var contentScaleFactor: Float = 1

    public var isRunning: Bool { _isRunning }

    public var onFrame: (@MainActor (NativeRenderSurface) -> Bool)?
    public var onInit: (@MainActor (NativeRenderSurface, _ widthPx: UInt32, _ heightPx: UInt32) -> Void)?
    public var onResize: (@MainActor (UInt32, UInt32) -> Void)?
    public var onEvent: (@MainActor (InputEvent) -> Void)?
    public var onBeforeCommit: (@MainActor (_ deltaTime: Double) -> Void)?
    /// Fires before an individual native window is destroyed. Consumers that
    /// own per-window GPU surfaces must release the matching surface here so it
    /// does not outlive the SDL/Wayland window it was created from.
    public var onWindowTeardown: (@MainActor (_ windowID: WindowID) -> Void)?
    /// Fires once when the run loop has exited, *before* the shell tears down its
    /// windows and quits SDL. The symmetric counterpart to `onInit`: consumers
    /// must release any GPU surfaces created from a window handle here, while the
    /// native windowing system (e.g. the Wayland display) is still alive.
    /// Releasing a wgpu/Vulkan surface after `SDL_Quit` has disconnected the
    /// Wayland display dereferences freed Wayland proxies and crashes in
    /// libwayland-client.
    public var onTeardown: (@MainActor () -> Void)?
    public var externalDisplayRequestDrain: (() -> Bool)?

    private var frameRateMode: PlatformFrameRateMode = .eventDriven
    private var frameTimingLogCounter = 0

    public init(title: String = "GuavaUI",
                mainWindowOptions: WindowOptions = WindowOptions(),
                recomposer: Recomposer = Recomposer(),
                inputContext: PlatformInputContext = PlatformInputContext(),
                shellFactory: @escaping @MainActor () throws -> any Shell = { try makeDefaultShell() }) {
        self.title = title
        self.mainWindowOptions = mainWindowOptions
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

    /// Convenience accessor for the main-window session, if one has been
    /// registered. Returns `nil` until `run()` / `run(tree:)` finishes
    /// bootstrapping the first window.
    public var mainSession: PlatformWindowSession? {
        guard let id = mainWindowID else { return nil }
        return sessions[id]
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

    public func minimizeWindow(_ windowID: WindowID) {
        shell?.minimizeWindow(windowID)
    }

    public func maximizeWindow(_ windowID: WindowID) {
        shell?.maximizeWindow(windowID)
    }

    public func restoreWindow(_ windowID: WindowID) {
        shell?.restoreWindow(windowID)
    }

    public func isWindowMaximized(_ windowID: WindowID) -> Bool {
        shell?.isWindowMaximized(windowID) ?? false
    }

    public func showWindowSystemMenu(_ windowID: WindowID, x: Float, y: Float) {
        shell?.showWindowSystemMenu(windowID, x: x, y: y)
    }

    public func setWindowChromeHitTest(_ windowID: WindowID, _ hitTest: WindowChromeHitTest?) {
        shell?.setWindowChromeHitTest(windowID, hitTest)
    }

    public func showOpenFolderDialog(windowID: WindowID?,
                                     defaultPath: String?,
                                     accept: @escaping (String?) -> Void) {
        guard let shell else { accept(nil); return }
        // The platform fires its dialog callback on a background thread (SDL
        // runs the Windows folder dialog on its own thread). Marshal the result
        // back onto the main loop thread so `accept` runs where it is safe to
        // touch UI / load a project.
        let inbox = mainThreadInbox
        shell.showOpenFolderDialog(windowID: windowID, defaultPath: defaultPath) { path in
            inbox.enqueue { accept(path) }
        }
    }

    public func showOpenFileDialog(windowID: WindowID?,
                                   defaultPath: String?,
                                   filters: [FileDialogFilter],
                                   allowsMultiple: Bool,
                                   accept: @escaping ([String]) -> Void) {
        guard let shell else { accept([]); return }
        // SDL runs the native file dialog on its own thread; marshal the result
        // back onto the main loop thread before touching UI / loading assets.
        let inbox = mainThreadInbox
        shell.showOpenFileDialog(windowID: windowID,
                                 defaultPath: defaultPath,
                                 filters: filters,
                                 allowsMultiple: allowsMultiple) { paths in
            inbox.enqueue { accept(paths) }
        }
    }

    /// Destroy a window. The matching `PlatformWindowSession` is dropped on
    /// the next iteration of the run loop via `pruneClosedSessions`.
    public func closeWindow(_ windowID: WindowID) {
        onWindowTeardown?(windowID)
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

    /// Consulted before an OS-initiated window close or app quit (`nil` =
    /// quit). Return `false` to veto; programmatic `closeWindow`/`stop` are
    /// never intercepted.
    public var windowCloseInterceptor: ((WindowID?) -> Bool)?

    public func stop() {
        _isRunning = false
    }

    public func requestDisplay(windowID: WindowID? = nil) {
        let resolvedWindowID = windowID ?? mainWindowID
        guard let resolvedWindowID,
              let session = sessions[resolvedWindowID] else { return }
        session.requestDisplay()
    }

    public func enqueueMainThreadWork(_ work: @escaping () -> Void) {
        mainThreadInbox.enqueue(work)
    }

    public func setTargetFrameRate(_ framesPerSecond: Double?) {
        guard let framesPerSecond, framesPerSecond.isFinite, framesPerSecond > 0 else {
            frameRateMode = .eventDriven
            return
        }
        frameRateMode = .fixed(Self.sanitizedFrameRate(framesPerSecond))
    }

    public func setFrameRateMode(_ mode: PlatformFrameRateMode) {
        switch mode {
        case .eventDriven, .displayRefresh:
            frameRateMode = mode
        case let .fixed(framesPerSecond):
            frameRateMode = .fixed(Self.sanitizedFrameRate(framesPerSecond))
        }
    }

    public func currentDisplayRefreshRate(windowID: WindowID? = nil) -> Double? {
        guard let shell else { return nil }
        let resolvedWindowID = windowID ?? mainWindowID
        return Self.sanitizedOptionalFrameRate(shell.displayRefreshRate(windowID: resolvedWindowID))
    }

    private func runLoop() {
        guard let shell else { return }

        #if os(Windows)
        // Default Windows timer granularity is ~15.6ms, so the Thread.sleep
        // frame pacing below rounds every sleep up to ~15.6ms and caps the loop
        // at 64fps (1000/15.625) regardless of vsync/backend. Raise the
        // multimedia timer resolution to 1ms for the loop's lifetime. macOS and
        // Linux already have high-resolution sleep.
        timeBeginPeriod(1)
        defer { timeEndPeriod(1) }
        #endif

        _isRunning = true
        Logger.runtime.info("running — \(title)")
        var lastLoopTime = TimingTrace.now()
        var lastFramePreparationTime: Double?

        while _isRunning && shell.isRunning && !sessions.isEmpty {
            let frameStart = TimingTrace.now()
            let loopDeltaTime = frameStart - lastLoopTime
            lastLoopTime = frameStart
            var framePreparationDelta = loopDeltaTime
            var timing = TimingTrace(label: "[timing] host.frame")

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
                // Focus, caret position, and IME anchor geometry are updated
                // during draw, so input delivery must always request a frame.
                session.needsDisplay = true
            }
            let externalDisplayRequested = externalDisplayRequestDrain?() == true
            if externalDisplayRequested {
                for session in sessions.values {
                    session.needsDisplay = true
                }
            }

            // Run work handed back from native callbacks (e.g. file dialogs) on
            // the main thread, then force a frame so any resulting UI change
            // (such as a freshly loaded project) is shown promptly.
            let pendingMainThreadWork = mainThreadInbox.drain()
            if !pendingMainThreadWork.isEmpty {
                for work in pendingMainThreadWork { work() }
                for session in sessions.values {
                    session.needsDisplay = true
                }
            }
            timing.mark("events")

            let hasDisplayWork = sessions.values.contains { session in
                session.needsDisplay || session.tree.hasRenderUpdates || session.recomposer.hasPending
            }
            let targetFrameInterval = currentFrameInterval(shell: shell)
            let frameDue: Bool = {
                guard let targetFrameInterval else { return hasDisplayWork }
                guard let lastFramePreparationTime else { return true }
                return frameStart - lastFramePreparationTime >= targetFrameInterval
            }()
            let isCadenceDriven = targetFrameInterval != nil
            let shouldRunFramePreparation = frameDue
            if isCadenceDriven,
               frameDue,
               let mainWindowID,
               let session = sessions[mainWindowID] {
                session.needsDisplay = true
            }
            if shouldRunFramePreparation {
                if let lastFramePreparationTime {
                    framePreparationDelta = frameStart - lastFramePreparationTime
                } else if let targetFrameInterval {
                    framePreparationDelta = targetFrameInterval
                }
                lastFramePreparationTime = frameStart
                onBeforeCommit?(framePreparationDelta)
            }
            timing.mark("prepare")

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
            timing.mark("commit")

            AnimatorScheduler.current.tick(deltaTime: loopDeltaTime)
            let animationsActive = AnimatorScheduler.current.hasActiveAnimations
            timing.mark("animations")

            var renderedAnyFrame = false
            var renderSummaries: [String] = []

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

                let hasRenderInvalidation = session.tree.hasRenderUpdates
                let shouldRender = (session.needsDisplay || hasRenderInvalidation)
                    && (!isCadenceDriven || frameDue)

                if shouldRender, let surface = handle.renderSurface {
                    var reasons: [String] = []
                    if session.needsDisplay { reasons.append("needsDisplay") }
                    if hasRenderInvalidation { reasons.append("renderDirty") }

                    session.needsDisplay = false
                    let renderStart = TimingTrace.now()
                    let hasFrameHandler = session.onFrame != nil
                        || (id == mainWindowID && onFrame != nil)
                    var didRender = !hasFrameHandler
                    if let callback = session.onFrame {
                        didRender = callback(surface) || didRender
                    }
                    if id == mainWindowID, let callback = onFrame {
                        didRender = callback(surface) || didRender
                    }
                    if didRender {
                        session.withCurrent {
                            session.tree.flush()
                        }
                    } else {
                        session.needsDisplay = true
                    }
                    let renderMilliseconds = (TimingTrace.now() - renderStart) * 1000
                    if didRender {
                        let reasonText = reasons.isEmpty ? "unknown" : reasons.joined(separator: "+")
                        let renderText = String(format: "%.2fms", renderMilliseconds)
                        renderSummaries.append(
                            "window=\(id) reason=\(reasonText) render=\(renderText)"
                        )
                        renderedAnyFrame = true
                    }
                }

                syncTextInputArea(for: session, shell: shell)
                scheduleFocusedTextRefresh(for: session)
            }
            timing.mark("windows")

            if renderedAnyFrame {
                let deltaText = String(format: "%.2fms", framePreparationDelta * 1000)
                let extra = [
                    "delta=\(deltaText)",
                    "animationsActive=\(animationsActive)",
                ] + renderSummaries
                frameTimingLogCounter &+= 1
                if Self.frameTimingLogStride > 0,
                   frameTimingLogCounter % Self.frameTimingLogStride == 0 {
                    Logger.runtime.debug("\(timing.summary(extra: extra))")
                }
            }

            pruneClosedSessions(using: shell)

            if let targetFrameInterval, let lastFramePreparationTime {
                // Only an explicit `.fixed(N)` cap reaches here; `.displayRefresh`
                // returns nil and lets the swapchain present (FIFO/vsync) pace
                // the loop instead. Sleep almost the whole remaining interval —
                // timeBeginPeriod(1) above keeps this accurate on Windows — and
                // let the next iteration spin out the final sub-millisecond.
                let remaining = (lastFramePreparationTime + targetFrameInterval) - TimingTrace.now()
                if remaining > 0.001 {
                    Thread.sleep(forTimeInterval: remaining - 0.0003)
                }
            } else if !handledEvents && !committedAny && !renderedAnyFrame {
                // Nothing to draw (idle / occluded window) — yield briefly.
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        _isRunning = false
        // Release consumer GPU surfaces (which hold Wayland display/surface
        // references) before the shell destroys windows and quits SDL — otherwise
        // the surfaces outlive the Wayland display and crash on release.
        onTeardown?()
        shell.shutdown()
        self.shell = nil
        sessions.removeAll()
        sessionOrder.removeAll()
        mainWindowID = nil
        drawableSize = (1, 1)
        logicalSize = (1, 1)
        Logger.runtime.info("stopped")
    }

    private func currentFrameInterval(shell: any Shell) -> Double? {
        switch frameRateMode {
        case .eventDriven, .displayRefresh:
            // VSync is provided by the surface's FIFO present, which blocks at
            // vblank and paces the loop to the refresh rate. A separate sleep
            // pacer here would stack on top and halve the rate, so we pace only
            // for an explicit fixed cap.
            return nil
        case let .fixed(framesPerSecond):
            return 1.0 / Self.sanitizedFrameRate(framesPerSecond)
        }
    }

    private static func sanitizedOptionalFrameRate(_ framesPerSecond: Double?) -> Double? {
        guard let framesPerSecond, framesPerSecond.isFinite, framesPerSecond > 0 else {
            return nil
        }
        return sanitizedFrameRate(framesPerSecond)
    }

    private static func sanitizedFrameRate(_ framesPerSecond: Double) -> Double {
        max(1.0, min(240.0, framesPerSecond))
    }

    private func resolveShell() throws -> any Shell {
        if let shell {
            return shell
        }
        let created = try shellFactory()
        created.closeInterceptor = { [weak self] windowID in
            guard let self else { return true }
            guard self.windowCloseInterceptor?(windowID) ?? true else {
                return false
            }
            if let windowID {
                self.closeWindow(windowID)
            } else {
                self.stop()
            }
            return false
        }
        shell = created
        return created
    }

    private func ensureMainSession(tree: NodeTree) throws -> PlatformWindowSession {
        if let mainWindowID, let session = sessions[mainWindowID] {
            return session
        }

        let shell = try resolveShell()
        if shell.mainWindowID == nil {
            _ = try shell.createWindow(title: title, options: mainWindowOptions)
        }
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
            logicalSize: handle.logicalSize,
            contentScaleFactor: handle.contentScaleFactor
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
            contentScaleFactor = handle.contentScaleFactor
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
                    contentScaleFactor = replacement.contentScaleFactor
                } else {
                    drawableSize = (1, 1)
                    logicalSize = (1, 1)
                    contentScaleFactor = 1
                }
            }
        }
    }

    private func focusedTextInputArea(for session: PlatformWindowSession) -> TextInputArea? {
        session.focusChain.focused?
            .attachments[TextInputAttachmentKey.area] as? TextInputArea
    }

    private func syncTextInputArea(for session: PlatformWindowSession,
                                   shell: any Shell) {
        let area = focusedTextInputArea(for: session)
        guard area != session.lastTextInputArea else { return }

        shell.setTextInputArea(windowID: session.id, area)
        session.lastTextInputArea = area
    }

    private func scheduleFocusedTextRefresh(for session: PlatformWindowSession) {
        guard focusedTextInputArea(for: session) != nil else {
            session.lastTextCursorAnimationTick = 0
            return
        }

        let now = TimingTrace.now()
        if session.lastTextCursorAnimationTick == 0 {
            session.lastTextCursorAnimationTick = now
            return
        }
        guard now - session.lastTextCursorAnimationTick >= Self.focusedTextRefreshInterval else {
            return
        }

        session.lastTextCursorAnimationTick = now
        session.needsDisplay = true
        // The caret blink phase is computed inside the field's draw closure;
        // invalidate its cached layer or the composite replays the old slice.
        session.focusChain.focused?.markRenderDirty(reason: .styleSet(field: "textFieldCaretBlink"))
    }

}
