import Foundation
import GuavaUIRuntime
import GuavaUICompose
import GuavaUISharedDemo
import GuavaUIGallery
import GuavaUIDevTools
import PlatformShell
import NativeRHI

enum DemoFrameMode { case idle, benchmark }
enum DemoFrameModeHolder {
    nonisolated(unsafe) static var current: DemoFrameMode = CommandLine.arguments.contains("--benchmark") ? .benchmark : .idle
}
enum DemoVSyncHolder {
    nonisolated(unsafe) static var enabled = !CommandLine.arguments.contains("--no-vsync")
}
let initialGalleryPage: GalleryPage = {
    guard let index = CommandLine.arguments.firstIndex(of: "--component"), CommandLine.arguments.indices.contains(index + 1) else { return .introduction }
    return GalleryCatalog.page(named: CommandLine.arguments[index + 1]) ?? .introduction
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
/// Timestamp of the previous submitted frame, for the cadence diagnostic below.
nonisolated(unsafe) var lastFrameSubmitTime = TimingTrace.now()
nonisolated(unsafe) var hudTickFrameCount: Int = 0
nonisolated(unsafe) var hudRenderFrameCount: Int = 0
nonisolated(unsafe) var hudTickFPS: Int = 0
nonisolated(unsafe) var hudRenderFPS: Int = 0

let demoBootGlyphSeed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,:;!?+-*/_=()[]{}<>/%@#&'\"`~|\\…●☀︎☾"

func shouldLogMainDemoFrameTiming(frameIndex: Int,
                                  didAtlasUpload: Bool,
                                  didPreviewUpload: Bool) -> Bool {
    frameIndex <= 5 || didAtlasUpload || didPreviewUpload
        || (DemoFrameModeHolder.current == .benchmark && frameIndex.isMultiple(of: 60))
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

// NativeRHI: the demo is where the frost is looked at, and
// the backdrop pass that blurs what is behind a panel only exists here.
let device = try Device.make(DeviceConfig(
    preferredBackends: NativeRHI.platformDefaultBackends,
    enableValidation: true,
    framesInFlight: 3))
let renderer = try device.withFrameSession { try NativeDrawListRenderer(device: device) }
let demoImageAssets = ImageAssetRegistry()
let demoAssetDrops = AssetDropRegistry()
ImageAssetRegistryHolder.current = demoImageAssets
AssetDropRegistryHolder.current = demoAssetDrops
UIWorkSchedulerHolder.enqueue = { [weak host] work in host?.enqueueMainThreadWork(work) }
let drawList = DrawList()
let nodeRenderer = NodeRenderer()
let layerRenderer = LayerAwareNodeRenderer()
let useLegacyRenderer = ProcessInfo.processInfo.environment["GUAVAUI_LEGACY_RENDERER"] == "1"
let demoMSAASampleCount: UInt32 = 4

var devTools: DevTools?
if let config = demoDevToolsConfig {
    let tools = DevTools(config: config,
                         tree: tree,
                         invalidationLog: host.invalidationLog,
                         renderTree: graph.renderTree,
                         logSink: demoDevToolsLogSink ?? LogTap.Sink())
    tools.stateRegistry = graph.stateRegistry
    do {
        let capture = try NativeAppFrameCapture(device: device, renderer: renderer)
        tools.attachFrameTap(capture: { list, width, height, logical in
            try capture.capture(list: list, size: SIMD2(Int(width), Int(height)),
                logical: SIMD2(logical.width, logical.height))
        }, reset: { capture.reset() })
    } catch {
        print("[demo] frame tap unavailable: \(error)")
    }
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

var swapchain: SwapchainResource?
var surfaceNative: NativeRenderSurface?
var surfaceVSync = DemoVSyncHolder.enabled
var configured = false
var drawableW: UInt32 = 0
var drawableH: UInt32 = 0
var logicalW: UInt32 = 0
var logicalH: UInt32 = 0
var multisample: TextureResource?
/// Owned copy of the presented frame, so a panel can blur it.
var framebuffer: TextureResource?

@MainActor
func appendDevToolsSelectionOverlay(to list: DrawList) {
    devTools?.drawInspectionOverlay(into: list)
}

func demoNodeCount(_ node: Node) -> Int {
    1 + node.children.reduce(0) { $0 + demoNodeCount($1) }
}

@MainActor
func uploadAtlas() throws {
    guard let atlas else { return }
    try device.withFrameSession { try renderer.uploadFontAtlas(atlas, textureID: atlasTextureID) }
}

@MainActor
func uploadPreviewTexture() throws {
    guard !previewTexturePixels.isEmpty else { return }
    let width = Int(previewTextureSize.width)
    let height = Int(previewTextureSize.height)
    try device.withFrameSession {
        var region = TextureUploadRegion(width: width, height: height)
        region.origin = .zero
        try renderer.registerTexture(id: previewTextureID, pixels: Data(previewTexturePixels),
            size: SIMD2(width, height), region: region, format: .rgba8Unorm)
    }
}

@MainActor
@discardableResult
func presentBootClearFrame() throws -> Bool {
    guard let resource = swapchain, drawableW > 0, drawableH > 0 else { return false }
    try device.withFrameSession {
        try device.beginFrame()
        defer { device.endFrame() }
        let image = try device.acquireSwapchainImage(resource.swapchain)
        let commands = CommandBuffer()
        let frame = try renderer.record(list: DrawList(), into: commands,
            target: RenderColorTarget(texture: image.texture,
                loadAction: .clear(SIMD4<Float>(0.05, 0.06, 0.08, 1)), store: true),
            viewport: NativeUIViewport(pixels: SIMD2(Int(image.width), Int(image.height)),
                logical: SIMD2(Float(logicalW), Float(logicalH))))
        try device.submit(commands)
        frame.didSubmit()
        try device.present(image)
    }
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
    let isVSyncOn = DemoVSyncHolder.enabled
    do {
        var timing = TimingTrace(label: "[timing] demo.boot.main")
        swapchain = try device.withFrameSession {
            try SwapchainResource(device: device, descriptor: SurfaceFactory.nativeDescriptor(
                native: native, size: SIMD2(w, h), vsync: isVSyncOn))
        }
        surfaceNative = native
        surfaceVSync = isVSyncOn
        try device.withFrameSession {
            try renderer.configure(format: .bgra8UnormSRGB, sampleCount: Int(demoMSAASampleCount))
        }
        // Without the backdrop program there is no frost, and the panels are
        // just translucent — worth knowing which one is on screen.
        print("[demo] NativeRHI ready: frost=\(renderer.supportsBackdrop) msaa=\(demoMSAASampleCount)x")
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
    guard let resource = swapchain, let native = surfaceNative else { return }
    do {
        let isVSyncOn = DemoVSyncHolder.enabled
        try device.withFrameSession {
            // Minimized windows have no drawable extent; keep the current pool
            // and reconfigure once a positive size comes back.
            guard w > 0 && h > 0 else { return }
            try device.configureSwapchain(resource.swapchain,
                descriptor: SurfaceFactory.nativeDescriptor(native: native, size: SIMD2(w, h), vsync: isVSyncOn))
        }
        surfaceVSync = isVSyncOn
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

host.onFrame = { native in
    surfaceNative = native
    guard configured, swapchain != nil, let root = tree.root else { return false }
    let devToolsFrameStart = TimingTrace.now()
    hudTickFrameCount += 1

    // Reconfigure the swapchain if vsync state changed since last frame.
    if surfaceVSync != DemoVSyncHolder.enabled, let resource = swapchain {
        do {
            try device.withFrameSession {
                try device.configureSwapchain(resource.swapchain,
                    descriptor: SurfaceFactory.nativeDescriptor(native: native,
                        size: SIMD2(drawableW, drawableH), vsync: DemoVSyncHolder.enabled))
            }
            surfaceVSync = DemoVSyncHolder.enabled
            print("[demo] vsync changed: vsync=\(DemoVSyncHolder.enabled)")
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
    // Snapping happens as edges are emitted, so the scale has to be known here
    // rather than at record time.
    drawList.pixelScale = Float(host.contentScaleFactor)
    let drawTrace = tree.timeline.begin()
    if useLegacyRenderer {
        nodeRenderer.render(root: root, into: drawList)
    } else {
        layerRenderer.render(tree: graph.renderTree, into: drawList)
    }
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

    // 3. Record and submit. These are CPU wall times, including any wait for a
    // frame slot or drawable; GPU execution proceeds asynchronously.
    var presented = false
    var devToolsPresentEnd = devToolsDrawEnd
    do {
        presented = try submitDemoFrame(timing: &timing)
        devToolsPresentEnd = TimingTrace.now()
    } catch {
        print("[demo] frame submit failed: \(error)")
    }
    // Log slow frame work, rather than interpreting an event-driven window's
    // idle time between input events as a missed display deadline. The interval
    // remains useful context, but includes intentional time asleep in SDL.
    let submitNow = TimingTrace.now()
    let frameInterval = submitNow - lastFrameSubmitTime
    lastFrameSubmitTime = submitNow
    if submitNow - devToolsFrameStart > 0.025, demoRenderedFrameCount > 5 {
        print(timing.summary(extra: [
            "interval=\(String(format: "%.1f", frameInterval * 1000))ms",
        ]))
    }

    if let tools = devTools {
        // Recorded after presenting the primary swapchain image: capturing
        // first can starve the swapchain and leave the window on an older frame.
        tools.mirrorCapture(
            drawList: drawList,
            widthPx: drawableW,
            heightPx: drawableH,
            logical: (Float(logicalW), Float(logicalH))
        )
        if tools.mirrorIsActive {
            host.requestDisplay()
        }
        tools.timing.record(
            layoutMs: (devToolsLayoutEnd - devToolsLayoutStart) * 1_000,
            drawMs: (devToolsDrawEnd - devToolsLayoutEnd) * 1_000,
            presentMs: (devToolsPresentEnd - devToolsDrawEnd) * 1_000,
            totalMs: (devToolsPresentEnd - devToolsFrameStart) * 1_000,
            nodeCount: demoNodeCount(root),
            batchCount: drawList.batches.count,
            presented: presented
        )
        tools.notifyFrameFinished()
    }

    guard presented else {
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

    hudRenderFrameCount += 1
    demoRenderedFrameCount = nextFrameIndex
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
            "vertices=\(drawList.vertices.count)",
            "indices=\(drawList.indices.count)",
            "batches=\(drawList.batches.count)",
            "interval=\(String(format: "%.1f", frameInterval * 1000))ms",
        ]))
    }
    demoSurfaceWasUnavailable = false
    // Presentation synchronization does not choose whether an idle UI redraws.
    // Continuous rendering is an explicit benchmark mode.
    if DemoFrameModeHolder.current == .benchmark {
        host.requestDisplay()
    }
    return true
}

host.onTeardown = {
    devTools?.stop()
    devTools = nil
}

host.run(tree: tree)

// MARK: - Frame submission

/// Renders the recorded draw list into the swapchain. Returns false while the
/// window has no drawable to present to.
@MainActor
func submitDemoFrame(timing: inout TimingTrace) throws -> Bool {
    guard let resource = swapchain else { return false }
    return try device.withFrameSession { () throws -> Bool in
        try device.beginFrame()
        timing.mark("frameSlot")
        defer {
            device.endFrame()
            timing.mark("frameEnd")
        }
        let image = try device.acquireSwapchainImage(resource.swapchain)
        timing.mark("drawableAcquire")
        let pixels = SIMD2(image.width, image.height)
        if demoMSAASampleCount > 1,
           multisample?.descriptor.width != pixels.x || multisample?.descriptor.height != pixels.y {
            var descriptor = TextureDescriptor(width: pixels.x, height: pixels.y,
                format: .bgra8UnormSRGB, usage: [.colorTarget])
            descriptor.sampleCount = Int(demoMSAASampleCount)
            multisample = try TextureResource(device: device, descriptor: descriptor)
        }
        // With frost the frame goes into an owned texture instead of straight
        // into the drawable: a panel samples what is already behind it, and a
        // swapchain image is a render target that cannot be sampled. Only pay
        // for that texture — and the blit that follows — on frames that really
        // have a panel doing the sampling; the rest go straight to the drawable.
        let frosted = renderer.supportsBackdrop
            && drawList.batches.contains(where: { $0.backdrop != nil })
        if !frosted {
            framebuffer = nil
        } else if framebuffer?.descriptor.width != pixels.x || framebuffer?.descriptor.height != pixels.y {
            framebuffer = try TextureResource(device: device, descriptor: TextureDescriptor(
                width: pixels.x, height: pixels.y, format: .bgra8UnormSRGB,
                usage: [.colorTarget, .sampled], label: "demo-framebuffer"))
        }
        let surface = framebuffer?.texture ?? image.texture
        var target = RenderColorTarget(texture: multisample?.texture ?? surface,
            loadAction: .clear(SIMD4<Float>(0.05, 0.06, 0.08, 1)))
        target.resolveTexture = multisample == nil ? nil : surface
        let commands = CommandBuffer()
        timing.mark("renderTargets")
        let frame = try renderer.record(list: drawList, into: commands, target: target,
            viewport: NativeUIViewport(pixels: pixels, logical: SIMD2(Float(logicalW), Float(logicalH))),
            backdropSource: framebuffer?.texture)
        if let source = framebuffer?.texture {
            let present = RenderColorTarget(texture: image.texture, loadAction: .dontCare, store: true)
            try renderer.recordBlit(source: source, into: commands, target: present, size: pixels)
        }
        timing.mark("commandRecord")
        try device.submit(commands)
        timing.mark("queueSubmit")
        frame.didSubmit()
        try device.present(image)
        timing.mark("present")
        return true
    }
}
