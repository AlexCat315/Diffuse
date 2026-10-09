import Foundation
import GuavaUIRuntime
import GuavaUICompose
import GuavaUISharedDemo
import GuavaUIGallery
import GuavaUIDevTools
import PlatformShell
import RHIWGPU

enum DemoFrameMode { case idle, benchmark }
enum DemoFrameModeHolder {
    nonisolated(unsafe) static var current: DemoFrameMode = CommandLine.arguments.contains("--benchmark") ? .benchmark : .idle
}
enum DemoVSyncHolder {
    nonisolated(unsafe) static var enabled = !CommandLine.arguments.contains("--no-vsync")
}
let initialGalleryPage: GalleryPage = {
    guard let index = CommandLine.arguments.firstIndex(of: "--component"), CommandLine.arguments.indices.contains(index + 1) else { return .button }
    return GalleryCatalog.page(named: CommandLine.arguments[index + 1]) ?? .button
}()

// MARK: - Compose graph

let demoDevToolsConfig = DevToolsConfig.fromEnvironment(appTitle: "GuavaUI Demo")
let demoDevToolsLogSink: LogTap.Sink?
if let config = demoDevToolsConfig, config.autoInstallLogTap {
    let sink = LogTapInstaller.processSink
    LogTapInstaller.bootstrapIfNeeded(sink: sink)
    demoDevToolsLogSink = sink
} else {
    demoDevToolsLogSink = nil
}

let tree = NodeTree()
let host = SDL3PlatformHost(title: "GuavaUI — Component Showcase")
let sharedCounter = SharedCounterView()
let sharedRecorder = InputRecorder()
let usesSharedCounter = CommandLine.arguments.contains("--shared-counter")
let graph = ViewGraph(tree: tree, recomposer: host.recomposer)
InteractionRegistryHolder.current = host.interactions
FocusChainHolder.current = host.focusChain
PointerCaptureHolder.current = host.pointerCapture
ClipboardHolder.read  = { SDL3Clipboard.read() }
ClipboardHolder.write = { SDL3Clipboard.write($0) }
// MARK: - Text environment (font atlas + shaper bound to primary face)

let atlasTextureID: TextureID = 1
let previewTextureID: TextureID = 2

var atlas: FontAtlas?
var shaper: TextShaper?
var fontResolver: TextFontResolver?
var previewTexturePixels: [UInt8] = []
var previewTextureSize: (width: UInt32, height: UInt32) = (0, 0)
var activeTextScale: Float = 0
var didInstallRoot = false
var didPresentBootClear = false
var demoRenderedFrameCount = 0
var demoFrameAttemptCount = 0
var demoSurfaceWasUnavailable = false
nonisolated(unsafe) var lastHUDSampleTime = ProcessInfo.processInfo.systemUptime
nonisolated(unsafe) var hudTickFrameCount: Int = 0
nonisolated(unsafe) var hudRenderFrameCount: Int = 0
nonisolated(unsafe) var hudTickFPS: Int = 0
nonisolated(unsafe) var hudRenderFPS: Int = 0

let demoBootGlyphSeed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,:;!?+-*/_=()[]{}<>/%@#&'\"`~|\\…●☀︎☾"

func shouldLogMainDemoFrameTiming(frameIndex: Int,
                                  didAtlasUpload: Bool,
                                  didPreviewUpload: Bool) -> Bool {
    frameIndex <= 5 || didAtlasUpload || didPreviewUpload
}

func makePreviewTexturePixels(scale: Float) -> (pixels: [UInt8], width: UInt32, height: UInt32) {
    let logicalWidth: Float = 112
    let logicalHeight: Float = 112
    let physicalWidth = max(1, Int((logicalWidth * scale).rounded(.up)))
    let physicalHeight = max(1, Int((logicalHeight * scale).rounded(.up)))
    let checkerSize = max(1, Int((14 * scale).rounded(.up)))
    var pixels = [UInt8](repeating: 0, count: physicalWidth * physicalHeight * 4)

    for y in 0..<physicalHeight {
        let logicalY = Float(y) / scale
        for x in 0..<physicalWidth {
            let logicalX = Float(x) / scale
            let index = (y * physicalWidth + x) * 4
            let checker = ((x / checkerSize) + (y / checkerSize)).isMultiple(of: 2)
            let r = UInt8(min(255, 36 + Int(logicalX * 2)))
            let g = UInt8(min(255, 74 + Int(logicalY)))
            let b = checker ? UInt8(214) : UInt8(112)

            pixels[index + 0] = r
            pixels[index + 1] = g
            pixels[index + 2] = b
            pixels[index + 3] = 255
        }
    }

    return (pixels, UInt32(physicalWidth), UInt32(physicalHeight))
}

