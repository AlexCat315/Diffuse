import EngineKernel
import Foundation
import GuavaUIBundledFonts
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIDevTools
import Logging
import PlatformShell
import RHIWGPU

/// 高层应用宿主。隐藏 `SDL3PlatformHost`、`WGPUBackend`、`DrawListRenderer`、
/// `TextEnvironment`、`ViewGraph` 等装配细节。
///
/// 调用方使用方式：
///
/// ```swift
/// try AppRuntime.run(config: AppConfig(title: "My App")) {
///     RootView()
/// }
/// ```
///
/// 单窗口、单 wgpu surface。多窗口 / 浮动工作区窗口走 GuavaUIWorkspace 路线，
/// 后续在此层之上扩展，不要让调用方再下沉到 `SDL3PlatformHost.openWindow`。
@MainActor
public final class AppRuntime {

    /// 启动主窗口并阻塞直到窗口关闭。返回值仅用于错误传递。
    ///
    /// `onTick` 会在每一帧 layout 之前调用，用于把外部子系统（例如游戏引擎
    /// `EngineHost`）按 UI 帧率推进。`deltaTime` 是上一帧到这一帧之间的秒数。
    public static func run<Root: View>(config: AppConfig = AppConfig(),
                                       backend: WGPUBackend? = nil,
                                       events: PlatformEventBridge = PlatformEventBridge(),
                                       onTick: ((_ deltaTime: Double) -> Void)? = nil,
                                       onDisplayReady: ((AppDisplayHandle) -> Void)? = nil,
                                       @ViewBuilder rootView: () -> Root) throws {
        let runtime = AppRuntime(config: config,
                                 backend: backend,
                                 events: events,
                                 onTick: onTick,
                                 onDisplayReady: onDisplayReady)
        try runtime.start(rootView: rootView())
    }

    // MARK: - Stored state

    private let config: AppConfig
    private let onTick: ((Double) -> Void)?
    private let onDisplayReady: ((AppDisplayHandle) -> Void)?
    private let events: PlatformEventBridge

    private let tree = NodeTree()
    private let host: SDL3PlatformHost
    private let graph: ViewGraph
    private let backend: WGPUBackend
    private let renderer: DrawListRenderer
    private let imageAssets: ImageAssetRegistry
    private let assetDropRegistry = AssetDropRegistry()
    private let viewportTextures: ViewportTextureRegistry
    private let drawList = DrawList()
    /// Phase 4c: layer-aware renderer drives RenderTree-based composition with
    /// per-layer DrawList caches. Falls back to the legacy `NodeRenderer`
    /// path when GUAVAUI_LEGACY_RENDERER=1 is set in the environment, so we
    /// can still bisect against the old painter while the new path stabilises.
    private let layerRenderer = LayerAwareNodeRenderer()
    private let nodeRenderer = NodeRenderer()
    private let useLegacyRenderer: Bool = {
        ProcessInfo.processInfo.environment["GUAVAUI_LEGACY_RENDERER"] == "1"
    }()

    /// 进程内的字体 atlas 纹理 id。固定为 1，调用方注册业务纹理时从 2 起。
    private let atlasTextureID: TextureID = 1

    private var surface: GPUSurface?
    private var configuredSurface = false
    private var msaaColorTexture: GPUTexture?
    private var msaaColorView: GPUTextureView?
    private var msaaColorWidth: UInt32 = 0
    private var msaaColorHeight: UInt32 = 0

    private var drawableW: UInt32 = 0
    private var drawableH: UInt32 = 0
    private var logicalW: UInt32 = 0
    private var logicalH: UInt32 = 0

    private var activeTextScale: Float = 0
    private var atlas: FontAtlas?

    private var didInstallRoot = false
    private var lastFrameTime: Double = 0
    private var auxiliaryWindows: [WindowID: AuxiliaryAppWindow] = [:]
    private var isVSyncEnabled = true
    private var lastMainWindowChromeHitTest: WindowChromeHitTest?

