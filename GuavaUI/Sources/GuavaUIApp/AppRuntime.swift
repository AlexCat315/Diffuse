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
/// 单窗口、单 wgpu surface。多窗口 / 卫星窗口走 `DockHostCoordinator` 路线，
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
                                       @ViewBuilder rootView: () -> Root) throws {
        let runtime = AppRuntime(config: config,
                                 backend: backend,
                                 events: events,
                                 onTick: onTick)
        try runtime.start(rootView: rootView())
    }

    // MARK: - Stored state

    private let config: AppConfig
    private let onTick: ((Double) -> Void)?
    private let events: PlatformEventBridge

    private let tree = NodeTree()
    private let host: SDL3PlatformHost
    private let graph: ViewGraph
    private let backend: WGPUBackend
    private let renderer: DrawListRenderer
    private let imageAssets: ImageAssetRegistry
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

    private var drawableW: UInt32 = 0
    private var drawableH: UInt32 = 0
    private var logicalW: UInt32 = 0
    private var logicalH: UInt32 = 0

    private var activeTextScale: Float = 0
    private var atlas: FontAtlas?

    private var didInstallRoot = false
    private var lastFrameTime: Double = 0

    /// 进程内 DevTools 调试服务器。仅当 `config.devTools != nil` 时创建。
    private var devTools: DevTools?
    private var devToolsTickedOnce = false
    private var devToolsFrameCounter: UInt64 = 0

    private init(config: AppConfig,
                 backend: WGPUBackend?,
                 events: PlatformEventBridge,
                 onTick: ((Double) -> Void)?) {
        self.config = config
        self.onTick = onTick
        self.events = events
        let resolvedBackend = backend ?? WGPUBackend(config: config.backendConfig)
        self.backend = resolvedBackend
        self.renderer = DrawListRenderer(backend: resolvedBackend)
        self.imageAssets = ImageAssetRegistry(renderer: renderer)
        self.viewportTextures = ViewportTextureRegistry(renderer: renderer)
        self.host = SDL3PlatformHost(title: config.title)
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
        ViewportTextureBridgeHolder.current = viewportTextures
        ImageAssetRegistryHolder.current = imageAssets
        defer {
            ViewportTextureBridgeHolder.current = previousViewportBridge
            ImageAssetRegistryHolder.current = previousImageAssets
        }

        // 把进程级 holder 接到主窗口的 input context 上，使 Compose 层
        // primitives（Button、TextField、Dock）能直接读到 interaction / focus /
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
        host.onFrame = { [weak self] _ in
            self?.handleFrame() ?? false
        }

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
            presentMode: .fifo
        )
        try renderer.configure(format: .bgra8Unorm,
                               sampleCount: config.msaaSampleCount)
        try ensureMSAATarget(widthPx: widthPx, heightPx: heightPx)
        surface = gpu

        configureTextEnvironment(scale: host.contentScaleFactor)

        if !didInstallRoot {
            graph.install(root: rootView)
            graph.computeLayout(width: Float(logicalW), height: Float(logicalH))
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
            presentMode: .fifo
        )
        try ensureMSAATarget(widthPx: widthPx, heightPx: heightPx)
        configureTextEnvironment(scale: host.contentScaleFactor)
        try uploadAtlasIfNeeded()
    }

    private func handleFrame() -> Bool {
        guard configuredSurface, let surface, let root = tree.root else { return false }

        let frameStart = ProcessInfo.processInfo.systemUptime
        let now = frameStart
        let delta = max(0, now - lastFrameTime)
        lastFrameTime = now
        onTick?(delta)

        configureTextEnvironment(scale: host.contentScaleFactor)
        let layoutStart = ProcessInfo.processInfo.systemUptime
        _ = graph.computeLayoutIfNeeded(width: Float(logicalW), height: Float(logicalH))
        let layoutEnd = ProcessInfo.processInfo.systemUptime

        drawList.reset()
        if useLegacyRenderer {
            nodeRenderer.render(root: root, into: drawList)
        } else {
            layerRenderer.render(tree: graph.renderTree, into: drawList)
        }
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
            return
        }

        if msaaColorTexture != nil,
           msaaColorView != nil,
           drawableW == widthPx,
           drawableH == heightPx {
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
    }
}
