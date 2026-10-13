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

        func request() -> Bool {
            lock.withLock {
                guard !pending else { return false }
                pending = true
                return true
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

    private var presentation = PresentationControls()
    private var mainWindow = MainWindowControls()
    private var windows = WindowControls()
    private let signal = Signal()
    private let wakeEventLoop: @Sendable () -> Void
    private var openAuxiliaryWindow: (@MainActor (AppAuxiliaryWindowRequest) -> WindowID?)?
    private var closeAuxiliaryWindow: (@MainActor (WindowID) -> Void)?
    private var auxiliaryWindowIsOpen: (@MainActor (WindowID) -> Bool)?
    private var installRuntimeNativeMenuBar: (@MainActor (NativeMenuBar) -> Void)?
    private var setCloseInterceptorAction: (@MainActor (((WindowID?) -> Bool)?) -> Void)?
    private var quitAction: (@MainActor () -> Void)?
    private var mainWindowIDQuery: (@MainActor () -> WindowID?)?
    private var openFolderDialogAction: (@MainActor (String?, @escaping (String?) -> Void) -> Void)?
    private var openFileDialogAction: (@MainActor (String?, [FileDialogFilter], Bool, @escaping ([String]) -> Void) -> Void)?

    public init(wakeEventLoop: @escaping @Sendable () -> Void = {}) {
        self.wakeEventLoop = wakeEventLoop
    }

    public nonisolated func requestDisplay() {
        if signal.request() {
            wakeEventLoop()
        }
    }

    @MainActor
    public func setTargetFrameRate(_ framesPerSecond: Double?) {
        presentation.setRuntimeTargetFrameRate?(framesPerSecond)
        requestDisplay()
    }

    @MainActor
    public func setFrameRateMode(_ mode: PlatformFrameRateMode) {
        presentation.setRuntimeFrameRateMode?(mode)
        requestDisplay()
    }

    @MainActor
    public func setVSyncEnabled(_ enabled: Bool) {
        presentation.setRuntimeVSyncEnabled?(enabled)
        requestDisplay()
    }

    @MainActor
    public func currentDisplayRefreshRate() -> Double? {
        presentation.currentRuntimeDisplayRefreshRate?()
    }

    @MainActor
    public func installNativeMenuBar(_ menuBar: NativeMenuBar) {
        installRuntimeNativeMenuBar?(menuBar)
    }

    @MainActor
    public func minimizeWindow() {
        mainWindow.minimizeMainWindowAction?()
    }

    @MainActor
    public func minimizeWindow(_ windowID: WindowID) {
        windows.minimizeWindowByIDAction?(windowID)
    }

    @MainActor
    public func maximizeWindow() {
        mainWindow.maximizeMainWindowAction?()
    }

    @MainActor
    public func maximizeWindow(_ windowID: WindowID) {
        windows.maximizeWindowByIDAction?(windowID)
    }

    @MainActor
    public func restoreWindow() {
        mainWindow.restoreMainWindowAction?()
    }

    /// 把主窗口完全收起——不是最小化。
    ///
    /// 最小化会在 Dock 里留一个入口，隐藏不会。只有状态栏/托盘图标的常驻型
    /// 应用关掉窗口时应该用这个，否则窗口会赖在 Dock 里。
    @MainActor
    public func hideWindow() {
        mainWindow.hideMainWindowAction?()
    }

    /// 重新显示被 `hideWindow()` 收起的主窗口。
    @MainActor
    public func showWindow() {
        mainWindow.showMainWindowAction?()
    }

    @MainActor
    public func restoreWindow(_ windowID: WindowID) {
        windows.restoreWindowByIDAction?(windowID)
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
        mainWindow.closeMainWindowAction?()
    }

    @MainActor
    public func isWindowMaximized() -> Bool {
        mainWindow.mainWindowMaximizedQuery?() ?? false
    }

    @MainActor
    public func isWindowMaximized(_ windowID: WindowID) -> Bool {
        windows.windowMaximizedByIDQuery?(windowID) ?? false
    }

    @MainActor
    public func showWindowSystemMenu(_ windowID: WindowID, x: Float = 0, y: Float = 0) {
        windows.showWindowSystemMenuAction?(windowID, x, y)
    }

    @MainActor
    public func setWindowChromeHitTest(_ hitTest: WindowChromeHitTest?) {
        mainWindow.setMainWindowChromeHitTestAction?(hitTest)
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
        if let close = windows.closeWindowByIDAction {
            close(windowID)
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
    func installCloseControls(setCloseInterceptor: @escaping @MainActor (((WindowID?) -> Bool)?) -> Void,
                              quit: @escaping @MainActor () -> Void,
                              mainWindowID: @escaping @MainActor () -> WindowID?) {
        setCloseInterceptorAction = setCloseInterceptor
        quitAction = quit
        mainWindowIDQuery = mainWindowID
    }

    /// Veto OS-initiated window closes / app quit (`nil` window = quit).
    /// Programmatic `closeWindow` / `quit()` bypass the interceptor, so a
    /// confirmation flow can re-issue the close it previously vetoed.
    @MainActor
    public func setWindowCloseInterceptor(_ handler: ((WindowID?) -> Bool)?) {
        setCloseInterceptorAction?(handler)
    }

    @MainActor
    public func quit() {
        quitAction?()
    }

    @MainActor
    public var mainWindowID: WindowID? {
        mainWindowIDQuery?()
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
    func installPresentationControls(_ controls: PresentationControls) { presentation = controls }

    @MainActor
    func installWindowControls(main: MainWindowControls, windows: WindowControls) {
        mainWindow = main
        self.windows = windows
    }

    @MainActor
    func installMenuControl(_ install: @escaping @MainActor (NativeMenuBar) -> Void) {
        installRuntimeNativeMenuBar = install
    }
}