    private var currentPresentMode: GPUPresentMode {
        isVSyncEnabled ? .fifo : .immediate
    }

    /// 进程内 DevTools 调试服务器。仅当 `config.devTools != nil` 时创建。
    private var devTools: DevTools?
    private var devToolsTickedOnce = false
    private var devToolsFrameCounter: UInt64 = 0

    private init(config: AppConfig,
                 backend: WGPUBackend?,
                 events: PlatformEventBridge,
                 onTick: ((Double) -> Void)?,
                 onDisplayReady: ((AppDisplayHandle) -> Void)?) {
        self.config = config
        self.onTick = onTick
        self.onDisplayReady = onDisplayReady
        self.events = events
        let resolvedBackend = backend ?? WGPUBackend(config: config.backendConfig)
        self.backend = resolvedBackend
        self.renderer = DrawListRenderer(backend: resolvedBackend)
        self.imageAssets = ImageAssetRegistry(renderer: renderer)
        self.viewportTextures = ViewportTextureRegistry(renderer: renderer)
        self.host = SDL3PlatformHost(
            title: config.title,
            mainWindowOptions: WindowOptions(titleBarStyle: config.titleBarStyle.platformStyle)
        )
        self.host.setTargetFrameRate(config.targetFrameRate)
        self.graph = ViewGraph(tree: tree, recomposer: host.recomposer)
    }

    private func start<Root: View>(rootView: Root) throws {
        BundledFonts.register()
        try backend.initialize()

        if let devConfig = config.devTools {
            let dev = DevTools(config: devConfig,
                               tree: tree,
                               renderTree: graph.renderTree,
                               inputScene: graph.inputScene)
            // Install the log tap before any DevTools-related Logger fires
            // so the first records also reach the client.
            LogTapInstaller.bootstrapIfNeeded(sink: dev.logSink)
            dev.attachFrameTap(backend: backend, renderer: renderer)
            dev.inputDelivery = { [weak self] event in
                self?.host.mainSession?.injectEvent(event)
            }
            dev.onMirrorStart = { [weak self] in
                self?.host.requestDisplay()
            }
            do {
                try dev.start()
                self.devTools = dev
            } catch {
                Logger(label: "com.guava.ui.app").warning("DevTools server failed to start: \(error)")
            }
        }

        let previousViewportBridge = ViewportTextureBridgeHolder.current
        let previousImageAssets = ImageAssetRegistryHolder.current
        let previousAssetDropRegistry = AssetDropRegistryHolder.current
        ViewportTextureBridgeHolder.current = viewportTextures
        ImageAssetRegistryHolder.current = imageAssets
        AssetDropRegistryHolder.current = assetDropRegistry
        defer {
            ViewportTextureBridgeHolder.current = previousViewportBridge
            ImageAssetRegistryHolder.current = previousImageAssets
            AssetDropRegistryHolder.current = previousAssetDropRegistry
        }

        // 把进程级 holder 接到主窗口的 input context 上，使 Compose / Workspace
        // primitives 能直接读到 interaction / focus /
        // pointer-capture / clipboard。
        InteractionRegistryHolder.current = host.interactions
        FocusChainHolder.current = host.focusChain
        PointerCaptureHolder.current = host.pointerCapture
        ClipboardHolder.read = { SDL3Clipboard.read() }
        ClipboardHolder.write = { SDL3Clipboard.write($0) }

        host.onInit = { [weak self] native, w, h in
            try? self?.handleInit(native: native, widthPx: w, heightPx: h, rootView: rootView)
        }
        host.onResize = { [weak self] w, h in
            try? self?.handleResize(widthPx: w, heightPx: h)
        }
        host.onEvent = { [weak self] event in
            self?.events.publish(event)
        }
        host.onBeforeCommit = { [weak self] deltaTime in
            self?.handleFramePreparation(deltaTime: deltaTime)
        }
        host.onFrame = { [weak self] _ in
            self?.handleFrame() ?? false
        }

        let displayHandle = AppDisplayHandle()
        let previousDisplayHandle = AppDisplayHandleHolder.current
        AppDisplayHandleHolder.current = displayHandle
        defer {
            AppDisplayHandleHolder.current = previousDisplayHandle
        }
        host.externalDisplayRequestDrain = {
            displayHandle.drainDisplayRequest()
        }
        displayHandle.installAuxiliaryWindowControls(
            open: { [weak self] request in
                self?.openAuxiliaryWindow(request)
            },
            close: { [weak self] windowID in
                self?.closeAuxiliaryWindow(windowID)
            },
            isOpen: { [weak self] windowID in
                self?.isAuxiliaryWindowOpen(windowID) ?? false
            }
        )
        displayHandle.installRuntimeControls(
            setTargetFrameRate: { [weak self] framesPerSecond in
                self?.host.setTargetFrameRate(framesPerSecond)
            },
            setFrameRateMode: { [weak self] mode in
                self?.host.setFrameRateMode(mode)
            },
            setVSyncEnabled: { [weak self] enabled in
                self?.setVSyncEnabled(enabled)
            },
            currentDisplayRefreshRate: { [weak self] in
                self?.host.currentDisplayRefreshRate()
            },
            installNativeMenuBar: { menuBar in
                NativeMenuInstaller.install(menuBar)
            },
            minimizeWindow: { [weak self] in
                guard let id = self?.host.mainSession?.id else { return }
                self?.host.minimizeWindow(id)
            },
            maximizeWindow: { [weak self] in
                guard let id = self?.host.mainSession?.id else { return }
                self?.host.maximizeWindow(id)
            },
            restoreWindow: { [weak self] in
                guard let id = self?.host.mainSession?.id else { return }
                self?.host.restoreWindow(id)
            },
            closeWindow: { [weak self] in
                guard let self, let id = self.host.mainSession?.id else { return }
                self.host.closeWindow(id)
            },
            isWindowMaximized: { [weak self] in
                guard let id = self?.host.mainSession?.id else { return false }
                return self?.host.isWindowMaximized(id) ?? false
            },
            setWindowChromeHitTest: { [weak self] hitTest in
                guard let id = self?.host.mainSession?.id else { return }
                self?.host.setWindowChromeHitTest(id, hitTest)
            }
        )
        onDisplayReady?(displayHandle)
        host.run(tree: tree)
    }

