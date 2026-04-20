import Foundation
import GuavaUIRuntime
import GuavaUICompose
import PlatformShell
import RHIWGPU

// MARK: - Root view (compose)

/// Process-wide demo state. The compose graph is rebuilt on the same `RootView`
/// reference each frame; persisting `inputText` outside the struct keeps the
/// `Binding` stable without depending on a `@State` runtime that does not yet
/// exist in GuavaUICompose.
final class DemoState {
    nonisolated(unsafe) static let shared = DemoState()
    var inputText: String = ""
}

struct RootView: View {
    var body: some View {
        Row(spacing: 1) {
            Column(alignment: .leading, spacing: 8) {
                Text("Sidebar", color: Color.white)
                Divider()
                Text("Item A", color: Color(r: 0.85, g: 0.85, b: 0.9))
                Text("Item B", color: Color(r: 0.85, g: 0.85, b: 0.9))
                Text("Item C", color: Color(r: 0.85, g: 0.85, b: 0.9))
                Spacer()
                Button(action: { print("[demo] sidebar button tapped") }) {
                    Text("Click me", color: Color.white)
                        .padding(8)
                        .background(Color(r: 0.30, g: 0.55, b: 0.95))
                }
            }
            .padding(16)
            .frame(width: 220)
            .background(Color(r: 0.16, g: 0.18, b: 0.22))

            Column(alignment: .leading, spacing: 12) {
                Text("GuavaUI — Phase 6.4", color: Color.white)
                Divider()
                Text("Compose -> Yoga -> DrawList -> wgpu",
                     color: Color(r: 0.7, g: 0.85, b: 1.0))
                Text("Button + ScrollView + TextField live",
                     color: Color(r: 0.94, g: 0.94, b: 0.98))

                TextField(
                    "Type here…",
                    text: Binding(
                        get: { DemoState.shared.inputText },
                        set: {
                            DemoState.shared.inputText = $0
                            print("[demo] input → \"\($0)\"")
                        }
                    ),
                    onSubmit: { print("[demo] submit: \(DemoState.shared.inputText)") }
                )
                .padding(8)
                .background(Color(r: 0.20, g: 0.22, b: 0.28))
                .frame(height: 36)

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
                .frame(height: 220)
                .background(Color(r: 0.12, g: 0.14, b: 0.18))

                Spacer()
            }
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

let atlasTextureID: TextureID = 1

TextEnvironmentHolder.current = TextEnvironment(
    atlas: atlas,
    shaper: shaper,
    atlasTextureID: atlasTextureID,
    defaultLineHeight: 22,
    defaultColor: Color.white
)

// MARK: - Compose graph

let tree = NodeTree()
let host = SDL3PlatformHost(title: "GuavaUI — Phase 6.5")
let graph = ViewGraph(tree: tree, recomposer: host.recomposer)
InteractionRegistryHolder.current = host.interactions
FocusChainHolder.current = host.focusChain
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
