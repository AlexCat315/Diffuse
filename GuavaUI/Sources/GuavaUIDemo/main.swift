import Foundation
import GuavaUIRuntime
import GuavaUICompose
import PlatformShell
import RHIWGPU

struct DemoSceneNode: Identifiable {
    let id: String
    let title: String
    let children: [DemoSceneNode]
}

struct DemoLogEntry: Identifiable {
    let id: Int
    let level: String
    let message: String
}

let demoSceneTree: [DemoSceneNode] = [
    DemoSceneNode(id: "scene", title: "Scene Root", children: [
        DemoSceneNode(id: "camera", title: "Main Camera", children: []),
        DemoSceneNode(id: "lights", title: "Lights", children: [
            DemoSceneNode(id: "sun", title: "Directional Light", children: []),
            DemoSceneNode(id: "fill", title: "Fill Light", children: [])
        ]),
        DemoSceneNode(id: "props", title: "Props", children: [
            DemoSceneNode(id: "crate", title: "Crate_A", children: []),
            DemoSceneNode(id: "monitor", title: "MonitorWall", children: []),
            DemoSceneNode(id: "console", title: "ConsoleDesk", children: [])
        ])
    ])
]

let demoLogEntries: [DemoLogEntry] = [
    DemoLogEntry(id: 1, level: "INFO", message: "Renderer warmed 1024 atlas glyphs."),
    DemoLogEntry(id: 2, level: "INFO", message: "List and Tree compose components are active in the demo."),
    DemoLogEntry(id: 3, level: "WARN", message: "Rounded clip is still axis-aligned at the subtree level."),
    DemoLogEntry(id: 4, level: "INFO", message: "Scene hierarchy selection now feeds inspector text."),
    DemoLogEntry(id: 5, level: "DEBUG", message: "ScrollView wheel routing drives both components."),
    DemoLogEntry(id: 6, level: "INFO", message: "Phase 7 foundation is ready for SplitView and DockContainer."),
]

func demoLogColor(_ level: String) -> Color {
    switch level {
    case "WARN":
        return Color(r: 1.0, g: 0.78, b: 0.46)
    case "DEBUG":
        return Color(r: 0.62, g: 0.78, b: 1.0)
    default:
        return Color(r: 0.56, g: 0.86, b: 0.62)
    }
}

func demoSceneTitle(id: String?) -> String {
    guard let id else { return "None" }
    return findDemoSceneNode(id: id, in: demoSceneTree)?.title ?? id
}

func findDemoSceneNode(id: String,
                       in nodes: [DemoSceneNode]) -> DemoSceneNode? {
    for node in nodes {
        if node.id == id { return node }
        if let match = findDemoSceneNode(id: id, in: node.children) {
            return match
        }
    }
    return nil
}

// MARK: - Root view (compose)

struct RootView: View {
    @State var inputText: String = ""
    @State var clickCount: Int = 0
    @State var selectedSceneNodeID: String? = "camera"
    @State var selectedLogID: Int? = 2
    @State var appearance: Appearance = .dark