    // MARK: - Lifecycle callbacks

    private func handleInit<Root: View>(native: NativeRenderSurface,
                                        widthPx: UInt32,
                                        heightPx: UInt32,
                                        rootView: Root) throws {
        drawableW = widthPx
        drawableH = heightPx
        logicalW = host.logicalSize.width
        logicalH = host.logicalSize.height

        let gpu = try SurfaceFactory.make(backend: backend, native: native)
        try gpu.configure(
            device: backend.rawDevice!,
            format: .bgra8Unorm,
            width: widthPx,
            height: heightPx,
            presentMode: currentPresentMode
        )
        if !isVSyncEnabled { native.disableDisplaySync() }
        try renderer.configure(format: .bgra8Unorm,
                               sampleCount: config.msaaSampleCount)
        try ensureMSAATarget(widthPx: widthPx, heightPx: heightPx)
        surface = gpu

        configureTextEnvironment(scale: host.contentScaleFactor)

        if !didInstallRoot {
            graph.install(root: rootView)
            graph.computeLayout(width: Float(logicalW), height: Float(logicalH))
            syncMainWindowChromeHitTest()
            // Phase 5b: hand the input mirror to the session's dispatcher
            // so subsequent events hit-test through `InputScene` rather
            // than re-walking the live Node tree.
            host.mainSession?.attachInputScene(graph.inputScene)
            didInstallRoot = true
        }

        try uploadAtlasIfNeeded()
        configuredSurface = true
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        
        // Request an initial frame to ensure surfaces like viewport have
        // time to initialize before the first render.
        host.requestDisplay()
    }

