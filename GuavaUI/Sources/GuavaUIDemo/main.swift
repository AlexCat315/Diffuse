import Foundation
import GuavaUIRuntime
import GuavaUICompose
import PlatformShell
import RHIWGPU

// MARK: - Root view (compose)

struct RootView: View {
    @State var inputText: String = ""
    @State var clickCount: Int = 0

    var body: some View {
        Box(direction: .row, alignItems: .stretch, spacing: 1) {
            Column(alignment: .leading, spacing: 8) {
                Text("Sidebar", color: Color.white)
                Divider()
                Text("Item A", color: Color(r: 0.85, g: 0.85, b: 0.9))
                Text("Item B", color: Color(r: 0.85, g: 0.85, b: 0.9))
                Text("Item C", color: Color(r: 0.85, g: 0.85, b: 0.9))
                Spacer()
                Button(action: { clickCount += 1 }) {
                    Text("Tapped \(clickCount)x", color: Color.white)
                        .padding(8)
                        .background(Color(r: 0.30, g: 0.55, b: 0.95))
                }
            }
            .padding(16)
            .frame(width: 220)
            .background(Color(r: 0.16, g: 0.18, b: 0.22))

            Column(alignment: .leading, spacing: 12) {
                Text("GuavaUI — Phase 6.6", color: Color.white)
                    .font(.system(size: 28, weight: .bold))
                    .lineHeight(32)
                Divider()
                Text("Compose -> Yoga -> DrawList -> wgpu",
                     color: Color(r: 0.7, g: 0.85, b: 1.0))
                Text("@State + Recomposer reconcile live",
                     color: Color(r: 0.94, g: 0.94, b: 0.98))

                TextField(
                    "Type here…",
                    text: $inputText,
                    onSubmit: { print("[demo] submit: \(inputText)") }
                )
                .padding(8)
                .background(Color(r: 0.20, g: 0.22, b: 0.28))
                .frame(height: 36)

                Text("echo: \(inputText)",
                     color: Color(r: 0.85, g: 0.92, b: 1.0))

                Row(alignment: .top, spacing: 16) {
                    Image(textureID: previewTextureID, width: 112, height: 112)
                        .cornerRadius(24)
                        .foregroundColor(Color(r: 1.0, g: 0.92, b: 0.84, a: 0.92))
                        .opacity(0.92)

                    Column(alignment: .leading, spacing: 6) {
                        Text("Style Preview", color: Color.white)
                            .font(.system(size: 20, weight: .bold))
                            .lineHeight(24)
                        Text("Image + cornerRadius + foregroundColor + opacity",
                             color: Color(r: 0.72, g: 0.79, b: 0.9))
                            .lineHeight(18)
                        Text("font(size: 28, weight: .bold)",
                             color: Color(r: 0.95, g: 0.96, b: 0.98))
                            .font(.system(size: 28, weight: .bold))
                            .lineHeight(32)
                        Text("lineHeight(24) keeps multi-line rhythm stable.",
                             color: Color(r: 0.78, g: 0.84, b: 0.92))
                            .lineHeight(24)
                    }
                    .flex()
                }
                .padding(16)
                .background(Color(r: 0.14, g: 0.17, b: 0.22))

                ScrollView(.vertical) {
                    Column(alignment: .leading, spacing: 6) {
                        Text("Row 0", color: Color.white).frame(height: 40)
                        Text("Row 1", color: Color.white).frame(height: 40)
                        Text("Row 2", color: Color.white).frame(height: 40)
                        Text("Row 3", color: Color.white).frame(height: 40)
                        Text("Row 4", color: Color.white).frame(height: 40)
                        Text("Row 5", color: Color.white).frame(height: 40)
                        Text("Row 6", color: Color.white).frame(height: 40)
                        Text("Row 7", color: Color.white).frame(height: 40)
                        Text("Row 8", color: Color.white).frame(height: 40)
                        Text("Row 9", color: Color.white).frame(height: 40)
                    }
                    .padding(12)
                    .background(Color(r: 0.18, g: 0.22, b: 0.28))
                }
                .flex()
                .background(Color(r: 0.12, g: 0.14, b: 0.18))
            }
            .flex()
            .padding(20)
            .background(Color(r: 0.10, g: 0.11, b: 0.14))

            Column(alignment: .leading, spacing: 6) {
                Text("Inspector", color: Color.white)
                Divider()
                Text("type: Box", color: Color(r: 0.7, g: 0.7, b: 0.75))
                Text("layout: yoga", color: Color(r: 0.7, g: 0.7, b: 0.75))
                Spacer()
            }
            .padding(16)
            .frame(width: 240)
            .background(Color(r: 0.16, g: 0.18, b: 0.22))
        }
        .flex()
    }
}

