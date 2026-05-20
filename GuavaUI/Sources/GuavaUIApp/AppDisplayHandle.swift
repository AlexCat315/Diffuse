import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import PlatformShell
import Foundation

struct AppAuxiliaryWindowRequest {
    let title: String
    let width: Int32
    let height: Int32
    let rootView: AnyView
}

public final class AppDisplayHandle: @unchecked Sendable {
    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false

        func request() {
            lock.withLock {
                pending = true
            }
        }

        func drain() -> Bool {
            lock.withLock {
                let wasPending = pending
                pending = false
                return wasPending
            }
        }
    }

    private let signal = Signal()
    private var openAuxiliaryWindow: (@MainActor (AppAuxiliaryWindowRequest) -> WindowID?)?
    private var closeAuxiliaryWindow: (@MainActor (WindowID) -> Void)?
    private var auxiliaryWindowIsOpen: (@MainActor (WindowID) -> Bool)?
    private var setRuntimeTargetFrameRate: (@MainActor (Double?) -> Void)?
    private var setRuntimeFrameRateMode: (@MainActor (PlatformFrameRateMode) -> Void)?
    private var setRuntimeVSyncEnabled: (@MainActor (Bool) -> Void)?
    private var currentRuntimeDisplayRefreshRate: (@MainActor () -> Double?)?
    private var installRuntimeNativeMenuBar: (@MainActor (NativeMenuBar) -> Void)?
    private var minimizeMainWindowAction: (@MainActor () -> Void)?
    private var maximizeMainWindowAction: (@MainActor () -> Void)?
    private var restoreMainWindowAction: (@MainActor () -> Void)?
    private var closeMainWindowAction: (@MainActor () -> Void)?
    private var mainWindowMaximizedQuery: (@MainActor () -> Bool)?
    private var setMainWindowChromeHitTestAction: (@MainActor (WindowChromeHitTest?) -> Void)?
    private var minimizeWindowByIDAction: (@MainActor (WindowID) -> Void)?
    private var maximizeWindowByIDAction: (@MainActor (WindowID) -> Void)?
    private var restoreWindowByIDAction: (@MainActor (WindowID) -> Void)?
    private var closeWindowByIDAction: (@MainActor (WindowID) -> Void)?
    private var windowMaximizedByIDQuery: (@MainActor (WindowID) -> Bool)?
    private var showWindowSystemMenuAction: (@MainActor (WindowID, Float, Float) -> Void)?

    public init() {}

    public nonisolated func requestDisplay() {
        signal.request()
    }

    @MainActor
    public func setTargetFrameRate(_ framesPerSecond: Double?) {
        setRuntimeTargetFrameRate?(framesPerSecond)
        requestDisplay()
    }

    @MainActor
    public func setFrameRateMode(_ mode: PlatformFrameRateMode) {
        setRuntimeFrameRateMode?(mode)
        requestDisplay()
    }

    @MainActor
    public func setVSyncEnabled(_ enabled: Bool) {
        setRuntimeVSyncEnabled?(enabled)
        requestDisplay()
    }

    @MainActor
    public func currentDisplayRefreshRate() -> Double? {
        currentRuntimeDisplayRefreshRate?()
    }

    @MainActor
    public func installNativeMenuBar(_ menuBar: NativeMenuBar) {
        installRuntimeNativeMenuBar?(menuBar)
    }

    @MainActor
    public func minimizeWindow() {
        minimizeMainWindowAction?()
    }

    @MainActor
    public func minimizeWindow(_ windowID: WindowID) {
        minimizeWindowByIDAction?(windowID)
    }

    @MainActor
    public func maximizeWindow() {
        maximizeMainWindowAction?()
    }

    @MainActor
    public func maximizeWindow(_ windowID: WindowID) {
        maximizeWindowByIDAction?(windowID)
    }

    @MainActor
    public func restoreWindow() {
        restoreMainWindowAction?()
    }

    @MainActor
    public func restoreWindow(_ windowID: WindowID) {
        restoreWindowByIDAction?(windowID)
    }

    @MainActor
    public func toggleMaximizeWindow() {
        isWindowMaximized() ? restoreWindow() : maximizeWindow()
    }

    @MainActor
    public func toggleMaximizeWindow(_ windowID: WindowID) {
        isWindowMaximized(windowID) ? restoreWindow(windowID) : maximizeWindow(windowID)
    }

    @MainActor
    public func closeMainWindow() {
        closeMainWindowAction?()
    }

    @MainActor
    public func isWindowMaximized() -> Bool {
        mainWindowMaximizedQuery?() ?? false
    }

    @MainActor
    public func isWindowMaximized(_ windowID: WindowID) -> Bool {
        windowMaximizedByIDQuery?(windowID) ?? false
    }

    @MainActor
    public func showWindowSystemMenu(_ windowID: WindowID, x: Float = 0, y: Float = 0) {
        showWindowSystemMenuAction?(windowID, x, y)
    }

    @MainActor
    public func setWindowChromeHitTest(_ hitTest: WindowChromeHitTest?) {
        setMainWindowChromeHitTestAction?(hitTest)
    }

    @MainActor
    public func openWindow<Root: View>(title: String,
                                       width: Int32 = 480,
                                       height: Int32 = 360,
                                       @ViewBuilder rootView: () -> Root) -> WindowID? {
        openAuxiliaryWindow?(AppAuxiliaryWindowRequest(title: title,
                                                       width: width,
                                                       height: height,
                                                       rootView: AnyView(rootView())))
    }

    @MainActor
    public func closeWindow(_ windowID: WindowID) {
        if let closeWindowByIDAction {
            closeWindowByIDAction(windowID)
        } else {
            closeAuxiliaryWindow?(windowID)
        }
    }

    @MainActor
    public func isWindowOpen(_ windowID: WindowID) -> Bool {
        auxiliaryWindowIsOpen?(windowID) ?? false
    }

    func drainDisplayRequest() -> Bool {
        signal.drain()
    }

    @MainActor
    func installAuxiliaryWindowControls(open: @escaping @MainActor (AppAuxiliaryWindowRequest) -> WindowID?,
                                        close: @escaping @MainActor (WindowID) -> Void,
                                        isOpen: @escaping @MainActor (WindowID) -> Bool) {
        openAuxiliaryWindow = open
        closeAuxiliaryWindow = close
        auxiliaryWindowIsOpen = isOpen
    }

    @MainActor
    func installRuntimeControls(setTargetFrameRate: @escaping @MainActor (Double?) -> Void,
                                setFrameRateMode: @escaping @MainActor (PlatformFrameRateMode) -> Void,
                                setVSyncEnabled: @escaping @MainActor (Bool) -> Void,
                                currentDisplayRefreshRate: @escaping @MainActor () -> Double?,
                                installNativeMenuBar: @escaping @MainActor (NativeMenuBar) -> Void,
                                minimizeWindow: @escaping @MainActor () -> Void,
                                maximizeWindow: @escaping @MainActor () -> Void,
                                restoreWindow: @escaping @MainActor () -> Void,
                                closeWindow: @escaping @MainActor () -> Void,
                                isWindowMaximized: @escaping @MainActor () -> Bool,
                                minimizeWindowByID: @escaping @MainActor (WindowID) -> Void,
                                maximizeWindowByID: @escaping @MainActor (WindowID) -> Void,
                                restoreWindowByID: @escaping @MainActor (WindowID) -> Void,
                                closeWindowByID: @escaping @MainActor (WindowID) -> Void,
                                isWindowMaximizedByID: @escaping @MainActor (WindowID) -> Bool,
                                showWindowSystemMenu: @escaping @MainActor (WindowID, Float, Float) -> Void,
                                setWindowChromeHitTest: @escaping @MainActor (WindowChromeHitTest?) -> Void) {
        setRuntimeTargetFrameRate = setTargetFrameRate
        setRuntimeFrameRateMode = setFrameRateMode
        setRuntimeVSyncEnabled = setVSyncEnabled
        currentRuntimeDisplayRefreshRate = currentDisplayRefreshRate
        installRuntimeNativeMenuBar = installNativeMenuBar
        minimizeMainWindowAction = minimizeWindow
        maximizeMainWindowAction = maximizeWindow
        restoreMainWindowAction = restoreWindow
        closeMainWindowAction = closeWindow
        mainWindowMaximizedQuery = isWindowMaximized
        minimizeWindowByIDAction = minimizeWindowByID
        maximizeWindowByIDAction = maximizeWindowByID
        restoreWindowByIDAction = restoreWindowByID
        closeWindowByIDAction = closeWindowByID
        windowMaximizedByIDQuery = isWindowMaximizedByID
        showWindowSystemMenuAction = showWindowSystemMenu
        setMainWindowChromeHitTestAction = setWindowChromeHitTest
    }
}