    var body: some View {
        SplitView(.horizontal, fraction: 0.22) {
            Panel("Hierarchy") {
                Column(alignment: .leading, spacing: 0) {
                    Tree(demoSceneTree,
                         children: \.children,
                         selection: $selectedSceneNodeID,
                         rowHeight: 28,
                         rowSpacing: 2) { node, _, _, _ in
                        Text(node.title)
                            .font(.body)
                            .foregroundColor(.onSurface)
                    }
                    .flex()

                    Divider()

                    Row(alignment: .center, spacing: 8) {
                        Button("Refresh \(clickCount)") { clickCount += 1 }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                }
                .flex()
            }
        } second: {
            SplitView(.horizontal, fraction: 0.74) {
                SplitView(.vertical, fraction: 0.68) {
                    Panel("Workspace") {
                        Column(alignment: .leading, spacing: 12) {
                            Text("GuavaUI — Phase 7.5")
                                .font(.display)
                                .foregroundColor(.onBackground)

                            Text("Theme + Style 已落地。这段文字使用 .body + .onSurfaceVariant，外观切换无需重写。")
                                .font(.body)
                                .foregroundColor(.onSurfaceVariant)

                            // Themed input — backgroundColor + cornerRadius
                            // resolve from `node.theme` automatically.
                            TextField(
                                "Type here…",
                                text: $inputText,
                                onSubmit: { print("[demo] submit: \(inputText)") }
                            )
                            .padding(8)
                            .frame(height: 36)

                            Text("echo: \(inputText)")
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)

                            // Button style showcase.
                            Row(alignment: .center, spacing: 8) {
                                Button("Primary") { clickCount += 1 }
                                Button("Secondary") { clickCount += 1 }
                                    .buttonStyle(.secondary)
                                Button("Ghost") { clickCount += 1 }
                                    .buttonStyle(.ghost)
                                Button("Delete", role: .destructive) { clickCount += 1 }
                                Spacer(minLength: 0)
                                Button(appearance == .dark ? "Light" : "Dark") {
                                    appearance = (appearance == .dark) ? .light : .dark
                                }
                                .buttonStyle(.ghost)
                            }

                            Row(alignment: .top, spacing: 16) {
                                Image(textureID: previewTextureID, width: 112, height: 112)
                                    .cornerRadius(24)

                                Column(alignment: .leading, spacing: 6) {
                                    Text("Style Preview")
                                        .font(.title)
                                        .foregroundColor(.onSurface)
                                    Text("Image + cornerRadius + theme tokens, no hard-coded colors.")
                                        .font(.caption)
                                        .foregroundColor(.onSurfaceMuted)
                                }
                                .flex()
                            }
                            .padding(16)
                            .background(.surfaceVariant)
                            .cornerRadius(8)

                            Spacer()
                        }
                    }
                } second: {
                    Panel("Console") {
                        List(demoLogEntries,
                             selection: $selectedLogID,
                             rowHeight: 34,
                             rowSpacing: 2) { entry, _ in
                            Row(alignment: .center, spacing: 10) {
                                Text(entry.level)
                                    .font(.bodyStrong)
                                    .foregroundColor(demoLogColor(entry.level))
                                Text(entry.message)
                                    .font(.body)
                                    .foregroundColor(.onSurface)
                            }
                        }
                        .flex()
                    }
                }
            } second: {
                Panel("Inspector") {
                    Column(alignment: .leading, spacing: 6) {
                        Text("selected: \(demoSceneTitle(id: selectedSceneNodeID))")
                            .font(.bodyStrong)
                            .foregroundColor(.onSurface)
                        Text("type: EntityNode")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                        Text("layout: yoga")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                        Text("console focus: #\(selectedLogID ?? 0)")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                        Spacer().frame(height: 12)
                        Text("Phase 7.5 status")
                            .font(.headline)
                            .foregroundColor(.onSurface)
                        Text("Theme + Style 协议已上线，所有原生组件读取语义槽位 — 切换 appearance 即可整体换肤。")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                        Spacer()
                    }
                }
            }
        }
        .flex()
        .background(.background)
        .appearance(appearance)
        // Phase 8 / Step 9 — when `appearance` flips, every semantic colour
        // resolved against the new theme is interpolated for 0.30 s instead
        // of snapping. Yields a cross-fade across the entire window.
        .animation(.easeInOut(duration: 0.30), value: appearance)
    }
}

// MARK: - Compose graph

