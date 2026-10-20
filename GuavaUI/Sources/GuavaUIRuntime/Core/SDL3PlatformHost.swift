import EngineKernel
import Foundation
import GuavaLogging
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
    /// While an injected press is held, the real cursor is not the pointer:
    /// its motion would drag the injected gesture to wherever the mouse rests.
    /// A real button press or release takes the pointer back.
    private var injectedPressHeld = false

    fileprivate func acceptsNative(_ event: InputEvent) -> Bool {
        switch event {
        case .mouseMotion, .mouseWheel: return !injectedPressHeld
        case .mouseButtonDown, .mouseButtonUp: injectedPressHeld = false; return true
        default: return true
        }
    }
    fileprivate var nextRenderAttemptTime: Double = 0

    public private(set) var drawableSize: (width: UInt32, height: UInt32)
    public private(set) var logicalSize: (width: UInt32, height: UInt32)
    public private(set) var contentScaleFactor: Float

    public var interactions: InteractionRegistry { inputContext.interactions }
    public var pointerCapture: PointerCapture { inputContext.pointerCapture }
    public var focusChain: FocusChain { inputContext.focusChain }

    /// Scene-thread observation of both native and injected input.
    public var inputObserver: ((InputEvent) -> Void)? {
        get { dispatcher.eventSink }
        set { dispatcher.eventSink = newValue }
    }
    public var inputInterceptor: ((InputEvent) -> Bool)? {
        get { dispatcher.eventInterceptor }
        set { dispatcher.eventInterceptor = newValue }
    }

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
        switch event {
        case .mouseButtonDown: injectedPressHeld = true
        case .mouseButtonUp: injectedPressHeld = false
        default: break
        }
        withCurrent {
            if dispatcher.dispatch(event) { onEvent?(event) }
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
    /// Native input redraws immediately; animations follow native display ticks.
    case eventDriven
    /// Follow per-window native display callbacks. A shell without native
    /// support reports a warning and uses an absolute fixed-rate fallback.
    case displayRefresh
    /// An explicit software deadline cadence, independent of presentation sync.
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
    private static let fallbackDisplayRefreshRate: Double = 60.0
    private static let minimumUsableDisplayRefreshRate: Double = 30.0
    private static let maxEventWaitInterval: Double = 0.25
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

    private final class EventLoopWakeRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (() -> Void)?

        func install(_ handler: (() -> Void)?) {
            lock.withLock {
                self.handler = handler
            }
        }

        func signal() {
            let handler = lock.withLock { self.handler }
            handler?()
        }
    }

    private let mainThreadInbox = MainThreadInbox()
    private let eventLoopWakeRelay = EventLoopWakeRelay()

    public var recomposer: Recomposer { mainRecomposer }
    public var interactions: InteractionRegistry { mainInputContext.interactions }
    public var pointerCapture: PointerCapture { mainInputContext.pointerCapture }
    public var focusChain: FocusChain { mainInputContext.focusChain }
    public var invalidationLog: InvalidationLog { mainInputContext.invalidationLog }

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
    /// Releasing a native graphics surface after `SDL_Quit` has disconnected the
    /// Wayland display dereferences freed Wayland proxies and crashes in
    /// libwayland-client.
    public var onTeardown: (@MainActor () -> Void)?
    public var externalDisplayRequestDrain: (() -> Bool)?

    private let frameDrive = HostFrameDrive()
    private var frameTimingLogCounter = 0
    // Tests can advance frame time independently of OS scheduling latency.
    var frameClock: () -> Double = TimingTrace.now

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

    public func nativeWindowReference(for windowID: WindowID) -> NativeWindowReference? {
        shell?.window(for: windowID)?.nativeWindowReference
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

    /// Resize `windowID`'s content area, in logical points.
    public func setWindowSize(_ windowID: WindowID, width: Float, height: Float) {
        shell?.setWindowSize(windowID, width: width, height: height)
    }

    /// The main window, when one is open.
    public var mainWindow: WindowID? { mainWindowID }

    public func minimizeWindow(_ windowID: WindowID) {
        shell?.minimizeWindow(windowID)
    }

    public func maximizeWindow(_ windowID: WindowID) {
        shell?.maximizeWindow(windowID)
    }

    public func restoreWindow(_ windowID: WindowID) {
        shell?.restoreWindow(windowID)
    }

    public func hideWindow(_ windowID: WindowID) {
        shell?.hideWindow(windowID)
    }

    public func showWindow(_ windowID: WindowID) {
        shell?.showWindow(windowID)
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

    public nonisolated func enqueueMainThreadWork(_ work: @escaping () -> Void) {
        mainThreadInbox.enqueue(work)
        eventLoopWakeRelay.signal()
    }

    public nonisolated func wakeEventLoop() {
        eventLoopWakeRelay.signal()
    }

    public func setTargetFrameRate(_ framesPerSecond: Double?) {
        guard let framesPerSecond, framesPerSecond.isFinite, framesPerSecond > 0 else {
            frameDrive.mode = .eventDriven
            return
        }
        frameDrive.mode = .fixed(Self.sanitizedFrameRate(framesPerSecond))
    }

    public func setFrameRateMode(_ mode: PlatformFrameRateMode) {
        switch mode {
        case .eventDriven, .displayRefresh:
            frameDrive.mode = mode
        case let .fixed(framesPerSecond):
            frameDrive.mode = .fixed(Self.sanitizedFrameRate(framesPerSecond))
        }
    }

    public var safeArea: WindowSafeArea {
        guard let id = mainWindowID else { return WindowSafeArea() }
        return shell?.window(for: id)?.safeArea ?? WindowSafeArea()
    }

    public func currentDisplayRefreshRate(windowID: WindowID? = nil) -> Double? {
        guard let shell else { return nil }
        let resolvedWindowID = windowID ?? mainWindowID
        return Self.sanitizedOptionalFrameRate(shell.displayRefreshRate(windowID: resolvedWindowID))
    }

    private func runLoop() {
        guard let shell else { return }

        #if os(Windows)
        // SDL's timed event wait is also subject to Windows timer granularity.
        // Raise resolution for explicitly fixed-rate / fallback deadlines.
        timeBeginPeriod(1)
        defer { timeEndPeriod(1) }
        #endif

        _isRunning = true
        Logger.runtime.info("running — \(title)")
        frameDrive.clock = HostFrameClock(now: frameClock())
        #if os(iOS)
        let driver = IOSFrameDriver { [weak self] in
            guard let self else { return false }
            guard self._isRunning, shell.isRunning, !self.sessions.isEmpty else {
                self.finishRunLoop()
                return false
            }
            self.runFrame(wait: false)
            return true
        }
        frameDrive.driver = driver
        driver.start()
        #else
        while _isRunning && shell.isRunning && !sessions.isEmpty { runFrame(wait: true) }
        finishRunLoop()
        #endif
    }

    private func runFrame(wait: Bool) {
        guard let shell else { return }
        let state = frameDrive.clock
        let frameStart = frameClock()
        let loopDeltaTime = frameStart - state.lastLoopTime
        state.lastLoopTime = frameStart
        var framePreparationDelta = loopDeltaTime
        var timing = TimingTrace(label: "[timing] host.frame")

        for routed in shell.pollWindowEvents() {
            guard let session = sessions[routed.windowID] else { continue }
            guard session.acceptsNative(routed.event) else { continue }
            session.withCurrent {
                if session.dispatcher.dispatch(routed.event) {
                    session.onEvent?(routed.event)
                    if routed.windowID == mainWindowID { onEvent?(routed.event) }
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
        let animationsWereActive = AnimatorScheduler.current.hasActiveAnimations
        if !state.animationsPreviouslyActive || !animationsWereActive {
            state.lastAnimationTickTime = frameStart
        }
        let wantsNativeRefresh = frameDrive.mode == .displayRefresh
            || (frameDrive.mode == .eventDriven && animationsWereActive)
        var nativeWindows = Set<WindowID>()
        var refreshTicks: [WindowID: DisplayRefreshTick] = [:]
        for id in sessionOrder {
            if shell.setDisplayRefreshEnabled(wantsNativeRefresh, windowID: id), wantsNativeRefresh {
                nativeWindows.insert(id)
                if let tick = shell.takeDisplayRefresh(windowID: id) { refreshTicks[id] = tick }
            }
        }
        let needsRefreshFallback = wantsNativeRefresh && nativeWindows.count < sessions.count
        if needsRefreshFallback, !state.reportedFallback {
            Logger.runtime.warning("native display refresh unavailable; using fixed-rate deadline fallback")
            state.reportedFallback = true
        }
        let fallbackInterval: Double? = {
            if case let .fixed(fps) = frameDrive.mode { return 1.0 / fps }
            guard needsRefreshFallback else { return nil }
            return 1.0 / Self.sanitizedDisplayRefreshRate(shell.displayRefreshRate(windowID: mainWindowID))
        }()
        state.fallbackDeadline.update(interval: fallbackInterval, now: frameStart)
        let fallbackDue = state.fallbackDeadline.consumeIfDue(now: frameStart)
        let hasRefreshTick = !refreshTicks.isEmpty
        // Animate the frame for its predicted display time. CADisplayLink's
        // timestamp describes the previous display, while targetTimestamp
        // tracks the upcoming interval, including variable refresh rates.
        let animationTickTime = refreshTicks.values.map(\.targetTimestamp).max() ?? frameStart
        let isCadenceDriven = frameDrive.mode != .eventDriven
        let frameDue = hasRefreshTick || fallbackDue
        let shouldRunFramePreparation = frameDue || (!isCadenceDriven && hasDisplayWork)
        if isCadenceDriven {
            for id in sessionOrder where refreshTicks[id] != nil || (!nativeWindows.contains(id) && fallbackDue) {
                sessions[id]?.needsDisplay = true
            }
        }
        if shouldRunFramePreparation {
            let preparationTime = isCadenceDriven ? animationTickTime : frameStart
            if !isCadenceDriven {
                framePreparationDelta = loopDeltaTime
            } else if let previousPreparation = state.lastFramePreparationTime {
                framePreparationDelta = max(0, preparationTime - previousPreparation)
            } else {
                framePreparationDelta = fallbackInterval
                    ?? refreshTicks.values.first.map { max(0, $0.targetTimestamp - $0.timestamp) }
                    ?? 0
            }
            // Different displays can predict targets in a different order
            // from callback delivery. Keep the shared update clock monotonic.
            state.lastFramePreparationTime = max(state.lastFramePreparationTime ?? preparationTime, preparationTime)
            onBeforeCommit?(framePreparationDelta)
        }
        timing.mark("prepare")

        for id in sessionOrder where shouldRunFramePreparation {
            guard let session = sessions[id] else { continue }
            let didCommit = session.withCurrent {
                session.recomposer.commitAll()
            }
            WindowRevealContext.clearActivation(in: session.tree.root)
            if didCommit {
                session.needsDisplay = true
            }
        }
        timing.mark("commit")

        // Input can wake SDL and redraw immediately, without advancing the
        // animation between native refresh callbacks. Missed callbacks are
        // coalesced, so a blocked present never causes catch-up frames.
        if frameDue || (shouldRunFramePreparation && !animationsWereActive) {
            AnimatorScheduler.current.tick(deltaTime: max(0, animationTickTime - state.lastAnimationTickTime))
            state.lastAnimationTickTime = max(state.lastAnimationTickTime, animationTickTime)
        }
        let animationsActive = AnimatorScheduler.current.hasActiveAnimations
        state.animationsPreviouslyActive = animationsActive
        timing.mark("animations")

        var renderedAnyFrame = false
        var renderSummaries: [String] = []

        for id in sessionOrder {
            guard let session = sessions[id],
                  let handle = shell.window(for: id)
            else { continue }

            if session.updateMetrics(from: handle) {
                session.needsDisplay = true
                session.nextRenderAttemptTime = 0
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
            if nativeWindows.contains(id), refreshTicks[id] != nil {
                session.nextRenderAttemptTime = 0
            }
            let shouldRender = (session.needsDisplay || hasRenderInvalidation)
                && frameStart >= session.nextRenderAttemptTime
                && (!isCadenceDriven || refreshTicks[id] != nil || (!nativeWindows.contains(id) && fallbackDue))
                && (isCadenceDriven || !nativeWindows.contains(id) || refreshTicks[id] != nil || session.needsDisplay)

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
                    session.nextRenderAttemptTime = 0
                    session.withCurrent {
                        session.tree.flush()
                    }
                } else {
                    session.needsDisplay = true
                    // An occluded/unavailable swapchain must remain pending,
                    // without redrawing the entire scene every 1 ms. Retry at
                    // display cadence; native events can still wake SDL.
                    if nativeWindows.contains(id) {
                        // The next native callback is itself the retry
                        // deadline; do not add another software period.
                        session.nextRenderAttemptTime = .infinity
                    } else {
                        session.nextRenderAttemptTime = frameClock() + 1.0 / Self.sanitizedDisplayRefreshRate(
                            shell.displayRefreshRate(windowID: id)
                        )
                    }
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

        if wait && _isRunning {
            if frameDrive.mode == .eventDriven && !animationsActive {
                state.fallbackDeadline.update(interval: nil, now: frameStart)
                for id in nativeWindows { shell.setDisplayRefreshEnabled(false, windowID: id) }
            }
            let now = frameClock()
            // A commit or layout can create the first animation after this
            // frame chose its refresh policy. Enter the next iteration now so
            // it can arm display refresh (or a fallback deadline), rather than
            // spending the entire entrance in the 250ms idle event wait.
            let startsAnimation = frameDrive.mode == .eventDriven
                && !animationsWereActive && AnimatorScheduler.current.hasActiveAnimations
            let hasImmediateWork = startsAnimation || sessions.values.contains { session in
                !isCadenceDriven && (session.recomposer.hasPending ||
                    ((session.needsDisplay || (session.tree.hasRenderUpdates && !nativeWindows.contains(session.id)))
                        && now >= session.nextRenderAttemptTime)
                )
            }
            var timeout = hasImmediateWork
                ? 0
                : eventWaitTimeout(now: now)
            if let remaining = state.fallbackDeadline.remaining(now: now) { timeout = min(timeout, remaining) }
            for session in sessions.values where !isCadenceDriven && !nativeWindows.contains(session.id)
                && (session.needsDisplay || session.tree.hasRenderUpdates) {
                timeout = min(timeout, max(0.001, session.nextRenderAttemptTime - now))
            }
            // Display callbacks, input and cross-thread work all wake the
            // same native wait. No sleep/spin follows a vsync-blocked frame:
            // a queued callback wakes immediately, and fallback waits only
            // for the remainder of its absolute deadline.
            _ = shell.waitForEvents(timeout: timeout)
        }
    }

    private func finishRunLoop() {
        guard let shell else { return }
        #if os(iOS)
        frameDrive.driver?.stop()
        frameDrive.driver = nil
        #endif
        _isRunning = false
        // Release consumer GPU surfaces (which hold Wayland display/surface
        // references) before the shell destroys windows and quits SDL — otherwise
        // the surfaces outlive the Wayland display and crash on release.
        onTeardown?()
        shell.shutdown()
        eventLoopWakeRelay.install(nil)
        self.shell = nil
        sessions.removeAll()
        sessionOrder.removeAll()
        mainWindowID = nil
        drawableSize = (1, 1)
        logicalSize = (1, 1)
        Logger.runtime.info("stopped")
    }

    private func eventWaitTimeout(now: Double) -> Double {
        var timeout = Self.maxEventWaitInterval

        for session in sessions.values where focusedTextInputArea(for: session) != nil {
            guard session.lastTextCursorAnimationTick > 0 else {
                timeout = min(timeout, Self.focusedTextRefreshInterval)
                continue
            }
            let remaining = Self.focusedTextRefreshInterval
                - (now - session.lastTextCursorAnimationTick)
            timeout = min(timeout, max(0.001, remaining))
        }

        return timeout
    }

    private static func sanitizedDisplayRefreshRate(_ framesPerSecond: Double?) -> Double {
        guard let framesPerSecond = sanitizedOptionalFrameRate(framesPerSecond),
              framesPerSecond >= minimumUsableDisplayRefreshRate else {
            return fallbackDisplayRefreshRate
        }
        return framesPerSecond
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
        eventLoopWakeRelay.install { created.wakeEventLoop() }
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

        let now = frameClock()
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
