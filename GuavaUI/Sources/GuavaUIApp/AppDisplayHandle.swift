import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
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
    private var currentRuntimeDisplayRefreshRate: (@MainActor () -> Double?)?

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
    public func currentDisplayRefreshRate() -> Double? {
        currentRuntimeDisplayRefreshRate?()
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
        closeAuxiliaryWindow?(windowID)
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
                                currentDisplayRefreshRate: @escaping @MainActor () -> Double?) {
        setRuntimeTargetFrameRate = setTargetFrameRate
        setRuntimeFrameRateMode = setFrameRateMode
        currentRuntimeDisplayRefreshRate = currentDisplayRefreshRate
    }
}