// MARK: - Text environment (font atlas + shaper bound to primary face)

let provider = FontProvider(size: 18)
provider.loadPrimaryFont(name: "Helvetica Neue")

let atlas = FontAtlas(width: 1024, height: 1024)
atlas.loadFont(path: "/System/Library/Fonts/Helvetica.ttc", size: 18)
provider.registerAllFonts(in: atlas)

let shaper = TextShaper()
if let face = atlas.freetypeFace {
    shaper.setFont(ftFace: face, size: 18)
}
let fontResolver = TextFontResolver(
    primaryFontName: provider.primaryFont?.postScriptName ?? "Helvetica Neue",
    atlas: atlas
)

let atlasTextureID: TextureID = 1
let previewTextureID: TextureID = 2

let previewTexturePixels: [UInt8] = {
    let width = 112
    let height = 112
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            let checker = ((x / 14) + (y / 14)).isMultiple(of: 2)
            let r = UInt8(min(255, 36 + x * 2))
            let g = UInt8(min(255, 74 + y))
            let b = checker ? UInt8(214) : UInt8(112)

            pixels[index + 0] = r
            pixels[index + 1] = g
            pixels[index + 2] = b
            pixels[index + 3] = 255
        }
    }

    return pixels
}()

TextEnvironmentHolder.current = TextEnvironment(
    atlas: atlas,
    shaper: shaper,
    atlasTextureID: atlasTextureID,
    defaultLineHeight: 22,
    defaultColor: Color.white,
    defaultFont: Font.system(size: 18),
    fontResolver: fontResolver
)

// MARK: - Compose graph

let tree = NodeTree()
let host = SDL3PlatformHost(title: "GuavaUI — Phase 6.5")
let graph = ViewGraph(tree: tree, recomposer: host.recomposer)
InteractionRegistryHolder.current = host.interactions
FocusChainHolder.current = host.focusChain
PointerCaptureHolder.current = host.pointerCapture
ClipboardHolder.read  = { SDL3Clipboard.read() }
ClipboardHolder.write = { SDL3Clipboard.write($0) }
graph.install(root: RootView())

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

@MainActor
func uploadAtlas() throws {
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
    try previewTexturePixels.withUnsafeBufferPointer { buf in
        try renderer.registerColorTexture(
            id: previewTextureID,
            pixels: buf.baseAddress!,
            width: 112,
            height: 112
        )
    }
}

host.onInit = { native, w, h in
    drawableW = w; drawableH = h
    do {
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
    guard let surface, let device = backend.rawDevice else { return }
    do {
        try surface.configure(
            device: device, format: .bgra8Unorm,
            width: w, height: h, presentMode: .fifo)
    } catch {
        print("[demo] resize failed: \(error)")
    }
}

host.onFrame = { _ in
    guard configured, let surface, let root = tree.root else { return }

    // 1. Layout against current viewport. Glyphs are rasterised lazily here as
    //    the measure func runs.
    graph.computeLayout(width: Float(drawableW), height: Float(drawableH))

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
            viewportPx: (drawableW, drawableH))
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
