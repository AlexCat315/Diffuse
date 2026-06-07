import Foundation
import GuavaKit
import GuavaUIRuntime
import EngineKernel
import PlatformShell
import RHIWGPU

/// End-to-end GuavaKit host: SDL3 window + wgpu pipeline + GuavaKit runtime,
/// all wired together in one class.
///
/// Usage:
/// ```swift
/// let app = try GuavaKitHostApp(title: "My App")
/// app.run(root: MyRootView())
/// ```
@MainActor
public final class GuavaKitHostApp {
    private let title: String
    private let windowOptions: WindowOptions
    private let session: GuavaKitSession
    private let fontBridge: FontBridge

    private var shell: (any Shell)!
    private var window: (any WindowHandle)!
    private var backend: WGPUBackend!
    private var gpuRenderer: DrawListRenderer!
    private var gpuSurface: GPUSurface?

    private let atlasTextureID: TextureID = 1
    private var isRunning = false

    // MARK: - Init

    public init(title: String = "GuavaKit",
                width: Int32 = 1280,
                height: Int32 = 720) {
        self.title = title
        self.windowOptions = WindowOptions(width: width, height: height)
        self.fontBridge = FontBridge()
        self.session = GuavaKitSession()
    }

    // MARK: - Run

    /// Blocks the calling thread until the window closes. Must be called from
    /// the main actor.
    public func run(root rootView: any View) throws {
        // 1. Create SDL shell + window.
        shell = try makeDefaultShell()
        window = try shell.createWindow(title: title, options: windowOptions)

        // 2. Set up wgpu backend and GPU renderer.
        backend = WGPUBackend(config: WGPUDeviceConfig())
        try backend.initialize()
        gpuRenderer = DrawListRenderer(backend: backend)

        // 3. Create GPU surface from the native window.
        try createGPUSurface()

        // 4. Configure renderer pipeline.
        try gpuRenderer.configure(format: .bgra8UnormSrgb)

        // 5. Prime the atlas texture slot.
        try primeAtlasTexture()

        // 6. Load a system font.
        loadSystemFont()

        // 7. Wire GuavaKit session.
        session.textMeasurer = FontBridgeMeasurer(bridge: fontBridge)
        session.renderer = GuavaKitHost.DisplayListRenderer(
            fontBridge: fontBridge, atlasTextureID: atlasTextureID
        )
        session.install(root: rootView)

        // 8. Frame loop.
        isRunning = true
        while isRunning && shell.isRunning {
            // 8a. Feed platform events into GuavaKit.
            for routed in shell.pollWindowEvents() {
                guard routed.windowID == window.id else { continue }
                feedEvent(routed.event)
            }

            // 8b. Tick the GuavaKit pipeline.
            let logical = window.logicalSize
            let available = Size(width: Float(logical.width), height: Float(logical.height))

            if let drawList = session.tick(available: available) {
                try uploadAtlasIfNeeded()
                try renderDrawList(drawList)
            } else {
                try uploadAtlasIfNeeded()
            }
        }
    }

    public func stop() { isRunning = false }

    // MARK: - GPU setup

    private func createGPUSurface() throws {
        guard let native = window.renderSurface else {
            throw GuavaKitHostError.noRenderSurface
        }
        let surface: GPUSurface
        switch native {
        case .metalLayer(let ptr):
            surface = try backend.createSurfaceMetal(layer: ptr)
        case .win32Window(let hwnd, let hinstance):
            surface = try backend.createSurfaceWin32(hwnd: hwnd, hinstance: hinstance)
        case .waylandSurface(let display, let surfPtr):
            surface = try backend.createSurfaceWayland(display: display, surface: surfPtr)
        case .xlibWindow(let display, let xWindow):
            surface = try backend.createSurfaceXlib(display: display, window: xWindow)
        }
        let drawable = window.drawableSize
        guard let device = backend.rawDevice else {
            throw GuavaKitHostError.noDevice
        }
        try surface.configure(device: device, format: .bgra8Unorm,
                              width: drawable.width, height: drawable.height)
        self.gpuSurface = surface
    }

    private func primeAtlasTexture() throws {
        let atlasEdge = UInt32(fontBridge.atlas.atlasWidth)
        let blank = [UInt8](repeating: 0, count: Int(atlasEdge * atlasEdge))
        try blank.withUnsafeBufferPointer { buf in
            try gpuRenderer.registerAlphaTexture(
                id: atlasTextureID,
                pixels: buf.baseAddress!,
                width: atlasEdge,
                height: atlasEdge
            )
        }
    }

    // MARK: - Font

    private func loadSystemFont() {
        let paths = [
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
        ]
        for path in paths {
            if fontBridge.loadFont(path: path, size: 16) { return }
        }
    }

    // MARK: - Atlas upload

    private func uploadAtlasIfNeeded() throws {
        let atlas = fontBridge.atlas
        guard atlas.isDirty, let payload = atlas.dirtyUploadPayload() else { return }
        try payload.pixels.withUnsafeBufferPointer { buf in
            try gpuRenderer.registerAlphaTexture(
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

    // MARK: - GPU submission

    private func renderDrawList(_ list: DrawList) throws {
        guard let surface = gpuSurface, let backend else { return }

        let drawable = window.drawableSize
        let logical = window.logicalSize
        let viewportPx = (drawable.width, drawable.height)

        // Reconfigure surface if drawable size changed.
        if let device = backend.rawDevice {
            try surface.configure(device: device, format: .bgra8Unorm,
                                  width: drawable.width, height: drawable.height)
        }

        // Acquire the next swapchain image.
        guard let frame = try surface.getCurrentTextureView() else { return }

        let encoder = try backend.createCommandEncoder()
        let pass = try encoder.beginRenderPass(
            colorView: frame.view,
            resolveTargetView: nil,
            loadOp: .clear,
            storeOp: .store,
            clearColor: GPUColor(r: 0, g: 0, b: 0, a: 1)
        )
        try gpuRenderer.render(
            list: list,
            pass: pass,
            viewportPx: viewportPx,
            coordinateSpace: (Float(logical.width), Float(logical.height))
        )
        pass.end()
        let buffer = try encoder.finish()
        backend.submit(buffer)
        surface.present()
    }

    // MARK: - Event translation

    private func feedEvent(_ event: InputEvent) {
        switch event {
        case .mouseButtonDown(let e):
            session.eventAdapter.pointerDown(
                at: Point(x: e.x, y: e.y),
                button: mapButton(e.button)
            )
        case .mouseButtonUp(let e):
            session.eventAdapter.pointerUp(
                at: Point(x: e.x, y: e.y),
                button: mapButton(e.button)
            )
        case .mouseMotion(let e):
            session.eventAdapter.pointerMove(to: Point(x: e.x, y: e.y))
        default:
            break
        }
    }

    private func mapButton(_ b: MouseButton) -> PointerButton {
        switch b {
        case .left:   return .primary
        case .right:  return .secondary
        case .middle: return .middle
        default:      return .primary
        }
    }
}

// MARK: - Errors

enum GuavaKitHostError: Error {
    case noRenderSurface
    case noDevice
}