@MainActor
func configureTextEnvironment(scale requestedScale: Float) {
    let scale = requestedScale.isFinite ? max(1, requestedScale) : 1
    ContentScaleHolder.current = scale
    guard atlas == nil || abs(scale - activeTextScale) >= 0.01 else { return }

    activeTextScale = scale

    let atlasEdge = max(1024, Int((1024 * scale).rounded(.up)))
    let environment = TextEnvironment.bootstrapped(
        atlasTextureID: atlasTextureID,
        primaryFontName: SystemFontDefaults.primaryFontName,
        defaultFont: Font.system(size: 18),
        defaultLineHeight: 22,
        defaultColor: .white,
        rasterScale: scale,
        atlasEdge: atlasEdge
    )

    let preview = makePreviewTexturePixels(scale: scale)
    previewTexturePixels = preview.pixels
    previewTextureSize = (preview.width, preview.height)
    atlas = environment.atlas
    shaper = environment.shaper
    fontResolver = environment.fontResolver

    TextEnvironmentHolder.current = environment
}

@MainActor
func prewarmDemoTextGlyphs() {
    guard let env = TextEnvironmentHolder.current else { return }
    let typography = Theme.defaultDark.typography
    env.prewarmGlyphs(text: demoBootGlyphSeed, fonts: [
        env.defaultFont,
        typography.display.font,
        typography.title.font,
        typography.headline.font,
        typography.body.font,
        typography.bodyStrong.font,
        typography.caption.font,
        typography.label.font,
        typography.mono.font,
        Font.system(size: 13, weight: .medium)
    ])
}

// MARK: - GPU stack

let backend = WGPUBackend()
try backend.initialize()
let renderer = DrawListRenderer(backend: backend)
let demoImageAssets = ImageAssetRegistry()
let demoAssetDrops = AssetDropRegistry()
ImageAssetRegistryHolder.current = demoImageAssets
AssetDropRegistryHolder.current = demoAssetDrops
UIWorkSchedulerHolder.enqueue = { [weak host] work in host?.enqueueMainThreadWork(work) }
let drawList = DrawList()
let nodeRenderer = NodeRenderer()
let demoMSAASampleCount: UInt32 = 4

var devTools: DevTools?
if let config = demoDevToolsConfig {
    let tools = DevTools(config: config,
                         tree: tree,
                         invalidationLog: host.invalidationLog,
                         renderTree: graph.renderTree,
                         logSink: demoDevToolsLogSink ?? LogTap.Sink())
    tools.stateRegistry = graph.stateRegistry
    tools.attachFrameTap(backend: backend, renderer: renderer)
    tools.server.hostMainExecutor = { operation in
        host.enqueueMainThreadWork {
            MainActor.assumeIsolated {
                operation()
            }
        }
    }
    if usesSharedCounter {
        tools.stateCheckpointProvider = { sharedCounter.checkpoint }
        tools.stateRestoreResultHandler = { values in sharedCounter.restore(values) }
        tools.inputRecordingStart = {
            guard let session = host.mainSession, !sharedRecorder.isRecording else { return false }
            sharedRecorder.start(state: sharedCounter.checkpoint, focusTarget: session.focusChain.focused?.attachments[LayoutDebugAttachmentKey.debugName] as? String)
            return true
        }
        tools.inputRecordingStop = { sharedRecorder.stop() }
        tools.inputReplay = { recording in
            guard !sharedRecorder.isRecording, recording.isValid, let session = host.mainSession,
                  sharedCounter.restore(recording.initialState) else { return false }
            session.pointerCapture.release()
            session.withCurrent {
                session.recomposer.commitAll()
                graph.computeLayoutIfNeeded(width: Float(session.logicalSize.width), height: Float(session.logicalSize.height))
                func find(_ node: Node, name: String) -> Node? {
                    if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { return node }
                    for child in node.children { if let found = find(child, name: name) { return found } }
                    return nil
                }
                session.focusChain.focus(recording.focusTarget.flatMap { name in tree.root.flatMap { find($0, name: name) } })
                for input in recording.events {
                    session.injectEvent(input.event)
                    session.recomposer.commitAll()
                    graph.computeLayoutIfNeeded(width: Float(session.logicalSize.width), height: Float(session.logicalSize.height))
                }
            }
            session.requestDisplay(); return true
        }
    }
    tools.inputDelivery = { event in
        host.mainSession?.injectEvent(event)
    }
    tools.onMirrorStart = {
        host.requestDisplay()
    }
    tools.onSelectionChanged = {
        host.requestDisplay()
    }
    do {
        try tools.start()
        devTools = tools
    } catch {
        print("[demo] DevTools failed to start: \(error)")
    }
}