    private func handleResize(widthPx: UInt32, heightPx: UInt32) throws {
        drawableW = widthPx
        drawableH = heightPx
        logicalW = host.logicalSize.width
        logicalH = host.logicalSize.height
        guard let surface, let device = backend.rawDevice else { return }
        try surface.configure(
            device: device,
            format: .bgra8Unorm,
            width: widthPx,
            height: heightPx,
            presentMode: currentPresentMode
        )
        try ensureMSAATarget(widthPx: widthPx, heightPx: heightPx)
        configureTextEnvironment(scale: host.contentScaleFactor)
        try uploadAtlasIfNeeded()
    }

    private func setVSyncEnabled(_ enabled: Bool) {
        let changed = isVSyncEnabled != enabled
        if changed {
            isVSyncEnabled = enabled
            reconfigureMainSurfaceForCurrentPresentMode()
            for window in auxiliaryWindows.values {
                window.setPresentMode(currentPresentMode)
            }
        }
        host.setFrameRateMode(enabled ? .displayRefresh : .eventDriven)
        host.requestDisplay()
    }

    private func reconfigureMainSurfaceForCurrentPresentMode() {
        guard configuredSurface,
              let surface,
              let device = backend.rawDevice,
              drawableW > 0,
              drawableH > 0
        else { return }

        do {
            try surface.configure(
                device: device,
                format: .bgra8Unorm,
                width: drawableW,
                height: drawableH,
                presentMode: currentPresentMode
            )
        } catch {
            Logger(label: "com.guava.ui.app").warning("Main surface present mode update failed: \(error)")
        }
    }

    private func syncMainWindowChromeHitTest() {
        guard let root = tree.root,
              let id = host.mainSession?.id else { return }

        var config: WindowChromeHitTest?
        var dragRects: [WindowChromeHitTest.Rect] = []
        collectWindowChrome(node: root,
                            parentOrigin: .zero,
                            config: &config,
                            dragRects: &dragRects)

        guard var next = config else {
            if lastMainWindowChromeHitTest != nil {
                host.setWindowChromeHitTest(id, nil)
                lastMainWindowChromeHitTest = nil
            }
            return
        }

        next.draggableRects = dragRects
        guard next != lastMainWindowChromeHitTest else { return }
        host.setWindowChromeHitTest(id, next)
        lastMainWindowChromeHitTest = next
    }

    private func collectWindowChrome(node: Node,
                                     parentOrigin: CGPoint,
                                     config: inout WindowChromeHitTest?,
                                     dragRects: inout [WindowChromeHitTest.Rect]) {
        let origin = CGPoint(x: parentOrigin.x + node.frame.origin.x,
                             y: parentOrigin.y + node.frame.origin.y)

        if let chrome = node.attachments[WindowChromeAttachmentKey.configuration] as? WindowChromeHitTest {
            config = chrome
        }

        if node.attachments[WindowChromeAttachmentKey.dragRegion] as? Bool == true,
           node.frame.width > 0,
           node.frame.height > 0 {
            dragRects.append(WindowChromeHitTest.Rect(x: Float(origin.x),
                                                      y: Float(origin.y),
                                                      width: Float(node.frame.width),
                                                      height: Float(node.frame.height)))
        }

        let childOrigin = CGPoint(x: origin.x - node.contentOffset.x,
                                  y: origin.y - node.contentOffset.y)
        for child in node.children {
            collectWindowChrome(node: child,
                                parentOrigin: childOrigin,
                                config: &config,
                                dragRects: &dragRects)
        }
    }

