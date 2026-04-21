import CSDL3
import EngineKernel
import Foundation
import Logging

#if os(macOS)
import QuartzCore
#endif

@MainActor
public final class SDL3Shell: Shell {
    private let initialWidth: Int32
    private let initialHeight: Int32
    private var window: OpaquePointer?
    private var metalView: UnsafeMutableRawPointer?
    private var didInitializeSDL = false
    private var lastTextInputArea: TextInputArea?

#if os(macOS)
    private var metalLayer: CAMetalLayer?
#endif

    public private(set) var isRunning = true
    public private(set) var isFocused = true
    public private(set) var isMinimized = false
    public private(set) var isOccluded = false

    public init(width: Int32 = 1280, height: Int32 = 720) throws {
        self.initialWidth = width
        self.initialHeight = height
    }

    public var renderSurface: NativeRenderSurface? {
#if os(macOS)
        guard let metalLayer else { return nil }
        return .metalLayer(Unmanaged.passUnretained(metalLayer).toOpaque())
#elseif os(Windows)
        guard let hwnd = pointerWindowProperty(named: "SDL.window.win32.hwnd") else { return nil }
        let hinstance = pointerWindowProperty(named: "SDL.window.win32.instance")
        return .win32Window(hwnd: hwnd, hinstance: hinstance)
#elseif os(Linux)
        if let display = pointerWindowProperty(named: "SDL.window.wayland.display"),
           let surface = pointerWindowProperty(named: "SDL.window.wayland.surface") {
            return .waylandSurface(display: display, surface: surface)
        }

        if let display = pointerWindowProperty(named: "SDL.window.x11.display") {
            let windowNumber = numberWindowProperty(named: "SDL.window.x11.window")
            if windowNumber > 0 {
                return .xlibWindow(display: display, window: UInt64(windowNumber))
            }
        }

        return nil
#else
        return nil
#endif
    }

    public var drawableSize: (width: UInt32, height: UInt32) {
        guard let window else { return (1, 1) }

        var width: Int32 = 1
        var height: Int32 = 1
        if SDL_GetWindowSizeInPixels(window, &width, &height) {
            return (UInt32(max(1, width)), UInt32(max(1, height)))
        }

        return (1, 1)
    }

    public var logicalSize: (width: UInt32, height: UInt32) {
        guard let window else { return (1, 1) }

        var width: Int32 = 1
        var height: Int32 = 1
        _ = SDL_GetWindowSize(window, &width, &height)
        return (UInt32(max(1, width)), UInt32(max(1, height)))
    }

    public func initializeWindow(title: String) throws {
        if window != nil {
            return
        }

        guard SDL_Init(SDL_INIT_VIDEO) else {
            throw ShellError.initializationFailed(Self.lastSDLError())
        }
        didInitializeSDL = true
        isRunning = true

#if os(macOS)
    let windowFlags = SDL_WindowFlags(
        GUAVA_SDL_WINDOW_RESIZABLE | GUAVA_SDL_WINDOW_HIGH_PIXEL_DENSITY | GUAVA_SDL_WINDOW_METAL)
#else
    let windowFlags = SDL_WindowFlags(
        GUAVA_SDL_WINDOW_RESIZABLE | GUAVA_SDL_WINDOW_HIGH_PIXEL_DENSITY)
#endif

        let createdWindow = title.withCString { rawTitle in
            SDL_CreateWindow(rawTitle, initialWidth, initialHeight, windowFlags)
        }
        guard let createdWindow else {
            shutdown()
            throw ShellError.initializationFailed(Self.lastSDLError())
        }
        window = createdWindow

#if os(macOS)
        guard let createdMetalView = SDL_Metal_CreateView(createdWindow) else {
            shutdown()
            throw ShellError.initializationFailed(Self.lastSDLError())
        }
        metalView = createdMetalView

        guard let layerPointer = SDL_Metal_GetLayer(createdMetalView) else {
            shutdown()
            throw ShellError.initializationFailed("SDL_Metal_GetLayer returned null")
        }

        let metalLayer = Unmanaged<CAMetalLayer>.fromOpaque(layerPointer).takeUnretainedValue()
        self.metalLayer = metalLayer
        configureMetalLayer(metalLayer)
#endif

        syncDrawableSize()
        // Always-on text input: TextField primitives rely on
        // `SDL_EVENT_TEXT_INPUT` for IME-aware character entry.
        SDL_StartTextInput(createdWindow)
        let sz = "\(drawableSize.width)x\(drawableSize.height)"
        Logger.platform.info("SDL3 window ready, drawable=\(sz)")
    }