var surface: GPUSurface?
var configured = false
var drawableW: UInt32 = 0
var drawableH: UInt32 = 0
var logicalW: UInt32 = 0
var logicalH: UInt32 = 0
var msaaColorTexture: GPUTexture?
var msaaColorView: GPUTextureView?
var msaaTargetSize: (width: UInt32, height: UInt32)?

@MainActor
func appendDevToolsSelectionOverlay(to list: DrawList) {
    devTools?.drawInspectionOverlay(into: list)
}

func demoNodeCount(_ node: Node) -> Int {
    1 + node.children.reduce(0) { $0 + demoNodeCount($1) }
}

@MainActor
func ensureDemoMSAATarget(width: UInt32, height: UInt32) throws {
    guard demoMSAASampleCount > 1 else {
        msaaColorTexture = nil
        msaaColorView = nil
        msaaTargetSize = nil
        return
    }

    if msaaColorTexture != nil,
       msaaColorView != nil,
       msaaTargetSize?.width == width,
       msaaTargetSize?.height == height {
        return
    }

    let texture = try backend.createTexture(
        width: width,
        height: height,
        format: .bgra8Unorm,
        usage: [.renderAttachment],
        mipLevels: 1,
        depthOrLayers: 1,
        sampleCount: demoMSAASampleCount
    )
    let view = try texture.createView()
    msaaColorTexture = texture
    msaaColorView = view
    msaaTargetSize = (width, height)
}

@MainActor
func uploadAtlas() throws {
    guard let atlas else { return }
    try renderer.uploadFontAtlas(atlas, textureID: atlasTextureID)
}

@MainActor
func uploadPreviewTexture() throws {
    guard !previewTexturePixels.isEmpty else { return }
    try previewTexturePixels.withUnsafeBufferPointer { buf in
        try renderer.registerColorTexture(
            id: previewTextureID,
            pixels: buf.baseAddress!,
            width: previewTextureSize.width,
            height: previewTextureSize.height
        )
    }
}

@MainActor
@discardableResult
func presentBootClearFrame() throws -> Bool {
    guard let surface else { return false }
    guard let frame = try surface.getCurrentTextureView() else {
        host.requestDisplay()
        return false
    }
    let encoder = try backend.createCommandEncoder()
    let pass = try encoder.beginRenderPass(
        colorView: frame.view,
        loadOp: .clear,
        storeOp: .store,
        clearColor: GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1)
    )
    pass.end()
    let buffer = try encoder.finish()
    backend.submit(buffer)
    surface.present()
    didPresentBootClear = true
    return true
}

@MainActor
func appendPerformanceHUD(to list: DrawList) {
    guard let env = TextEnvironmentHolder.current else { return }

    let now = ProcessInfo.processInfo.systemUptime
    let delta = max(0, now - lastHUDSampleTime)
    if delta >= 0.25 {
        hudTickFPS = Int((Double(hudTickFrameCount) / delta).rounded())
        hudRenderFPS = Int((Double(hudRenderFrameCount) / delta).rounded())
        hudTickFrameCount = 0
        hudRenderFrameCount = 0
        lastHUDSampleTime = now
    }

    let hudText = "Render FPS \(hudRenderFPS)  Tick FPS \(hudTickFPS)"
    let font = env.resolvedFont(.system(size: 13, weight: .medium))
    let layout = env.cachedLayout(
        text: hudText,
        font: font,
        lineHeight: nil,
        maxWidth: .infinity,
        alignment: .leading
    )

    let panelX: Float = 14
    let panelY: Float = 14
    let paddingX: Float = 10
    let paddingY: Float = 8
    let panelRect = UIRect(
        x: panelX,
        y: panelY,
        width: layout.totalWidth + paddingX * 2,
        height: env.resolvedLineHeight(font: font, override: nil) + paddingY * 2
    )
    list.addRoundedRect(
        panelRect,
        radius: 10,
        color: Color(r: 0.08, g: 0.10, b: 0.13, a: 0.88)
    )
    list.addText(
        layout,
        origin: (panelX + paddingX, panelY + paddingY),
        color: Color(r: 0.90, g: 0.93, b: 0.97, a: 1),
        textureID: env.atlasTextureID,
        atlas: env.atlas
    )
}

