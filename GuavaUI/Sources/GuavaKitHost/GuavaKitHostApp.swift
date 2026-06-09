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
    private var textInputActive = false

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

        // 4. Configure renderer pipeline. Must match the surface format
        // (`.bgra8Unorm`, set in createGPUSurface/renderDrawList) or wgpu rejects
        // the command buffer — the colour attachment formats have to be identical.
        try gpuRenderer.configure(format: .bgra8Unorm)

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
        var lastDrawList: DrawList?
        while isRunning && shell.isRunning {
            // 8a. Feed platform events into GuavaKit.
            for routed in shell.pollWindowEvents() {
                guard routed.windowID == window.id else { continue }
                feedEvent(routed.event)
            }

            // 8b. Tick the GuavaKit pipeline.
            let logical = window.logicalSize
            let available = Size(width: Float(logical.width), height: Float(logical.height))

            // The installed app fills the window: pin the root container to the
            // viewport and stretch its child across the cross axis. (The root view
            // fills the main axis itself via `.flex`.) `modifyLayout` no-ops when
            // unchanged, so this only re-lays-out on resize.
            session.viewGraph.root.modifyLayout {
                $0.width = .points(available.width)
                $0.height = .points(available.height)
                $0.alignItems = .stretch
            }

            // The CPU pipeline (recompose/layout/paint) only re-runs when state is
            // dirty — but the GPU must present *every* frame, otherwise the
            // swapchain rotates to buffers we never drew and the window goes black.
            // Cache the latest list and re-present it on otherwise-clean frames.
            if let drawList = session.tick(available: available) {
                lastDrawList = drawList
            }
            try uploadAtlasIfNeeded()
            if let drawList = lastDrawList {
                try renderDrawList(drawList)
            }

            // 8c. Keep SDL text input (IME) in sync with keyboard focus.
            syncTextInputArea()
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
        case .keyDown(let e):
            // Control/navigation keys. Printable input arrives via `.textInput`.
            session.eventAdapter.keyDown(KeyboardEvent(
                key: Self.keyName(for: e.keycode),
                isRepeat: e.isRepeat,
                modifiers: Self.mapModifiers(e)
            ))
        case .textInput(let text):
            // IME-composed text (printable characters, CJK, pasted runs).
            session.eventAdapter.keyDown(KeyboardEvent(key: "", character: text))
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

    // MARK: - Keyboard translation

    /// Maps an SDL3 keycode to GuavaKit's platform-independent key name. Only the
    /// control/navigation keys need names — printable characters arrive separately
    /// via `.textInput` (already IME-composed), so they're not mapped here.
    private static func keyName(for keycode: UInt32) -> String {
        switch keycode {
        case 13, 0x4000_0058: return "Enter"        // Return / keypad Enter
        case 27:              return "Escape"
        case 8:               return "Backspace"
        case 127:             return "Delete"
        case 9:               return "Tab"
        case 0x4000_004F:     return "ArrowRight"
        case 0x4000_0050:     return "ArrowLeft"
        case 0x4000_0051:     return "ArrowDown"
        case 0x4000_0052:     return "ArrowUp"
        case 0x4000_004A:     return "Home"
        case 0x4000_004D:     return "End"
        default:              return ""
        }
    }

    /// `KeyEvent.modifiers` is `EngineKernel.KeyModifiers`; we read it via the
    /// event so its type is inferred (the module name `EngineKernel` collides
    /// with the protocol of the same name and can't be used as a qualifier).
    private static func mapModifiers(_ event: KeyEvent) -> GuavaKit.KeyModifiers {
        let m = event.modifiers
        var out: GuavaKit.KeyModifiers = []
        if m.contains(.lshift) || m.contains(.rshift) { out.insert(.shift) }
        if m.contains(.lctrl)  || m.contains(.rctrl)  { out.insert(.control) }
        if m.contains(.lalt)   || m.contains(.ralt)   { out.insert(.alt) }
        if m.contains(.lgui)   || m.contains(.rgui)   { out.insert(.command) }
        return out
    }

    // MARK: - Text input (IME) follows keyboard focus

    /// Drives SDL text input from GuavaKit's focus state: enabled while a node
    /// holds keyboard focus (so `.textInput` events flow and the IME candidate
    /// window anchors to the field), disabled when focus clears.
    private func syncTextInputArea() {
        if let node = session.context.focusedNode {
            var x = node.geometry.frame.minX
            var y = node.geometry.frame.minY
            var ancestor = node.parent
            while let p = ancestor {
                x += p.geometry.frame.minX
                y += p.geometry.frame.minY
                ancestor = p.parent
            }
            let size = node.geometry.frame.size
            shell.setTextInputArea(windowID: window.id, TextInputArea(
                x: x, y: y, width: size.width, height: size.height, cursorX: x))
            textInputActive = true
        } else if textInputActive {
            shell.setTextInputArea(windowID: window.id, nil)
            textInputActive = false
        }
    }
}

// MARK: - Errors

enum GuavaKitHostError: Error {
    case noRenderSurface
    case noDevice
}