    @discardableResult
    public func pollEvents() -> [InputEvent] {
        guard window != nil else { return [] }

        var collected: [InputEvent] = []
        var event = SDL_Event()

        while SDL_PollEvent(&event) {
            let eventType = event.type

            switch eventType {
            // ── Quit / close ──
            case UInt32(GUAVA_SDL_EVENT_QUIT),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_CLOSE_REQUESTED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_DESTROYED):
                isRunning = false

            // ── Window geometry ──
            case UInt32(GUAVA_SDL_EVENT_WINDOW_RESIZED):
                syncDrawableSize()
                collected.append(.windowResized(
                    width: event.window.data1,
                    height: event.window.data2))

            case UInt32(GUAVA_SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED):
                syncDrawableSize()
                collected.append(.windowPixelSizeChanged(
                    width: event.window.data1,
                    height: event.window.data2))

            case UInt32(GUAVA_SDL_EVENT_WINDOW_METAL_VIEW_RESIZED):
                syncDrawableSize()

            // ── Window focus ──
            case UInt32(GUAVA_SDL_EVENT_WINDOW_FOCUS_GAINED):
                isFocused = true
                collected.append(.windowFocusGained)

            case UInt32(GUAVA_SDL_EVENT_WINDOW_FOCUS_LOST):
                isFocused = false
                collected.append(.windowFocusLost)

            // ── Minimize / restore ──
            case UInt32(GUAVA_SDL_EVENT_WINDOW_MINIMIZED):
                isMinimized = true
                collected.append(.windowMinimized)

            case UInt32(GUAVA_SDL_EVENT_WINDOW_RESTORED):
                isMinimized = false
                collected.append(.windowRestored)

            // ── Occluded / exposed ──
            case UInt32(GUAVA_SDL_EVENT_WINDOW_OCCLUDED):
                isOccluded = true
                collected.append(.windowOccluded)

            case UInt32(GUAVA_SDL_EVENT_WINDOW_EXPOSED):
                isOccluded = false
                collected.append(.windowExposed)

            // ── Keyboard ──
            case UInt32(GUAVA_SDL_EVENT_KEY_DOWN):
                let ke = makeKeyEvent(from: event)
                collected.append(.keyDown(ke))

            case UInt32(GUAVA_SDL_EVENT_KEY_UP):
                let ke = makeKeyEvent(from: event)
                collected.append(.keyUp(ke))

            // ── IME / text input ──
            case UInt32(GUAVA_SDL_EVENT_TEXT_EDITING):
                if let cstr = event.edit.text {
                    collected.append(.textEditing(TextEditingEvent(
                        text: String(cString: cstr),
                        start: event.edit.start,
                        length: event.edit.length
                    )))
                }

            case UInt32(GUAVA_SDL_EVENT_TEXT_INPUT):
                if let cstr = event.text.text {
                    collected.append(.textInput(String(cString: cstr)))
                }

            // ── Mouse motion ──
            case UInt32(GUAVA_SDL_EVENT_MOUSE_MOTION):
                collected.append(.mouseMotion(MouseMotionEvent(
                    x: event.motion.x,
                    y: event.motion.y,
                    deltaX: event.motion.xrel,
                    deltaY: event.motion.yrel)))

            // ── Mouse buttons ──
            case UInt32(GUAVA_SDL_EVENT_MOUSE_BUTTON_DOWN):
                if let btn = makeMouseButtonEvent(from: event) {
                    collected.append(.mouseButtonDown(btn))
                }

            case UInt32(GUAVA_SDL_EVENT_MOUSE_BUTTON_UP):
                if let btn = makeMouseButtonEvent(from: event) {
                    collected.append(.mouseButtonUp(btn))
                }

            // ── Mouse wheel ──
            case UInt32(GUAVA_SDL_EVENT_MOUSE_WHEEL):
                var wx = event.wheel.x
                var wy = event.wheel.y
                if event.wheel.direction.rawValue == UInt32(GUAVA_SDL_MOUSEWHEEL_FLIPPED) {
                    wx = -wx
                    wy = -wy
                }
                collected.append(.mouseWheel(MouseWheelEvent(x: wx, y: wy)))

            default:
                break
            }
        }