    private func handleFrame() -> Bool {
        guard configuredSurface, let surface, let root = tree.root else { return false }

        let frameStart = ProcessInfo.processInfo.systemUptime

        configureTextEnvironment(scale: host.contentScaleFactor)
        let layoutStart = ProcessInfo.processInfo.systemUptime
        _ = graph.computeLayoutIfNeeded(width: Float(logicalW), height: Float(logicalH))
        syncMainWindowChromeHitTest()
        let layoutEnd = ProcessInfo.processInfo.systemUptime

        drawList.reset()
        if useLegacyRenderer {
            nodeRenderer.render(root: root, into: drawList)
        } else {
            layerRenderer.render(tree: graph.renderTree, into: drawList)
        }
        TooltipOverlayRegistry.drawAll(into: drawList)
        let drawEnd = ProcessInfo.processInfo.systemUptime

        do {
            if atlas?.isDirty == true {
                try uploadAtlasIfNeeded(force: true)
            }
        } catch {
            return false
        }

        let acquired: (texture: GPUTexture, view: GPUTextureView)?
        do {
            acquired = try surface.getCurrentTextureView()
        } catch {
            return false
        }
        guard let frame = acquired else {
            host.requestDisplay()
            return false
        }

        do {
            let encoder = try backend.createCommandEncoder()
            // Ensure MSAA target matches the current drawable size.
            // The swapchain may report a different size than what was used to configure the surface.
            if msaaColorWidth != drawableW || msaaColorHeight != drawableH {
                try ensureMSAATarget(widthPx: drawableW, heightPx: drawableH)
            }
            let passColorView = msaaColorView ?? frame.view
            let passResolveView = msaaColorView == nil ? nil : frame.view
            let pass = try encoder.beginRenderPass(
                colorView: passColorView,
                resolveTargetView: passResolveView,
                loadOp: .clear,
                storeOp: .store,
                clearColor: config.clearColor
            )
            try renderer.render(
                list: drawList,
                pass: pass,
                viewportPx: (drawableW, drawableH),
                coordinateSpace: (Float(logicalW), Float(logicalH))
            )
            pass.end()
            let buffer = try encoder.finish()
            backend.submit(buffer)
            surface.present()
            host.requestDisplay()
            let presentEnd = ProcessInfo.processInfo.systemUptime

            if let dev = devTools {
                devToolsTickedOnce = true
                if devToolsFrameCounter % 60 == 0 {
                    print("[guava.devtools] AppRuntime.handleFrame frame#\(devToolsFrameCounter) drawable=\(drawableW)x\(drawableH) logical=\(logicalW)x\(logicalH) batches=\(drawList.batches.count) mirrorActive=\(dev.mirrorIsActive)")
                }
                devToolsFrameCounter &+= 1
                dev.notifyTreeChanged()
                dev.mirrorCapture(
                    drawList: drawList,
                    widthPx: drawableW,
                    heightPx: drawableH,
                    logical: (Float(logicalW), Float(logicalH))
                )
                dev.timing.record(
                    layoutMs: (layoutEnd - layoutStart) * 1000,
                    drawMs: (drawEnd - layoutEnd) * 1000,
                    presentMs: (presentEnd - drawEnd) * 1000,
                    totalMs: (presentEnd - frameStart) * 1000,
                    nodeCount: countNodes(root),
                    batchCount: drawList.batches.count
                )
                // Mirror needs a steady frame stream even when the UI is
                // idle. Force the next frame so FrameTap keeps producing.
                if dev.mirrorIsActive {
                    host.requestDisplay()
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func handleFramePreparation(deltaTime: Double) {
        let delta = max(0, deltaTime)
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        onTick?(delta)
        syncAuxiliaryWindows()
    }

    /// Recursive scene-graph node count used purely for the timing payload.
    private func countNodes(_ node: Node) -> Int {
        var n = 1
        for child in node.children {
            n += countNodes(child)
        }
        return n
    }

    // MARK: - Text environment

    private func configureTextEnvironment(scale requestedScale: Float) {
        let scale = max(1, requestedScale)
        guard atlas == nil || abs(scale - activeTextScale) >= 0.01 else { return }
        activeTextScale = scale

        let atlasEdge = max(1024, Int((1024 * scale).rounded(.up)))
        let env = TextEnvironment.bootstrapped(
            atlasTextureID: atlasTextureID,
            primaryFontName: config.primaryFontName,
            defaultFont: Font.system(size: config.defaultFontSize),
            defaultLineHeight: config.defaultLineHeight,
            defaultColor: .white,
            rasterScale: scale,
            atlasEdge: atlasEdge
        )
        atlas = env.atlas
        TextEnvironmentHolder.current = env
        ContentScaleHolder.current = scale
    }

    private func uploadAtlasIfNeeded(force: Bool = false) throws {
        guard let atlas else { return }
        guard force || atlas.isDirty, let payload = atlas.dirtyUploadPayload() else {
            if force { atlas.markClean() }
            return
        }
        try payload.pixels.withUnsafeBufferPointer { buf in
            try renderer.registerAlphaTexture(
                id: atlasTextureID,
                pixels: buf.baseAddress!,
                width: UInt32(payload.region.width),
                height: UInt32(payload.region.height),
                originX: UInt32(payload.region.x),
                originY: UInt32(payload.region.y),
                textureWidth: UInt32(atlas.atlasWidth),
                textureHeight: UInt32(atlas.atlasHeight)
            )
        }
        atlas.markClean()
    }

    private func ensureMSAATarget(widthPx: UInt32, heightPx: UInt32) throws {
        guard config.msaaSampleCount > 1 else {
            msaaColorTexture = nil
            msaaColorView = nil
            msaaColorWidth = 0
            msaaColorHeight = 0
            return
        }

        if msaaColorTexture != nil,
           msaaColorView != nil,
           msaaColorWidth == widthPx,
           msaaColorHeight == heightPx {
            return
        }

        let texture = try backend.createTexture(
            width: widthPx,
            height: heightPx,
            format: .bgra8Unorm,
            usage: [.renderAttachment],
            mipLevels: 1,
            depthOrLayers: 1,
            sampleCount: config.msaaSampleCount
        )
        msaaColorTexture = texture
        msaaColorView = try texture.createView()
        msaaColorWidth = widthPx
        msaaColorHeight = heightPx
    }

    private func openAuxiliaryWindow(_ request: AppAuxiliaryWindowRequest) -> WindowID? {
        syncAuxiliaryWindows()

        do {
            let tree = NodeTree()
            let recomposer = Recomposer()
            let inputContext = PlatformInputContext()
            let session = try host.openWindow(
                title: request.title,
                tree: tree,
                recomposer: recomposer,
                inputContext: inputContext,
                options: WindowOptions(width: request.width, height: request.height)
            )
            let window = AuxiliaryAppWindow(session: session,
                                            rootView: request.rootView,
                                            backend: backend,
                                            renderer: renderer,
                                            config: config,
                                            presentMode: currentPresentMode,
                                            useLegacyRenderer: useLegacyRenderer)
            auxiliaryWindows[session.id] = window

            session.onInit = { [weak self, weak window] native, widthPx, heightPx in
                guard let self, let window else { return }
                try? window.handleInit(
                    native: native,
                    widthPx: widthPx,
                    heightPx: heightPx,
                    configureTextEnvironment: { scale in
                        self.configureTextEnvironment(scale: scale)
                    },
                    uploadAtlasIfNeeded: { force in
                        try self.uploadAtlasIfNeeded(force: force)
                    }
                )
            }
            session.onResize = { [weak self, weak window] widthPx, heightPx in
                guard let self, let window else { return }
                try? window.handleResize(
                    widthPx: widthPx,
                    heightPx: heightPx,
                    configureTextEnvironment: { scale in
                        self.configureTextEnvironment(scale: scale)
                    },
                    uploadAtlasIfNeeded: { force in
                        try self.uploadAtlasIfNeeded(force: force)
                    }
                )
            }
            session.onFrame = { [weak self, weak window] _ in
                guard let self, let window else { return false }
                return window.handleFrame(
                    configureTextEnvironment: { scale in
                        self.configureTextEnvironment(scale: scale)
                    },
                    uploadAtlasIfNeeded: { force in
                        try self.uploadAtlasIfNeeded(force: force)
                    }
                )
            }
            session.requestDisplay()
            return session.id
        } catch {
            Logger(label: "com.guava.ui.app").warning("Auxiliary window open failed: \(error)")
            return nil
        }
    }

    private func closeAuxiliaryWindow(_ windowID: WindowID) {
        auxiliaryWindows.removeValue(forKey: windowID)
        host.closeWindow(windowID)
    }

    private func isAuxiliaryWindowOpen(_ windowID: WindowID) -> Bool {
        syncAuxiliaryWindows()
        return auxiliaryWindows[windowID] != nil && host.session(for: windowID) != nil
    }

    private func syncAuxiliaryWindows() {
        let liveWindowIDs = Set(host.windowIDs)
        auxiliaryWindows = auxiliaryWindows.filter { liveWindowIDs.contains($0.key) }
    }
}

private extension AppWindowTitleBarStyle {
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
private final class AuxiliaryAppWindow {
    private let session: PlatformWindowSession
    private let graph: ViewGraph
    private let rootView: AnyView
    private let backend: WGPUBackend
    private let renderer: DrawListRenderer
    private let config: AppConfig
    private let useLegacyRenderer: Bool
    private let drawList = DrawList()
    private let layerRenderer = LayerAwareNodeRenderer()
    private let nodeRenderer = NodeRenderer()
    private var presentMode: GPUPresentMode

    private var surface: GPUSurface?
    private var configuredSurface = false
    private var msaaColorTexture: GPUTexture?
    private var msaaColorView: GPUTextureView?
    private var msaaColorWidth: UInt32 = 0
    private var msaaColorHeight: UInt32 = 0
    private var drawableW: UInt32 = 0
    private var drawableH: UInt32 = 0
    private var logicalW: UInt32 = 0
    private var logicalH: UInt32 = 0
    private var didInstallRoot = false

    init(session: PlatformWindowSession,
         rootView: AnyView,
         backend: WGPUBackend,
         renderer: DrawListRenderer,
         config: AppConfig,
         presentMode: GPUPresentMode,
         useLegacyRenderer: Bool) {
        self.session = session
        self.rootView = rootView
        self.backend = backend
        self.renderer = renderer
        self.config = config
        self.presentMode = presentMode
        self.useLegacyRenderer = useLegacyRenderer
        self.graph = ViewGraph(tree: session.tree, recomposer: session.recomposer)
    }

    func handleInit(native: NativeRenderSurface,
                    widthPx: UInt32,
                    heightPx: UInt32,
                    configureTextEnvironment: (Float) -> Void,
                    uploadAtlasIfNeeded: (Bool) throws -> Void) throws {
        drawableW = widthPx
        drawableH = heightPx
        logicalW = session.logicalSize.width
        logicalH = session.logicalSize.height

        let gpu = try SurfaceFactory.make(backend: backend, native: native)
        try gpu.configure(
            device: backend.rawDevice!,
            format: .bgra8Unorm,
            width: widthPx,
            height: heightPx,
            presentMode: presentMode
        )
        try ensureMSAATarget(widthPx: widthPx, heightPx: heightPx)
        surface = gpu

        try session.withCurrent {
            configureTextEnvironment(session.contentScaleFactor)
            if !didInstallRoot {
                graph.install(root: rootView)
                graph.computeLayout(width: Float(logicalW), height: Float(logicalH))
                session.attachInputScene(graph.inputScene)
                didInstallRoot = true
            }
            try uploadAtlasIfNeeded(false)
        }

        configuredSurface = true
        session.requestDisplay()
    }

    func handleResize(widthPx: UInt32,
                      heightPx: UInt32,
                      configureTextEnvironment: (Float) -> Void,
                      uploadAtlasIfNeeded: (Bool) throws -> Void) throws {
        drawableW = widthPx
        drawableH = heightPx
        logicalW = session.logicalSize.width
        logicalH = session.logicalSize.height
        guard let surface, let device = backend.rawDevice else { return }
        try surface.configure(
            device: device,
            format: .bgra8Unorm,
            width: widthPx,
            height: heightPx,
            presentMode: presentMode
        )
        try ensureMSAATarget(widthPx: widthPx, heightPx: heightPx)
        try session.withCurrent {
            configureTextEnvironment(session.contentScaleFactor)
            try uploadAtlasIfNeeded(false)
        }
    }

    func setPresentMode(_ mode: GPUPresentMode) {
        guard presentMode != mode else { return }
        presentMode = mode
        guard configuredSurface,
              let surface,
              let device = backend.rawDevice,
              drawableW > 0,
              drawableH > 0
        else { return }

        do {
            try surface.configure(
                device: device,
                format: .bgra8Unorm,
                width: drawableW,
                height: drawableH,
                presentMode: presentMode
            )
            session.requestDisplay()
        } catch {
            Logger(label: "com.guava.ui.app").warning("Auxiliary surface present mode update failed: \(error)")
        }
    }

    func handleFrame(configureTextEnvironment: (Float) -> Void,
                     uploadAtlasIfNeeded: (Bool) throws -> Void) -> Bool {
        guard configuredSurface,
              let surface,
              let root = session.tree.root else {
            return false
        }

        session.withCurrent {
            configureTextEnvironment(session.contentScaleFactor)
            _ = graph.computeLayoutIfNeeded(width: Float(logicalW), height: Float(logicalH))
            drawList.reset()
            if useLegacyRenderer {
                nodeRenderer.render(root: root, into: drawList)
            } else {
                layerRenderer.render(tree: graph.renderTree, into: drawList)
            }
        }
        TooltipOverlayRegistry.drawAll(into: drawList)

        do {
            try uploadAtlasIfNeeded(false)
        } catch {
            return false
        }

        let acquired: (texture: GPUTexture, view: GPUTextureView)?
        do {
            acquired = try surface.getCurrentTextureView()
        } catch {
            return false
        }
        guard let frame = acquired else {
            session.requestDisplay()
            return false
        }

        do {
            let encoder = try backend.createCommandEncoder()
            // Ensure MSAA target matches the current drawable size.
            // The swapchain may report a different size than what was used to configure the surface.
            if msaaColorWidth != drawableW || msaaColorHeight != drawableH {
                try ensureMSAATarget(widthPx: drawableW, heightPx: drawableH)
            }
            let passColorView = msaaColorView ?? frame.view
            let passResolveView = msaaColorView == nil ? nil : frame.view
            let pass = try encoder.beginRenderPass(
                colorView: passColorView,
                resolveTargetView: passResolveView,
                loadOp: .clear,
                storeOp: .store,
                clearColor: config.clearColor
            )
            try renderer.render(
                list: drawList,
                pass: pass,
                viewportPx: (drawableW, drawableH),
                coordinateSpace: (Float(logicalW), Float(logicalH))
            )
            pass.end()
            let buffer = try encoder.finish()
            backend.submit(buffer)
            surface.present()
            return true
        } catch {
            return false
        }
    }

    private func ensureMSAATarget(widthPx: UInt32, heightPx: UInt32) throws {
        guard config.msaaSampleCount > 1 else {
            msaaColorTexture = nil
            msaaColorView = nil
            msaaColorWidth = 0
            msaaColorHeight = 0
            return
        }

        if msaaColorTexture != nil,
           msaaColorView != nil,
           msaaColorWidth == widthPx,
           msaaColorHeight == heightPx {
            return
        }

        let texture = try backend.createTexture(
            width: widthPx,
            height: heightPx,
            format: .bgra8Unorm,
            usage: [.renderAttachment],
            mipLevels: 1,
            depthOrLayers: 1,
            sampleCount: config.msaaSampleCount
        )
        msaaColorTexture = texture
        msaaColorView = try texture.createView()
        msaaColorWidth = widthPx
        msaaColorHeight = heightPx
    }
}