host.onInit = { native, w, h in
    host.mainSession?.inputInterceptor = { event in MainActor.assumeIsolated { devTools?.interceptInput(event) ?? false } }
    if usesSharedCounter {
        host.mainSession?.inputObserver = { event in MainActor.assumeIsolated { sharedRecorder.record(event) } }
    }
    drawableW = w; drawableH = h
    logicalW = host.logicalSize.width; logicalH = host.logicalSize.height
    let presentMode: GPUPresentMode = DemoVSyncHolder.enabled ? .fifo : .immediate
    let isVSyncOn = DemoVSyncHolder.enabled
    do {
        var timing = TimingTrace(label: "[timing] demo.boot.main")
        surface = try makeSurface(backend: backend, native: native)
        try surface?.configure(
            device: backend.rawDevice!,
            format: .bgra8Unorm,
            width: w, height: h,
            presentMode: presentMode)
        if !isVSyncOn { native.disableDisplaySync() }
        storedNativeSurface = native
        usedPresentMode = presentMode
        try renderer.configure(format: .bgra8Unorm,
                               sampleCount: demoMSAASampleCount)
        try ensureDemoMSAATarget(width: w, height: h)
        timing.mark("surface")
        if !didPresentBootClear {
            _ = try presentBootClearFrame()
        }
        timing.mark("clearPresent")
        configureTextEnvironment(scale: host.contentScaleFactor)
        timing.mark("textEnvironment")
        prewarmDemoTextGlyphs()
        timing.mark("glyphPrewarm")
        if !didInstallRoot {
            if usesSharedCounter {
                graph.install(root: sharedCounter.compositionLocal(SharedDemoText.painter, { text, list, origin in
                    guard let env = TextEnvironmentHolder.current else { return }
                    let result = env.cachedLayout(text: text.text, font: .system(size: text.size), lineHeight: text.size * 1.3)
                    list.addText(result, origin: (Float(origin.x) + text.inset, Float(origin.y)), color: text.color,
                                 textureID: env.atlasTextureID, atlas: env.atlas)
                }))
            } else { graph.install(root: GalleryView(initialPage: initialGalleryPage)) }
            timing.mark("installRoot")
            graph.computeLayout(width: Float(logicalW), height: Float(logicalH))
            timing.mark("firstLayout")
            didInstallRoot = true
        }
        try uploadAtlas()
        timing.mark("atlasUpload")
        try uploadPreviewTexture()
        timing.mark("previewUpload")
        configured = true
        let firstVisible = didPresentBootClear ? "clearPresent" : "deferred"
        print(timing.summary(extra: ["firstVisible=\(firstVisible)"]))
    } catch {
        print("[demo] init failed: \(error)")
    }
}

host.onResize = { w, h in
    drawableW = w; drawableH = h
    logicalW = host.logicalSize.width; logicalH = host.logicalSize.height
    guard let surface, let device = backend.rawDevice else { return }
    do {
        let presentMode: GPUPresentMode = DemoVSyncHolder.enabled ? .fifo : .immediate
        usedPresentMode = presentMode
        try surface.configure(
            device: device, format: .bgra8Unorm,
            width: w, height: h, presentMode: presentMode)
        try ensureDemoMSAATarget(width: w, height: h)
        let previousScale = activeTextScale
        configureTextEnvironment(scale: host.contentScaleFactor)
        if abs(previousScale - activeTextScale) >= 0.01 {
            try uploadAtlas()
            try uploadPreviewTexture()
        }
    } catch {
        print("[demo] resize failed: \(error)")
    }
}