        syncDrawableSize()
        return collected
    }

    public func setTextInputArea(_ area: TextInputArea?) {
        guard let window else { return }
        guard lastTextInputArea != area else { return }

        if let area {
            var rect = SDL_Rect(
                x: max(0, Int32(area.x.rounded(.down))),
                y: max(0, Int32(area.y.rounded(.down))),
                w: max(1, Int32(area.width.rounded(.up))),
                h: max(1, Int32(area.height.rounded(.up)))
            )
            let cursor = max(0, Int32(area.cursorX.rounded(.toNearestOrAwayFromZero)))
            _ = SDL_SetTextInputArea(window, &rect, cursor)
        } else {
            _ = SDL_SetTextInputArea(window, nil, 0)
        }

        lastTextInputArea = area
    }

    public func shutdown() {
#if os(macOS)
        metalLayer = nil
        if let metalView {
            SDL_Metal_DestroyView(metalView)
            self.metalView = nil
        }
#endif

        if let window {
            SDL_DestroyWindow(window)
            self.window = nil
        }

        if didInitializeSDL {
            SDL_Quit()
            didInitializeSDL = false
        }

        isRunning = false
        lastTextInputArea = nil
    }

    // MARK: - Private helpers

    private func makeKeyEvent(from event: SDL_Event) -> KeyEvent {
        KeyEvent(
            scancode: UInt32(event.key.scancode.rawValue),
            keycode: event.key.key,
            modifiers: Self.convertModifiers(event.key.mod),
            isRepeat: event.key.`repeat`)
    }

    private func makeMouseButtonEvent(from event: SDL_Event) -> MouseButtonEvent? {
        guard let button = MouseButton(rawValue: event.button.button) else { return nil }
        return MouseButtonEvent(
            button: button,
            x: event.button.x,
            y: event.button.y,
            clicks: event.button.clicks)
    }

    private static func convertModifiers(_ sdlMod: UInt16) -> KeyModifiers {
        var m = KeyModifiers()
        if sdlMod & UInt16(GUAVA_SDL_KMOD_LSHIFT) != 0 { m.insert(.lshift) }
        if sdlMod & UInt16(GUAVA_SDL_KMOD_RSHIFT) != 0 { m.insert(.rshift) }
        if sdlMod & UInt16(GUAVA_SDL_KMOD_LCTRL)  != 0 { m.insert(.lctrl) }
        if sdlMod & UInt16(GUAVA_SDL_KMOD_RCTRL)  != 0 { m.insert(.rctrl) }
        if sdlMod & UInt16(GUAVA_SDL_KMOD_LALT)   != 0 { m.insert(.lalt) }
        if sdlMod & UInt16(GUAVA_SDL_KMOD_RALT)   != 0 { m.insert(.ralt) }
        if sdlMod & UInt16(GUAVA_SDL_KMOD_LGUI)   != 0 { m.insert(.lgui) }
        if sdlMod & UInt16(GUAVA_SDL_KMOD_RGUI)   != 0 { m.insert(.rgui) }
        return m
    }

    private func syncDrawableSize() {
#if os(macOS)
        guard let metalLayer, let window else { return }

        var logicalWidth: Int32 = 1
        var logicalHeight: Int32 = 1
        _ = SDL_GetWindowSize(window, &logicalWidth, &logicalHeight)

        let pixelSize = drawableSize
        let contentsScale: CGFloat
        if logicalWidth > 0 {
            contentsScale = CGFloat(pixelSize.width) / CGFloat(logicalWidth)
        } else {
            contentsScale = 1.0
        }

        metalLayer.contentsScale = max(contentsScale, 1.0)
        metalLayer.drawableSize = CGSize(width: Int(pixelSize.width), height: Int(pixelSize.height))
#endif
    }

#if os(macOS)
    private func configureMetalLayer(_ layer: CAMetalLayer) {
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        syncDrawableSize()
    }
#endif

    private static func lastSDLError() -> String {
        guard let message = SDL_GetError() else {
            return "unknown SDL error"
        }
        return String(cString: message)
    }

    private func windowProperties() -> SDL_PropertiesID? {
        guard let window else { return nil }
        let properties = SDL_GetWindowProperties(window)
        return properties == 0 ? nil : properties
    }

    private func pointerWindowProperty(named propertyName: StaticString) -> UnsafeMutableRawPointer? {
        guard let properties = windowProperties() else { return nil }
        return propertyName.withUTF8Buffer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            let cString = UnsafeRawPointer(baseAddress).assumingMemoryBound(to: CChar.self)
            return SDL_GetPointerProperty(properties, cString, nil)
        }
    }

    private func numberWindowProperty(named propertyName: StaticString) -> Int64 {
        guard let properties = windowProperties() else { return 0 }
        return propertyName.withUTF8Buffer { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            let cString = UnsafeRawPointer(baseAddress).assumingMemoryBound(to: CChar.self)
            return Int64(SDL_GetNumberProperty(properties, cString, 0))
        }
    }
}