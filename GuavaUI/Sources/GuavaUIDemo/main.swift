import Foundation
import GuavaUIRuntime
import PlatformShell
import RHIWGPU

// MARK: - Text content

let provider = FontProvider(size: 28)
provider.loadPrimaryFont(name: "Helvetica Neue")

let text =
    "Hello, GuavaUI!\n emoji:🦊🍅🦋\n Монгол хэлний шалгалт: Энэ бол Монгол хэлний шалгалт.\n Phase 5 — DrawList + wgpu Renderer\n排版引擎运行中"

let runs = provider.resolveRuns(text: text)
var allGlyphs: [ShapedGlyph] = []
for run in runs {
    allGlyphs.append(contentsOf: provider.shapeRun(run))
}

let atlas = FontAtlas(width: 1024, height: 1024)
provider.registerAllFonts(in: atlas)

let layoutResult = TextLayout.layout(
    shapedGlyphs: allGlyphs,
    text: text,
    atlas: atlas,
    maxWidth: 900,
    lineHeight: 38
)

// MARK: - GPU stack

let backend = WGPUBackend()
try backend.initialize()
let renderer = DrawListRenderer(backend: backend)
let drawList = DrawList()

var surface: GPUSurface?
var configured = false
var drawableW: UInt32 = 0
var drawableH: UInt32 = 0

let atlasTextureID: TextureID = 1

// MARK: - Window

let tree = NodeTree()
let host = SDL3PlatformHost(title: "GuavaUI — Phase 5")

host.onInit = { native, w, h in
    drawableW = w
    drawableH = h
    do {
        surface = try makeSurface(backend: backend, native: native)
        try surface?.configure(
            device: backend.rawDevice!,
            format: .bgra8Unorm,
            width: w, height: h,
            presentMode: .fifo)
        try renderer.configure(format: .bgra8Unorm)
        try atlas.atlasData.withUnsafeBufferPointer { buf in
            try renderer.registerAlphaTexture(
                id: atlasTextureID,
                pixels: buf.baseAddress!,
                width: UInt32(atlas.atlasWidth),
                height: UInt32(atlas.atlasHeight)
            )
        }
        configured = true
    } catch {
        print("[demo] init failed: \(error)")
    }
}

host.onResize = { w, h in
    drawableW = w
    drawableH = h
    guard let surface, let device = backend.rawDevice else { return }
    do {
        try surface.configure(
            device: device,
            format: .bgra8Unorm,
            width: w, height: h,
            presentMode: .fifo)
    } catch {
        print("[demo] resize failed: \(error)")
    }
}

host.onFrame = { _ in
    guard configured, let surface else { return }

    drawList.reset()
    drawList.addRoundedRect(
        UIRect(
            x: 40, y: 40,
            width: Float(drawableW) - 80, height: Float(drawableH) - 80),
        radius: 24,
        color: Color(r: 0.12, g: 0.14, b: 0.18, a: 1.0)
    )
    drawList.addRect(
        UIRect(x: 40, y: 40, width: 6, height: Float(drawableH) - 80),
        color: Color(r: 0.40, g: 0.78, b: 1.00, a: 1.0)
    )
    drawList.addText(
        layoutResult,
        origin: (x: 80, y: 90),
        color: Color(r: 0.94, g: 0.94, b: 0.98, a: 1.0),
        textureID: atlasTextureID
    )

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

// MARK: - Helpers

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