var usedPresentMode: GPUPresentMode = .fifo
var storedNativeSurface: NativeRenderSurface? = nil

host.onFrame = { native in
    guard configured, let surface, let root = tree.root else { return false }
    let devToolsFrameStart = TimingTrace.now()
    hudTickFrameCount += 1

    // Reconfigure surface if vsync state changed since last frame.
    let desired: GPUPresentMode = DemoVSyncHolder.enabled ? .fifo : .immediate
    if usedPresentMode != desired, let device = backend.rawDevice {
        do {
            try surface.configure(
                device: device, format: .bgra8Unorm,
                width: drawableW, height: drawableH,
                presentMode: desired)
            if !DemoVSyncHolder.enabled {
                storedNativeSurface?.disableDisplaySync()
            }
            usedPresentMode = desired
            print("[demo] vsync changed: presentMode=\(desired) vsync=\(DemoVSyncHolder.enabled)")
        } catch {
            print("[demo] vsync reconfig failed: \(error)")
        }
    }

    var timing = TimingTrace(label: "[timing] demo.frame.main")
    demoFrameAttemptCount += 1
    let nextFrameIndex = demoRenderedFrameCount + 1

    let previousScale = activeTextScale
    configureTextEnvironment(scale: host.contentScaleFactor)
    timing.mark("textEnvironment")
    var didPreviewUpload = false
    if abs(previousScale - activeTextScale) >= 0.01 {
        do {
            try uploadPreviewTexture()
            didPreviewUpload = true
        }
        catch { print("[demo] preview reupload failed: \(error)") }
    }
    timing.mark("previewUpload")

    // 1. Layout against current viewport. Glyphs are rasterised lazily here as
    //    the measure func runs.
    let devToolsLayoutStart = TimingTrace.now()
    let didLayout = graph.computeLayoutIfNeeded(width: Float(logicalW), height: Float(logicalH))
    let devToolsLayoutEnd = TimingTrace.now()
    timing.mark("layout")
    if let session = host.mainSession { NativeAccessibility.synchronize(host: host, session: session, root: root) }

    // 2. Walk node tree -> draw list.
    drawList.reset()
    let drawTrace = tree.timeline.begin()
    nodeRenderer.render(root: root, into: drawList)
    tree.timeline.end(drawTrace, phase: "draw", name: "Encode draw list")
    if CommandLine.arguments.contains("--performance-hud") { appendPerformanceHUD(to: drawList) }
    appendDevToolsSelectionOverlay(to: drawList)
    let devToolsDrawEnd = TimingTrace.now()
    timing.mark("sceneRender")

    var didAtlasUpload = false
    do {
        if atlas?.isDirty == true {
            try uploadAtlas()
            didAtlasUpload = true
        }
    } catch {
        print("[demo] atlas reupload failed: \(error)")
    }
    timing.mark("atlasUpload")

    if let tools = devTools {
        if root.isDirty || root.renderDirty {
            tools.notifyTreeChanged()
        }
    }

    // 3. Submit to wgpu.
    let acquired: (texture: GPUTexture, view: GPUTextureView)?
    do {
        acquired = try surface.getCurrentTextureView()
    } catch {
        print("[demo] surface acquire failed: \(error)")
        return false
    }
    guard let frame = acquired else {
        devTools?.mirrorCapture(
            drawList: drawList,
            widthPx: drawableW,
            heightPx: drawableH,
            logical: (Float(logicalW), Float(logicalH))
        )
        let devToolsFrameEnd = TimingTrace.now()
        devTools?.timing.record(
            layoutMs: (devToolsLayoutEnd - devToolsLayoutStart) * 1_000,
            drawMs: (devToolsDrawEnd - devToolsLayoutEnd) * 1_000,
            presentMs: 0,
            totalMs: (devToolsFrameEnd - devToolsFrameStart) * 1_000,
            nodeCount: demoNodeCount(root),
            batchCount: drawList.batches.count,
            presented: false
        )
        devTools?.notifyFrameFinished()
        if !demoSurfaceWasUnavailable || didAtlasUpload || didPreviewUpload {
            print(timing.summary(extra: [
                "frameAttempt=\(demoFrameAttemptCount)",
                "layoutUpdated=\(didLayout)",
                "atlasUploaded=\(didAtlasUpload)",
                "previewUploaded=\(didPreviewUpload)",
                "retry=surfaceUnavailable",
            ]))
        }
        demoSurfaceWasUnavailable = true
        return false
    }
    timing.mark("acquireSurface")

    do {
        let encoder = try backend.createCommandEncoder()
        // Compare against the allocated target, since onResize has already
        // updated drawableW/drawableH before the target is recreated.
        try ensureDemoMSAATarget(width: drawableW, height: drawableH)
        let passColorView = msaaColorView ?? frame.view
        let passResolveView = msaaColorView == nil ? nil : frame.view
        let pass = try encoder.beginRenderPass(
            colorView: passColorView,
            resolveTargetView: passResolveView,
            loadOp: .clear, storeOp: .store,
            clearColor: GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1)
        )
        try renderer.render(
            list: drawList, pass: pass,
            viewportPx: (drawableW, drawableH),
            coordinateSpace: (Float(logicalW), Float(logicalH)))
        pass.end()
        let buffer = try encoder.finish()
        backend.submit(buffer)
        surface.present()
        let devToolsPresentEnd = TimingTrace.now()
        if let tools = devTools {
            // Acquire and present the primary swapchain image before doing the
            // synchronous mirror readback. Capturing first can starve the
            // swapchain and leave the native window stuck on an older frame.
            tools.mirrorCapture(
                drawList: drawList,
                widthPx: drawableW,
                heightPx: drawableH,
                logical: (Float(logicalW), Float(logicalH))
            )
            if tools.mirrorIsActive {
                host.requestDisplay()
            }
        }
        hudRenderFrameCount += 1
        demoRenderedFrameCount = nextFrameIndex
        timing.mark("gpuSubmit")
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastHUDSampleTime
        if elapsed >= 0.5 {
            hudRenderFPS = Int(Double(hudRenderFrameCount) / elapsed)
            hudTickFPS = Int(Double(hudTickFrameCount) / elapsed)
            lastHUDSampleTime = now
            hudRenderFrameCount = 0
            hudTickFrameCount = 0
        }
        if demoSurfaceWasUnavailable || shouldLogMainDemoFrameTiming(frameIndex: demoRenderedFrameCount,
                                        didAtlasUpload: didAtlasUpload,
                                        didPreviewUpload: didPreviewUpload) {
            print(timing.summary(extra: [
                "frame=\(demoRenderedFrameCount)",
                "surfaceRecovered=\(demoSurfaceWasUnavailable)",
                "layoutUpdated=\(didLayout)",
                "atlasUploaded=\(didAtlasUpload)",
                "previewUploaded=\(didPreviewUpload)",
            ]))
        }
        demoSurfaceWasUnavailable = false
        if let tools = devTools {
            tools.timing.record(
                layoutMs: (devToolsLayoutEnd - devToolsLayoutStart) * 1_000,
                drawMs: (devToolsDrawEnd - devToolsLayoutEnd) * 1_000,
                presentMs: (devToolsPresentEnd - devToolsDrawEnd) * 1_000,
                totalMs: (devToolsPresentEnd - devToolsFrameStart) * 1_000,
                nodeCount: demoNodeCount(root),
                batchCount: drawList.batches.count
            )
            tools.notifyFrameFinished()
        }
        if DemoFrameModeHolder.current == .benchmark || !DemoVSyncHolder.enabled {
            host.requestDisplay()
        }
        return true
    } catch {
        print("[demo] frame submit failed: \(error)")
        return false
    }
}

host.onTeardown = {
    devTools?.stop()
    devTools = nil
}

host.run(tree: tree)

// MARK: - Surface helper

@MainActor
func makeSurface(backend: WGPUBackend, native: NativeRenderSurface) throws -> GPUSurface {
    switch native {
    case .metalLayer(let ptr):
        return try backend.createSurfaceMetal(layer: ptr)
    case .win32Window(let hwnd, let hinstance):
        return try backend.createSurfaceWin32(hwnd: hwnd, hinstance: hinstance)
    case .waylandSurface(let display, let surface):
        return try backend.createSurfaceWayland(display: display, surface: surface)
    case .xlibWindow(let display, let window):
        return try backend.createSurfaceXlib(display: display, window: window)
    }
}
