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
    private var openFolderDialogAction: (@MainActor (String?, @escaping (String?) -> Void) -> Void)?
    private var openFileDialogAction: (@MainActor (String?, [FileDialogFilter], Bool, @escaping ([String]) -> Void) -> Void)?

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

    /// Present the native "choose a folder" dialog. `accept` receives the
    /// chosen directory path, or `nil` if the user cancelled (or no platform
    /// dialog is available). Delivered on the main thread.
    @MainActor
    public func requestOpenFolder(defaultPath: String? = nil,
                                  accept: @escaping (String?) -> Void) {
        guard let openFolderDialogAction else {
            accept(nil)
            return
        }
        openFolderDialogAction(defaultPath, accept)
    }

    /// Present the native "choose file(s)" dialog. `filters` restricts the
    /// selectable types — each entry pairs a human label with bare extensions
    /// (no dots), e.g. `(name: "3D Models", extensions: ["glb", "gltf", "obj"])`.
    /// `accept` receives the chosen absolute paths (empty when the user
    /// cancelled or no platform dialog is available), delivered on the main
    /// thread.
    @MainActor
    public func requestOpenFile(filters: [(name: String, extensions: [String])] = [],
                                allowsMultiple: Bool = false,
                                defaultPath: String? = nil,
                                accept: @escaping ([String]) -> Void) {
        guard let openFileDialogAction else {
            accept([])
            return
        }
        let mapped = filters.map { FileDialogFilter(name: $0.name, extensions: $0.extensions) }
        openFileDialogAction(defaultPath, mapped, allowsMultiple, accept)
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
    func installFolderDialogControl(_ action: @escaping @MainActor (String?, @escaping (String?) -> Void) -> Void) {
        openFolderDialogAction = action
    }

    @MainActor
    func installFileDialogControl(_ action: @escaping @MainActor (String?, [FileDialogFilter], Bool, @escaping ([String]) -> Void) -> Void) {
        openFileDialogAction = action
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
