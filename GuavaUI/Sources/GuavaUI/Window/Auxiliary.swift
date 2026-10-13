import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIDevTools
import Logging
import NativeRHI
import PlatformShell

extension AppWindowTitleBarStyle {
    var platformStyle: WindowTitleBarStyle {
        switch self {
        case .standard:
            return .standard
        case .hiddenInset:
            return .hiddenInset
        }
    }
}

@MainActor
func withWindowChromeContext<R>(_ windowID: WindowID?, _ body: () throws -> R) rethrows -> R {
    let previous = AppWindowChromeContextHolder.current
    if let windowID {
        AppWindowChromeContextHolder.current = AppWindowChromeContext(windowID: windowID)
    }
    defer {
        AppWindowChromeContextHolder.current = previous
    }
    return try body()
}

@MainActor
final class AuxiliaryAppWindow {
    private let session: PlatformWindowSession
    let graph: ViewGraph
    private let rootView: AnyView
    private let portalStore: PortalStore
    private let rendering: AppRenderingContext
    private var windowRenderer: (any AppWindowRenderer)?
    private let config: ApplicationConfiguration
    private let useLegacyRenderer: Bool
    private let drawList = DrawList()
    private let layerRenderer = LayerAwareNodeRenderer()
    private let nodeRenderer = NodeRenderer()
    private var isVSyncEnabled: Bool

    private var logicalW: UInt32 = 0
    private var logicalH: UInt32 = 0
    private var didInstallRoot = false
    private let windowChromeHitTestCollector = WindowChromeHitTestCollector()
    private var lastWindowChromeHitTest: WindowChromeHitTest?
    private let setWindowChromeHitTest: (WindowID, WindowChromeHitTest?) -> Void

    init(session: PlatformWindowSession,
         rootView: AnyView,
         portalStore: PortalStore,
         rendering: AppRenderingContext,
         config: ApplicationConfiguration,
         isVSyncEnabled: Bool,
         useLegacyRenderer: Bool,
         setWindowChromeHitTest: @escaping (WindowID, WindowChromeHitTest?) -> Void) {
        self.session = session
        self.rootView = rootView
        self.portalStore = portalStore
        self.rendering = rendering
        self.config = config
        self.isVSyncEnabled = isVSyncEnabled
        self.useLegacyRenderer = useLegacyRenderer
        self.setWindowChromeHitTest = setWindowChromeHitTest
        self.graph = ViewGraph(tree: session.tree, recomposer: session.recomposer)
    }

    func handleInit(native: NativeRenderSurface,
                    widthPx: UInt32,
                    heightPx: UInt32,
                    configureTextEnvironment: (Float) -> Void,
                    uploadAtlasIfNeeded: (Bool) throws -> Void) throws {
        logicalW = session.logicalSize.width
        logicalH = session.logicalSize.height

        let renderer = try rendering.makeWindow(settings: AppWindowRenderSettings(config: config))
        try renderer.configure(native: native, size: SIMD2(widthPx, heightPx), vsync: isVSyncEnabled)
        windowRenderer = renderer

        try session.withCurrent {
            configureTextEnvironment(session.contentScaleFactor)
            if !didInstallRoot {
                withWindowChromeContext(session.id) {
                    graph.install(root: rootView.textScaler(config.typography.scaler).compositionLocal(
                        PortalStoreEnvironment.key,
                        portalStore
                    ))
                }
                graph.computeLayout(width: Float(logicalW), height: Float(logicalH))
                syncWindowChromeHitTest()
                didInstallRoot = true
            }
            try uploadAtlasIfNeeded(false)
        }

        session.requestDisplay()
    }

    /// Release this window's GPU surface (and MSAA target) before the shell
    /// destroys its SDL/Wayland window. See `Application.releaseGPUSurfaces()`.
    func releaseGPUSurface() {
        do { try windowRenderer?.close() }
        catch { Logger(label: "com.guava.ui.app").error("Auxiliary window GPU cleanup failed: \(error)") }
        windowRenderer = nil
    }

    func handleResize(widthPx: UInt32,
                      heightPx: UInt32,
                      configureTextEnvironment: (Float) -> Void,
                      uploadAtlasIfNeeded: (Bool) throws -> Void) throws {
        logicalW = session.logicalSize.width
        logicalH = session.logicalSize.height
        try windowRenderer?.resize(size: SIMD2(widthPx, heightPx), vsync: isVSyncEnabled)
        try session.withCurrent {
            configureTextEnvironment(session.contentScaleFactor)
            try uploadAtlasIfNeeded(false)
        }
    }

    func setVSyncEnabled(_ enabled: Bool) {
        isVSyncEnabled = enabled
        do {
            try windowRenderer?.resize(size: SIMD2(session.drawableSize.width, session.drawableSize.height), vsync: enabled)
            session.requestDisplay()
        } catch { Logger(label: "com.guava.ui.app").warning("Auxiliary present mode update failed: \(error)") }
    }

    private func syncWindowChromeHitTest() {
        guard let root = session.tree.root else { return }

        guard let next = windowChromeHitTestCollector.collect(root: root) else {
            if lastWindowChromeHitTest != nil {
                setWindowChromeHitTest(session.id, nil)
                lastWindowChromeHitTest = nil
            }
            return
        }

        guard next != lastWindowChromeHitTest else { return }
        setWindowChromeHitTest(session.id, next)
        lastWindowChromeHitTest = next
    }

    func handleFrame(host: SDL3PlatformHost, configureTextEnvironment: (Float) -> Void,
                     uploadAtlasIfNeeded: (Bool) throws -> Void) -> Bool {
        guard let windowRenderer, windowRenderer.isConfigured,
              let root = session.tree.root else {
            return false
        }

        session.withCurrent {
            configureTextEnvironment(session.contentScaleFactor)
            _ = graph.computeLayoutIfNeeded(width: Float(logicalW), height: Float(logicalH))
            syncWindowChromeHitTest()
            NativeAccessibility.synchronize(host: host, session: session, root: root)
            drawList.reset()
            drawList.pixelScale = Float(session.contentScaleFactor)
            if useLegacyRenderer {
                nodeRenderer.render(root: root, into: drawList)
            } else {
                layerRenderer.render(tree: graph.renderTree, into: drawList)
            }
        }
        // Explicitly this window's store (we are outside withCurrent here —
        // see the main-window handleFrame for the full invariant).

        do {
            try uploadAtlasIfNeeded(false)
        } catch {
            return false
        }

        do {
            let presented = try windowRenderer.draw(list: drawList, logical: SIMD2(Float(logicalW), Float(logicalH)))
            if !presented { session.requestDisplay() }
            return presented
        } catch { return false }
    }

}