let tree = NodeTree()
let host = SDL3PlatformHost(title: "GuavaUI — Phase 7.5")
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
    let scale = max(1, requestedScale)
    guard atlas == nil || abs(scale - activeTextScale) >= 0.01 else { return }

    activeTextScale = scale

    let primaryProvider = FontProvider(size: 18, rasterScale: scale)
    primaryProvider.loadPrimaryFont(name: "Helvetica Neue")

    let atlasEdge = max(1024, Int((1024 * scale).rounded(.up)))
    let newAtlas = FontAtlas(width: atlasEdge, height: atlasEdge)
    newAtlas.loadFont(path: "/System/Library/Fonts/Helvetica.ttc", size: 18, rasterScale: scale)

    let newShaper = TextShaper()
    if let face = newAtlas.freetypeFace {
        newShaper.setFont(ftFace: face, size: 18, rasterScale: scale)
    }

    let newResolver = TextFontResolver(
        primaryFontName: primaryProvider.primaryFont?.postScriptName ?? "Helvetica Neue",
        atlas: newAtlas,
        rasterScale: scale
    )

    let preview = makePreviewTexturePixels(scale: scale)
    previewTexturePixels = preview.pixels
    previewTextureSize = (preview.width, preview.height)
    atlas = newAtlas
    shaper = newShaper
    fontResolver = newResolver

    TextEnvironmentHolder.current = TextEnvironment(
        atlas: newAtlas,
        shaper: newShaper,
        atlasTextureID: atlasTextureID,
        defaultLineHeight: 22,
        defaultColor: Color.white,
        defaultFont: Font.system(size: 18),
        fontResolver: newResolver
    )
}

// MARK: - GPU stack

let backend = WGPUBackend()
try backend.initialize()
let renderer = DrawListRenderer(backend: backend)
let drawList = DrawList()
let nodeRenderer = NodeRenderer()

var surface: GPUSurface?
var configured = false
var drawableW: UInt32 = 0
var drawableH: UInt32 = 0
var logicalW: UInt32 = 0
var logicalH: UInt32 = 0

@MainActor
func uploadAtlas() throws {
    guard let atlas else { return }
    try atlas.atlasData.withUnsafeBufferPointer { buf in
        try renderer.registerAlphaTexture(
            id: atlasTextureID,
            pixels: buf.baseAddress!,
            width: UInt32(atlas.atlasWidth),
            height: UInt32(atlas.atlasHeight)
        )
    }
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

host.onInit = { native, w, h in
    drawableW = w; drawableH = h
    logicalW = host.logicalSize.width; logicalH = host.logicalSize.height
    do {
        configureTextEnvironment(scale: host.contentScaleFactor)
        if !didInstallRoot {
            graph.install(root: RootView())
            didInstallRoot = true
        }
        surface = try makeSurface(backend: backend, native: native)
        try surface?.configure(
            device: backend.rawDevice!,
            format: .bgra8Unorm,
            width: w, height: h,
            presentMode: .fifo)
        try renderer.configure(format: .bgra8Unorm)
        try uploadAtlas()
        try uploadPreviewTexture()
        configured = true
    } catch {
        print("[demo] init failed: \(error)")
    }
}

host.onResize = { w, h in
    drawableW = w; drawableH = h
    logicalW = host.logicalSize.width; logicalH = host.logicalSize.height
    guard let surface, let device = backend.rawDevice else { return }
    do {
        try surface.configure(
            device: device, format: .bgra8Unorm,
            width: w, height: h, presentMode: .fifo)
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

host.onFrame = { _ in
    guard configured, let surface, let root = tree.root else { return }

    let previousScale = activeTextScale
    configureTextEnvironment(scale: host.contentScaleFactor)
    if abs(previousScale - activeTextScale) >= 0.01 {
        do { try uploadPreviewTexture() }
        catch { print("[demo] preview reupload failed: \(error)") }
    }

    // 1. Layout against current viewport. Glyphs are rasterised lazily here as
    //    the measure func runs.
    graph.computeLayout(width: Float(logicalW), height: Float(logicalH))

    // 2. Re-upload atlas in case new glyphs were rasterised this frame.
    do { try uploadAtlas() }
    catch { print("[demo] atlas reupload failed: \(error)") }

    // 3. Walk node tree -> draw list.
    drawList.reset()
    nodeRenderer.render(root: root, into: drawList)

    // 4. Submit to wgpu.
    let acquired: (texture: GPUTexture, view: GPUTextureView)?
    do {
        acquired = try surface.getCurrentTextureView()
    } catch {
        print("[demo] surface acquire failed: \(error)")
        return
    }
    guard let frame = acquired else { return }

    do {
        let encoder = try backend.createCommandEncoder()
        let pass = try encoder.beginRenderPass(
            colorView: frame.view,
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
    } catch {
        print("[demo] frame submit failed: \(error)")
    }
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
