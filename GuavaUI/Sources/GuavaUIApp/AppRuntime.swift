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
        let devToolsLogSink: LogTap.Sink?
        if let devConfig = config.devTools, devConfig.autoInstallLogTap {
            let sink = LogTapInstaller.processSink
            LogTapInstaller.bootstrapIfNeeded(sink: sink)
            devToolsLogSink = sink
        } else {
            devToolsLogSink = nil
        }
        let runtime = AppRuntime(config: config,
                                 backend: backend,
                                 events: events,
                                 onTick: onTick,
                                 onDisplayReady: onDisplayReady,
                                 devToolsLogSink: devToolsLogSink)
        try runtime.start(rootView: rootView())
    }

    // MARK: - Stored state

    private let config: AppConfig
    private let onTick: ((Double) -> Void)?
    private let onDisplayReady: ((AppDisplayHandle) -> Void)?
    private let events: PlatformEventBridge
    private let devToolsLogSink: LogTap.Sink?

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
    /// Diagnostic override: GUAVA_VSYNC=off forces vsync off regardless of the
    /// persisted editor setting, so the real per-frame GPU cost is visible
    /// instead of being hidden behind the vsync wait.
    private static let forceVSyncOff: Bool = {
        switch ProcessInfo.processInfo.environment["GUAVA_VSYNC"]?.lowercased() {
        case "off", "0", "false", "no": return true
        default: return false
        }
    }()
    private var isVSyncEnabled = !AppRuntime.forceVSyncOff
    private let mainWindowChromeHitTestCollector = WindowChromeHitTestCollector()
    private var lastMainWindowChromeHitTest: WindowChromeHitTest?

    /// Lightweight per-second FPS + frame-cost breakdown to stdout, enabled
    /// with GUAVA_FPS_LOG=1. Splits CPU build cost (layout/draw) from the
    /// acquire+submit+present cost so we can tell whether the loop is
    /// CPU-bound (→ pipelining/parallelism helps) or present/GPU-bound
    /// (→ it does not — look at vsync / cross-adapter present instead).
    private static let fpsLogEnabled =
        ProcessInfo.processInfo.environment["GUAVA_FPS_LOG"] == "1"
    /// Profiling-only override for measuring a normally event-driven app under
    /// a steady frame stream. The host still follows the display refresh rate.
    private static let forceContinuousFrameDrive =
        ProcessInfo.processInfo.environment["GUAVAUI_FORCE_CONTINUOUS_FRAMES"] == "1"
    private var fpsFrames = 0
    private var fpsWindowStart: Double = 0
    private var fpsLayoutAccum = 0.0
    private var fpsDrawAccum = 0.0
    private var fpsPresentAccum = 0.0
    private var fpsTickAccum = 0.0

    private var currentPresentMode: GPUPresentMode = .fifo
    /// Callback APIs on SDL3PlatformHost are non-throwing. Preserve the first
    /// fatal main-window lifecycle failure so `run` can surface it after the
    /// event loop has been stopped instead of leaving an unexplained blank UI.
    private var runLoopError: Error?

    /// 进程内 DevTools 调试服务器。仅当 `config.devTools != nil` 时创建。
    private var devTools: DevTools?

    private init(config: AppConfig,
                 backend: WGPUBackend?,
                 events: PlatformEventBridge,
                 onTick: ((Double) -> Void)?,
                 onDisplayReady: ((AppDisplayHandle) -> Void)?,
                 devToolsLogSink: LogTap.Sink?) {
        self.config = config
        self.onTick = onTick
        self.onDisplayReady = onDisplayReady
        self.events = events
        self.devToolsLogSink = devToolsLogSink
        let resolvedBackend = backend ?? WGPUBackend(config: config.backendConfig)
        self.backend = resolvedBackend
        self.renderer = DrawListRenderer(backend: resolvedBackend)
        self.imageAssets = ImageAssetRegistry(renderer: renderer)
        self.viewportTextures = ViewportTextureRegistry(renderer: renderer)
        // Each window gets its own portal store (规则 3): an open overlay in one
        // window can never paint into or swallow clicks for another. The store is
        // swapped in lockstep with the window's input registries via withCurrent.
        let mainInputContext = PlatformInputContext()
        mainInputContext.addScopedAmbient(PortalStoreAmbient(PortalStore()))
        self.host = SDL3PlatformHost(
            title: config.title,
            mainWindowOptions: WindowOptions(titleBarStyle: config.titleBarStyle.platformStyle),
            inputContext: mainInputContext
        )
        self.graph = ViewGraph(tree: tree, recomposer: host.recomposer)
        configureHostFrameDrive()
    }

    private func configureHostFrameDrive() {
        if let targetFrameRate = config.targetFrameRate {
            host.setTargetFrameRate(targetFrameRate)
            return
        }

        switch config.frameDrivePolicy {
        case .continuous:
            host.setFrameRateMode(.displayRefresh)
        case .eventDriven:
            host.setFrameRateMode(.eventDriven)
        }
    }

    private func start<Root: View>(rootView: Root) throws {
        BundledFonts.register()
        try backend.initialize()

        if let devConfig = config.devTools {
            let dev = DevTools(config: devConfig,
                               tree: tree,
                               invalidationLog: host.invalidationLog,
                               renderTree: graph.renderTree,
                               logSink: devToolsLogSink ?? LogTap.Sink())
            dev.attachFrameTap(backend: backend, renderer: renderer)
            dev.server.hostMainExecutor = { [weak self] operation in
                self?.host.enqueueMainThreadWork {
                    MainActor.assumeIsolated {
                        operation()
                    }
                }
            }
            dev.inputDelivery = { [weak self] event in
                self?.host.mainSession?.injectEvent(event)
            }
            dev.onMirrorStart = { [weak self] in
                self?.host.requestDisplay()
            }
            dev.onSelectionChanged = { [weak self] in
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
        let previousUIWorkScheduler = UIWorkSchedulerHolder.enqueue
        ViewportTextureBridgeHolder.current = viewportTextures
        ImageAssetRegistryHolder.current = imageAssets
        AssetDropRegistryHolder.current = assetDropRegistry
        UIWorkSchedulerHolder.enqueue = { [weak host] work in
            host?.enqueueMainThreadWork(work)
        }
        defer {
            ViewportTextureBridgeHolder.current = previousViewportBridge
            ImageAssetRegistryHolder.current = previousImageAssets
            AssetDropRegistryHolder.current = previousAssetDropRegistry
            UIWorkSchedulerHolder.enqueue = previousUIWorkScheduler
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
            guard let self else { return }
            do {
                try self.handleInit(native: native, widthPx: w, heightPx: h, rootView: rootView)
            } catch {
                self.failRunLoop(error, context: "main window initialization")
            }
        }
        host.onResize = { [weak self] w, h in
            guard let self else { return }
            do {
                try self.handleResize(widthPx: w, heightPx: h)
            } catch {
                self.failRunLoop(error, context: "main window resize")
            }
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
        host.onWindowTeardown = { [weak self] windowID in
            self?.releaseGPUSurface(for: windowID)
        }
        host.onTeardown = { [weak self] in
            self?.devTools?.stop()
            self?.devTools = nil
            self?.releaseGPUSurfaces()
        }

        let displayHandle = AppDisplayHandle { [weak host] in
            host?.wakeEventLoop()
        }
        let previousDisplayHandle = AppDisplayHandleHolder.current
        AppDisplayHandleHolder.current = displayHandle
        defer {
            AppDisplayHandleHolder.current = previousDisplayHandle
        }
        host.externalDisplayRequestDrain = {
            displayHandle.drainDisplayRequest()
        }
        displayHandle.installFolderDialogControl { [weak self] defaultPath, accept in
            guard let self else { accept(nil); return }
            self.host.showOpenFolderDialog(windowID: self.host.mainSession?.id,
                                           defaultPath: defaultPath,
                                           accept: accept)
        }
        displayHandle.installFileDialogControl { [weak self] defaultPath, filters, allowsMultiple, accept in
            guard let self else { accept([]); return }
            self.host.showOpenFileDialog(windowID: self.host.mainSession?.id,
                                         defaultPath: defaultPath,
                                         filters: filters,
                                         allowsMultiple: allowsMultiple,
                                         accept: accept)
        }
        displayHandle.installCloseControls(
            setCloseInterceptor: { [weak self] handler in
                self?.host.windowCloseInterceptor = handler
            },
            quit: { [weak self] in
                self?.host.stop()
            },
            mainWindowID: { [weak self] in
                self?.host.mainSession?.id
            }
        )
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
            minimizeWindowByID: { [weak self] id in
                self?.host.minimizeWindow(id)
            },
            maximizeWindowByID: { [weak self] id in
                self?.host.maximizeWindow(id)
            },
            restoreWindowByID: { [weak self] id in
                self?.host.restoreWindow(id)
            },
            closeWindowByID: { [weak self] id in
                self?.host.closeWindow(id)
                self?.auxiliaryWindows.removeValue(forKey: id)
            },
            isWindowMaximizedByID: { [weak self] id in
                self?.host.isWindowMaximized(id) ?? false
            },
            showWindowSystemMenu: { [weak self] id, x, y in
                self?.host.showWindowSystemMenu(id, x: x, y: y)
            },
            setWindowChromeHitTest: { [weak self] hitTest in
                guard let id = self?.host.mainSession?.id else { return }
                self?.host.setWindowChromeHitTest(id, hitTest)
            }
        )
        onDisplayReady?(displayHandle)
        host.run(tree: tree)
        if let runLoopError { throw runLoopError }
    }

    // MARK: - Lifecycle callbacks

    private func failRunLoop(_ error: Error, context: String) {
        guard runLoopError == nil else { return }
        runLoopError = error
        Logger(label: "com.guava.ui.app").error("\(context) failed: \(error)")
        host.stop()
    }

    /// Release every GPU surface (main window + auxiliary windows) before the host
    /// shell destroys its windows and quits SDL. A `GPUSurface` built from a
    /// Wayland window holds the `wl_display`/`wl_surface`; releasing it after
    /// `SDL_Quit` has disconnected Wayland dereferences freed proxies and crashes
    /// in libwayland-client. Wired to `host.onTeardown`, which fires after the run
    /// loop exits but before `shell.shutdown()`.
    private func releaseGPUSurfaces() {
        configuredSurface = false
        msaaColorView = nil
        msaaColorTexture = nil
        msaaColorWidth = 0
        msaaColorHeight = 0
        surface = nil
        for window in auxiliaryWindows.values {
            window.releaseGPUSurface()
        }
    }

    private func releaseGPUSurface(for windowID: WindowID) {
        if host.mainSession?.id == windowID {
            configuredSurface = false
            msaaColorView = nil
            msaaColorTexture = nil
            msaaColorWidth = 0
            msaaColorHeight = 0
            surface = nil
            return
        }

        auxiliaryWindows[windowID]?.releaseGPUSurface()
    }

    private func handleInit<Root: View>(native: NativeRenderSurface,
                                        widthPx: UInt32,
                                        heightPx: UInt32,
                                        rootView: Root) throws {
        drawableW = widthPx
        drawableH = heightPx
        logicalW = host.logicalSize.width
        logicalH = host.logicalSize.height

        let gpu = try SurfaceFactory.make(backend: backend, native: native)
        let presentMode = resolvePresentMode(for: gpu, context: "main surface init")
        try gpu.configure(
            device: backend.rawDevice!,
            format: .bgra8UnormSrgb,
            width: widthPx,
            height: heightPx,
            presentMode: presentMode
        )
        currentPresentMode = presentMode
        if !isVSyncEnabled { native.disableDisplaySync() }
        try renderer.configure(format: .bgra8UnormSrgb,
                               sampleCount: config.msaaSampleCount)
        try ensureMSAATarget(widthPx: widthPx, heightPx: heightPx)
        surface = gpu

        configureTextEnvironment(scale: host.contentScaleFactor)

        if !didInstallRoot {
            withWindowChromeContext(host.mainSession?.id) {
                graph.install(root: rootView)
            }
            graph.computeLayout(width: Float(logicalW), height: Float(logicalH))
            syncMainWindowChromeHitTest()
            didInstallRoot = true
        }

        try uploadAtlasIfNeeded()
        configuredSurface = true
        lastFrameTime = TimingTrace.now()
        
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
        let presentMode = resolvePresentMode(for: surface, context: "main surface resize")
        try surface.configure(
            device: device,
            format: .bgra8UnormSrgb,
            width: widthPx,
            height: heightPx,
            presentMode: presentMode
        )
        currentPresentMode = presentMode
        try ensureMSAATarget(widthPx: widthPx, heightPx: heightPx)
        configureTextEnvironment(scale: host.contentScaleFactor)
        try uploadAtlasIfNeeded()
    }

    private func setVSyncEnabled(_ enabled: Bool) {
        let enabled = enabled && !Self.forceVSyncOff
        let changed = isVSyncEnabled != enabled
        if changed {
            isVSyncEnabled = enabled
            reconfigureMainSurfaceForCurrentPresentMode()
            for window in auxiliaryWindows.values {
                window.setVSyncEnabled(isVSyncEnabled)
            }
        }
        // VSync controls the surface present mode only. Frame cadence is owned
        // by `AppConfig.frameDrivePolicy` or an explicit runtime frame-rate
        // override; tying it to VSync makes input/update pacing change when the
        // user only asked to change presentation.
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
            let presentMode = resolvePresentMode(for: surface, context: "main surface present mode update")
            try surface.configure(
                device: device,
                format: .bgra8UnormSrgb,
                width: drawableW,
                height: drawableH,
                presentMode: presentMode
            )
            currentPresentMode = presentMode
        } catch {
            Logger(label: "com.guava.ui.app").warning("Main surface present mode update failed: \(error)")
        }
    }

    private func resolvePresentMode(for surface: GPUSurface,
                                    context: String) -> GPUPresentMode {
        let candidates = Self.presentModeCandidates(vsyncEnabled: isVSyncEnabled,
                                                    preferred: config.vsyncPresentMode)
        guard let adapter = backend.rawAdapter else {
            Logger(label: "com.guava.ui.app").warning("\(context): no adapter available; falling back to FIFO present mode")
            return .fifo
        }

        do {
            let supported = try surface.supportedPresentModes(adapter: adapter)
            if let selected = candidates.first(where: { supported.contains($0) }) {
                if selected != (candidates.first ?? selected) {
                    Logger(label: "com.guava.ui.app").info("\(context): present mode \(String(describing: candidates.first ?? selected)) unsupported; using \(String(describing: selected))")
                }
                return selected
            }
            if supported.contains(.fifo) {
                Logger(label: "com.guava.ui.app").warning("\(context): none of \(String(describing: candidates)) are supported; falling back to FIFO")
                return .fifo
            }
            if let first = supported.first {
                Logger(label: "com.guava.ui.app").warning("\(context): none of \(String(describing: candidates)) are supported; using \(String(describing: first))")
                return first
            }
        } catch {
            Logger(label: "com.guava.ui.app").warning("\(context): present mode capability query failed: \(error); falling back to FIFO")
        }

        return .fifo
    }

    fileprivate static func presentModeCandidates(vsyncEnabled: Bool,
                                                  preferred: GPUPresentMode) -> [GPUPresentMode] {
        let desired: [GPUPresentMode]
        if vsyncEnabled {
            if preferred == .fifo || preferred == .immediate {
                desired = [preferred, .fifo]
            } else {
                desired = [preferred, .immediate, .fifo]
            }
        } else {
            desired = [.immediate, .fifo]
        }

        var candidates: [GPUPresentMode] = []
        for mode in desired where !candidates.contains(mode) {
            candidates.append(mode)
        }
        return candidates
    }

    private func syncMainWindowChromeHitTest() {
        guard let root = tree.root,
              let id = host.mainSession?.id else { return }

        guard let next = mainWindowChromeHitTestCollector.collect(root: root) else {
            if lastMainWindowChromeHitTest != nil {
                host.setWindowChromeHitTest(id, nil)
                lastMainWindowChromeHitTest = nil
            }
            return
        }

        guard next != lastMainWindowChromeHitTest else { return }
        host.setWindowChromeHitTest(id, next)
        lastMainWindowChromeHitTest = next
    }

    private func handleFrame() -> Bool {
        guard configuredSurface, let surface, let root = tree.root else { return false }

        let frameStart = TimingTrace.now()

        configureTextEnvironment(scale: host.contentScaleFactor)
        let layoutStart = TimingTrace.now()
        _ = graph.computeLayoutIfNeeded(width: Float(logicalW), height: Float(logicalH))
        syncMainWindowChromeHitTest()
        let layoutEnd = TimingTrace.now()

        drawList.reset()
        if useLegacyRenderer {
            nodeRenderer.render(root: root, into: drawList)
        } else {
            layerRenderer.render(tree: graph.renderTree, into: drawList)
        }
        // Explicitly this window's tooltip store. This frame hook runs OUTSIDE
        // `session.withCurrent`, so the ambient `TooltipStoreHolder.current`
        // would resolve to the shared default here — while Button registers
        // tooltips during recompose (inside withCurrent) into the per-window
        // store. Reading the store explicitly keeps register/draw on the same
        // instance.
        host.tooltips.drawAll(into: drawList)
        drawDevToolsOverlay(into: drawList)
        let drawEnd = TimingTrace.now()

        do {
            if atlas?.isDirty == true {
                try uploadAtlasIfNeeded(force: true)
            }
        } catch {
            return false
        }

        if let dev = devTools {
            if root.isDirty || root.renderDirty {
                dev.notifyTreeChanged()
            }
        }

        let acquired: (texture: GPUTexture, view: GPUTextureView)?
        do {
            acquired = try surface.getCurrentTextureView()
        } catch {
            return false
        }
        guard let frame = acquired else {
            devTools?.mirrorCapture(
                drawList: drawList,
                widthPx: drawableW,
                heightPx: drawableH,
                logical: (Float(logicalW), Float(logicalH))
            )
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
            if let dev = devTools {
                // Keep synchronous mirror readback behind the primary
                // swapchain submission. Doing it before acquisition can make
                // the native surface unavailable on subsequent frames.
                dev.mirrorCapture(
                    drawList: drawList,
                    widthPx: drawableW,
                    heightPx: drawableH,
                    logical: (Float(logicalW), Float(logicalH))
                )
            }
            if config.frameDrivePolicy == .continuous || Self.forceContinuousFrameDrive {
                // Legacy behavior: keep re-rendering at display rate. Under
                // `.eventDriven` the loop's needsDisplay machinery (input,
                // recompose, markRenderDirty, animations, requestDisplay)
                // schedules the next frame instead.
                host.requestDisplay()
            }
            let presentEnd = TimingTrace.now()

            if Self.fpsLogEnabled {
                recordFPSSample(layoutMs: (layoutEnd - layoutStart) * 1000,
                                drawMs: (drawEnd - layoutEnd) * 1000,
                                presentMs: (presentEnd - drawEnd) * 1000)
            }

            if let dev = devTools {
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
        lastFrameTime = TimingTrace.now()
        let tickStart = TimingTrace.now()
        onTick?(delta)
        if Self.fpsLogEnabled {
            fpsTickAccum += (TimingTrace.now() - tickStart) * 1000
        }
        syncAuxiliaryWindows()
    }

    /// Accumulate one frame's timing and emit a one-line summary roughly once
    /// per second. `presentMs` covers acquire + encode + submit + present, i.e.
    /// the part that blocks on vsync / GPU / cross-adapter copy.
    private func recordFPSSample(layoutMs: Double, drawMs: Double, presentMs: Double) {
        let now = TimingTrace.now()
        if fpsWindowStart == 0 { fpsWindowStart = now }
        fpsFrames += 1
        fpsLayoutAccum += layoutMs
        fpsDrawAccum += drawMs
        fpsPresentAccum += presentMs

        let elapsed = now - fpsWindowStart
        guard elapsed >= 1.0 else { return }
        let n = Double(fpsFrames)
        // Write to stderr: when stdout is redirected to a file it is block
        // buffered, so a force-killed GUI run would lose buffered samples.
        let line = String(format: "[guava.fps] %.1f fps | sim/tick=%.2fms | cpu: layout=%.2fms draw=%.2fms | gpu/present=%.2fms (n=%d)\n",
                          n / elapsed,
                          fpsTickAccum / n,
                          fpsLayoutAccum / n,
                          fpsDrawAccum / n,
                          fpsPresentAccum / n,
                          fpsFrames)
        FileHandle.standardError.write(Data(line.utf8))
        fpsFrames = 0
        fpsWindowStart = now
        fpsLayoutAccum = 0
        fpsDrawAccum = 0
        fpsPresentAccum = 0
        fpsTickAccum = 0
    }

    /// Recursive scene-graph node count used purely for the timing payload.
    private func countNodes(_ node: Node) -> Int {
        var n = 1
        for child in node.children {
            n += countNodes(child)
        }
        return n
    }

    private func drawDevToolsOverlay(into list: DrawList) {
        guard let frame = devTools?.selectedNodeAbsoluteFrame else { return }
        let x = Float(frame.origin.x)
        let y = Float(frame.origin.y)
        let width = Float(frame.size.width)
        let height = Float(frame.size.height)
        guard width > 0, height > 0 else { return }

        let rect = UIRect(x: x, y: y, width: width, height: height)
        list.addRect(rect, color: Color(red: 0x35, green: 0x74, blue: 0xF0, alpha: 0x20))

        let stroke = Color(red: 0x72, green: 0xB4, blue: 0xFF, alpha: 0xF0)
        let shadow = Color(r: 0, g: 0, b: 0, a: 0.45)
        drawFrame(rect, thickness: 4, color: shadow, into: list)
        drawFrame(rect, thickness: 2, color: stroke, into: list)
    }

    private func drawFrame(_ rect: UIRect,
                           thickness: Float,
                           color: Color,
                           into list: DrawList) {
        let half = thickness * 0.5
        list.addLine(fromX: rect.minX, fromY: rect.minY + half,
                     toX: rect.maxX, toY: rect.minY + half,
                     thickness: thickness, color: color)
        list.addLine(fromX: rect.maxX - half, fromY: rect.minY,
                     toX: rect.maxX - half, toY: rect.maxY,
                     thickness: thickness, color: color)
        list.addLine(fromX: rect.maxX, fromY: rect.maxY - half,
                     toX: rect.minX, toY: rect.maxY - half,
                     thickness: thickness, color: color)
        list.addLine(fromX: rect.minX + half, fromY: rect.maxY,
                     toX: rect.minX + half, toY: rect.minY,
                     thickness: thickness, color: color)
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
            format: .bgra8UnormSrgb,
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
            inputContext.addScopedAmbient(PortalStoreAmbient(PortalStore()))
            let session = try host.openWindow(
                title: request.title,
                tree: tree,
                recomposer: recomposer,
                inputContext: inputContext,
                options: WindowOptions(width: request.width,
                                       height: request.height,
                                       titleBarStyle: config.titleBarStyle.platformStyle)
            )
            let window = AuxiliaryAppWindow(session: session,
                                            rootView: request.rootView,
                                            backend: backend,
                                            renderer: renderer,
                                            config: config,
                                            isVSyncEnabled: isVSyncEnabled,
                                            useLegacyRenderer: useLegacyRenderer,
                                            setWindowChromeHitTest: { [weak self] id, hitTest in
                                                self?.host.setWindowChromeHitTest(id, hitTest)
                                            })
            auxiliaryWindows[session.id] = window
            let windowID = session.id

            session.onInit = { [weak self, weak window] native, widthPx, heightPx in
                guard let self, let window else { return }
                do {
                    try window.handleInit(
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
                } catch {
                    self.failAuxiliaryWindow(windowID, error: error, context: "initialization")
                }
            }
            session.onResize = { [weak self, weak window] widthPx, heightPx in
                guard let self, let window else { return }
                do {
                    try window.handleResize(
                        widthPx: widthPx,
                        heightPx: heightPx,
                        configureTextEnvironment: { scale in
                            self.configureTextEnvironment(scale: scale)
                        },
                        uploadAtlasIfNeeded: { force in
                            try self.uploadAtlasIfNeeded(force: force)
                        }
                    )
                } catch {
                    self.failAuxiliaryWindow(windowID, error: error, context: "resize")
                }
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
        host.closeWindow(windowID)
        auxiliaryWindows.removeValue(forKey: windowID)
    }

    private func failAuxiliaryWindow(_ windowID: WindowID,
                                     error: Error,
                                     context: String) {
        Logger(label: "com.guava.ui.app")
            .error("auxiliary window \(context) failed: \(error)")
        host.enqueueMainThreadWork { [weak self] in
            self?.closeAuxiliaryWindow(windowID)
        }
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
private func withWindowChromeContext<R>(_ windowID: WindowID?, _ body: () throws -> R) rethrows -> R {
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
    private var isVSyncEnabled: Bool
    private var presentMode: GPUPresentMode = .fifo

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
    private let windowChromeHitTestCollector = WindowChromeHitTestCollector()
    private var lastWindowChromeHitTest: WindowChromeHitTest?
    private let setWindowChromeHitTest: (WindowID, WindowChromeHitTest?) -> Void

    init(session: PlatformWindowSession,
         rootView: AnyView,
         backend: WGPUBackend,
         renderer: DrawListRenderer,
         config: AppConfig,
         isVSyncEnabled: Bool,
         useLegacyRenderer: Bool,
         setWindowChromeHitTest: @escaping (WindowID, WindowChromeHitTest?) -> Void) {
        self.session = session
        self.rootView = rootView
        self.backend = backend
        self.renderer = renderer
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
        drawableW = widthPx
        drawableH = heightPx
        logicalW = session.logicalSize.width
        logicalH = session.logicalSize.height

        let gpu = try SurfaceFactory.make(backend: backend, native: native)
        let resolvedPresentMode = resolvePresentMode(for: gpu, context: "auxiliary surface init")
        try gpu.configure(
            device: backend.rawDevice!,
            format: .bgra8UnormSrgb,
            width: widthPx,
            height: heightPx,
            presentMode: resolvedPresentMode
        )
        presentMode = resolvedPresentMode
        try ensureMSAATarget(widthPx: widthPx, heightPx: heightPx)
        surface = gpu

        try session.withCurrent {
            configureTextEnvironment(session.contentScaleFactor)
            if !didInstallRoot {
                withWindowChromeContext(session.id) {
                    graph.install(root: rootView)
                }
                graph.computeLayout(width: Float(logicalW), height: Float(logicalH))
                syncWindowChromeHitTest()
                didInstallRoot = true
            }
            try uploadAtlasIfNeeded(false)
        }

        configuredSurface = true
        session.requestDisplay()
    }

    /// Release this window's GPU surface (and MSAA target) before the shell
    /// destroys its SDL/Wayland window. See `AppRuntime.releaseGPUSurfaces()`.
    func releaseGPUSurface() {
        configuredSurface = false
        msaaColorView = nil
        msaaColorTexture = nil
        msaaColorWidth = 0
        msaaColorHeight = 0
        surface = nil
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
        let resolvedPresentMode = resolvePresentMode(for: surface, context: "auxiliary surface resize")
        try surface.configure(
            device: device,
            format: .bgra8UnormSrgb,
            width: widthPx,
            height: heightPx,
            presentMode: resolvedPresentMode
        )
        presentMode = resolvedPresentMode
        try ensureMSAATarget(widthPx: widthPx, heightPx: heightPx)
        try session.withCurrent {
            configureTextEnvironment(session.contentScaleFactor)
            try uploadAtlasIfNeeded(false)
        }
    }

    func setVSyncEnabled(_ enabled: Bool) {
        isVSyncEnabled = enabled
        guard configuredSurface,
              let surface,
              let device = backend.rawDevice,
              drawableW > 0,
              drawableH > 0
        else { return }

        do {
            let resolvedPresentMode = resolvePresentMode(for: surface, context: "auxiliary surface present mode update")
            guard presentMode != resolvedPresentMode else { return }
            try surface.configure(
                device: device,
                format: .bgra8UnormSrgb,
                width: drawableW,
                height: drawableH,
                presentMode: resolvedPresentMode
            )
            presentMode = resolvedPresentMode
            session.requestDisplay()
        } catch {
            Logger(label: "com.guava.ui.app").warning("Auxiliary surface present mode update failed: \(error)")
        }
    }

    private func resolvePresentMode(for surface: GPUSurface,
                                    context: String) -> GPUPresentMode {
        let candidates = AppRuntime.presentModeCandidates(vsyncEnabled: isVSyncEnabled,
                                                          preferred: config.vsyncPresentMode)
        guard let adapter = backend.rawAdapter else {
            Logger(label: "com.guava.ui.app").warning("\(context): no adapter available; falling back to FIFO present mode")
            return .fifo
        }

        do {
            let supported = try surface.supportedPresentModes(adapter: adapter)
            if let selected = candidates.first(where: { supported.contains($0) }) {
                if selected != (candidates.first ?? selected) {
                    Logger(label: "com.guava.ui.app").info("\(context): present mode \(String(describing: candidates.first ?? selected)) unsupported; using \(String(describing: selected))")
                }
                return selected
            }
            if supported.contains(.fifo) {
                Logger(label: "com.guava.ui.app").warning("\(context): none of \(String(describing: candidates)) are supported; falling back to FIFO")
                return .fifo
            }
            if let first = supported.first {
                Logger(label: "com.guava.ui.app").warning("\(context): none of \(String(describing: candidates)) are supported; using \(String(describing: first))")
                return first
            }
        } catch {
            Logger(label: "com.guava.ui.app").warning("\(context): present mode capability query failed: \(error); falling back to FIFO")
        }

        return .fifo
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
            syncWindowChromeHitTest()
            drawList.reset()
            if useLegacyRenderer {
                nodeRenderer.render(root: root, into: drawList)
            } else {
                layerRenderer.render(tree: graph.renderTree, into: drawList)
            }
        }
        // Explicitly this window's store (we are outside withCurrent here —
        // see the main-window handleFrame for the full invariant).
        session.inputContext.tooltips.drawAll(into: drawList)

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
            format: .bgra8UnormSrgb,
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
