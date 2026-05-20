import CSDL3
import EngineKernel
import Foundation
import Logging

#if os(macOS)
import AppKit
import QuartzCore
#endif

@MainActor
public final class SDL3Shell: Shell {
    private final class SDL3WindowHandle: WindowHandle {
        let id: WindowID
        let window: OpaquePointer
        let metalView: UnsafeMutableRawPointer?

#if os(macOS)
        private var metalLayer: CAMetalLayer?
#endif

        private var lastTextInputArea: TextInputArea?
        private var cursorCache: [SystemCursor: OpaquePointer] = [:]
        private var activeCursor: SystemCursor = .arrow
        private var chromeHitTestState: SDL3ChromeHitTestState?

        var isFocused: Bool = true
        var isMinimized: Bool = false
        var isOccluded: Bool = false

        init(id: WindowID,
             window: OpaquePointer,
             metalView: UnsafeMutableRawPointer?) throws {
            self.id = id
            self.window = window
            self.metalView = metalView

#if os(macOS)
            if let metalView {
                guard let layerPointer = SDL_Metal_GetLayer(metalView) else {
                    throw ShellError.initializationFailed("SDL_Metal_GetLayer returned null")
                }
                let layer = Unmanaged<CAMetalLayer>.fromOpaque(layerPointer).takeUnretainedValue()
                metalLayer = layer
                configureMetalLayer(layer)
            }
#endif

            syncDrawableSize()
        }

        var renderSurface: NativeRenderSurface? {
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

        var drawableSize: (width: UInt32, height: UInt32) {
            var width: Int32 = 1
            var height: Int32 = 1
            if SDL_GetWindowSizeInPixels(window, &width, &height) {
                return (UInt32(max(1, width)), UInt32(max(1, height)))
            }
            return (1, 1)
        }

        var logicalSize: (width: UInt32, height: UInt32) {
            // Derive logical size from physical drawable ÷ display scale so the
            // computation stays consistent whether SDL reports DPI-scaled or
            // unscaled coordinates from SDL_GetWindowSize.
            let phys = drawableSize
            let scale = max(1.0, SDL_GetWindowDisplayScale(window))
            return (UInt32(max(1, (Float(phys.width) / scale).rounded())),
                    UInt32(max(1, (Float(phys.height) / scale).rounded())))
        }

        var contentScaleFactor: Float {
            // SDL_GetWindowDisplayScale returns the ratio between physical
            // pixels and DIP for the display the window lives on, computed
            // by SDL3 using the platform DPI APIs.  This is the correct
            // SDL3 source of truth and works on all platforms.
            let scale = SDL_GetWindowDisplayScale(window)
            if scale > 0 && scale.isFinite {
                // Quantize to 0.25 steps (100 %, 125 %, 150 %, 175 %, 200 %).
                return max(1, (scale * 4).rounded() / 4)
            }
            // Fallback: drawable / logical pixel ratio.
            let logicalWidth = max(logicalSize.width, 1)
            let raw = Float(drawableSize.width) / Float(logicalWidth)
            guard raw > 1 else { return 1 }
            return max(1, (raw * 4).rounded() / 4)
        }

        func setTextInputArea(_ area: TextInputArea?) {
            guard lastTextInputArea != area else { return }

            if let area {
                if !SDL_TextInputActive(window) {
                    _ = SDL_StartTextInput(window)
                }
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
                if SDL_TextInputActive(window) {
                    _ = SDL_StopTextInput(window)
                }
            }

            lastTextInputArea = area
        }

        func setCursor(_ cursor: SystemCursor) {
            guard cursor != activeCursor else { return }

            let handle = resolveCursor(cursor) ?? resolveCursor(.arrow)
            guard let handle else { return }

            _ = SDL_SetCursor(handle)
            activeCursor = cursor
        }

        func handleWindowEvent(_ eventType: UInt32) {
            switch eventType {
            case UInt32(GUAVA_SDL_EVENT_WINDOW_RESIZED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_METAL_VIEW_RESIZED):
                syncDrawableSize()
            case UInt32(GUAVA_SDL_EVENT_WINDOW_FOCUS_GAINED):
                isFocused = true
            case UInt32(GUAVA_SDL_EVENT_WINDOW_FOCUS_LOST):
                isFocused = false
            case UInt32(GUAVA_SDL_EVENT_WINDOW_MINIMIZED):
                isMinimized = true
            case UInt32(GUAVA_SDL_EVENT_WINDOW_RESTORED):
                isMinimized = false
            case UInt32(GUAVA_SDL_EVENT_WINDOW_OCCLUDED):
                isOccluded = true
            case UInt32(GUAVA_SDL_EVENT_WINDOW_EXPOSED):
                isOccluded = false
            default:
                break
            }
        }

        func shutdown() {
            setChromeHitTest(nil)

#if os(macOS)
            metalLayer = nil
            if let metalView {
                SDL_Metal_DestroyView(metalView)
            }
#endif

            SDL_DestroyWindow(window)

            for (_, ptr) in cursorCache {
                SDL_DestroyCursor(ptr)
            }
            cursorCache.removeAll()
            activeCursor = .arrow
            lastTextInputArea = nil
        }

        func setChromeHitTest(_ hitTest: WindowChromeHitTest?) {
            guard let hitTest else {
                _ = SDL_SetWindowHitTest(window, nil, nil)
                chromeHitTestState = nil
                return
            }

            let state = chromeHitTestState ?? SDL3ChromeHitTestState(config: hitTest)
            state.config = hitTest
            chromeHitTestState = state
            let raw = Unmanaged.passUnretained(state).toOpaque()
            _ = SDL_SetWindowHitTest(window, _sdl3ChromeHitTest, raw)
        }

#if os(macOS)
        func applyTitleBarStyle(_ style: WindowTitleBarStyle) {
            guard let window = cocoaWindow else { return }
            switch style {
            case .standard:
                break
            case .hiddenInset:
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                if #available(macOS 11.0, *) {
                    window.toolbarStyle = .unifiedCompact
                }
            }
        }

        func activateNativeWindow() {
            guard let window = cocoaWindow else { return }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
#endif

        private func resolveCursor(_ cursor: SystemCursor) -> OpaquePointer? {
            if let cached = cursorCache[cursor] { return cached }

            let id: Int32
            switch cursor {
            case .arrow:            id = Int32(GUAVA_SDL_SYSTEM_CURSOR_DEFAULT)
            case .pointer:          id = Int32(GUAVA_SDL_SYSTEM_CURSOR_POINTER)
            case .ibeam:            id = Int32(GUAVA_SDL_SYSTEM_CURSOR_TEXT)
            case .crosshair:        id = Int32(GUAVA_SDL_SYSTEM_CURSOR_CROSSHAIR)
            case .wait:             id = Int32(GUAVA_SDL_SYSTEM_CURSOR_WAIT)
            case .progress:         id = Int32(GUAVA_SDL_SYSTEM_CURSOR_PROGRESS)
            case .notAllowed:       id = Int32(GUAVA_SDL_SYSTEM_CURSOR_NOT_ALLOWED)
            case .move:             id = Int32(GUAVA_SDL_SYSTEM_CURSOR_MOVE)
            case .resizeHorizontal: id = Int32(GUAVA_SDL_SYSTEM_CURSOR_EW_RESIZE)
            case .resizeVertical:   id = Int32(GUAVA_SDL_SYSTEM_CURSOR_NS_RESIZE)
            case .resizeNWSE:       id = Int32(GUAVA_SDL_SYSTEM_CURSOR_NWSE_RESIZE)
            case .resizeNESW:       id = Int32(GUAVA_SDL_SYSTEM_CURSOR_NESW_RESIZE)
            }

            guard let created = SDL_CreateSystemCursor(SDL_SystemCursor(rawValue: SDL_SystemCursor.RawValue(id))) else {
                return nil
            }
            cursorCache[cursor] = created
            return created
        }

        private func syncDrawableSize() {
#if os(macOS)
            guard let metalLayer else { return }

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

        private var cocoaWindow: NSWindow? {
            guard let pointer = pointerWindowProperty(named: "SDL.window.cocoa.window") else {
                return nil
            }
            return Unmanaged<NSWindow>.fromOpaque(pointer).takeUnretainedValue()
        }
#endif

        private func windowProperties() -> SDL_PropertiesID? {
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

    private let defaultWindowOptions: WindowOptions
    private var windows: [WindowID: SDL3WindowHandle] = [:]
    private var windowOrder: [WindowID] = []
    private var didInitializeSDL = false
    private var isQuitting = false

    public init(width: Int32 = 1280, height: Int32 = 720) throws {
        self.defaultWindowOptions = WindowOptions(width: width, height: height)
    }

    public var isRunning: Bool {
        !isQuitting && !windows.isEmpty
    }

    public var mainWindowID: WindowID? {
        windowOrder.first(where: { windows[$0] != nil })
    }

    public var windowIDs: [WindowID] {
        windowOrder.filter { windows[$0] != nil }
    }

    @discardableResult
    public func createWindow(title: String, options: WindowOptions) throws -> any WindowHandle {
        try ensureSDLInitialized()
        isQuitting = false

#if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
#endif

#if os(macOS)
        let windowFlags = SDL_WindowFlags(
            GUAVA_SDL_WINDOW_RESIZABLE | GUAVA_SDL_WINDOW_HIGH_PIXEL_DENSITY | GUAVA_SDL_WINDOW_METAL)
#else
        var rawWindowFlags = GUAVA_SDL_WINDOW_RESIZABLE | GUAVA_SDL_WINDOW_HIGH_PIXEL_DENSITY
        if options.titleBarStyle == .hiddenInset {
            rawWindowFlags |= GUAVA_SDL_WINDOW_BORDERLESS
        }
        let windowFlags = SDL_WindowFlags(rawWindowFlags)
#endif

        // On Windows with DPI awareness enabled, SDL_CreateWindow coordinates are
        // physical pixels. Multiply by the primary display scale so the window
        // occupies the correct logical size on screen.
#if os(Windows)
        let primaryDisplay = SDL_GetPrimaryDisplay()
        let displayContentScale: Float = {
            guard primaryDisplay != 0 else { return 1 }
            let s = SDL_GetDisplayContentScale(primaryDisplay)
            return (s > 0 && s.isFinite) ? max(1, (s * 4).rounded() / 4) : 1
        }()
        let createWidth  = Int32((Float(options.width)  * displayContentScale).rounded())
        let createHeight = Int32((Float(options.height) * displayContentScale).rounded())
#else
        let createWidth  = options.width
        let createHeight = options.height
#endif

        let createdWindow = title.withCString { rawTitle in
            SDL_CreateWindow(rawTitle, createWidth, createHeight, windowFlags)
        }
        guard let createdWindow else {
            throw ShellError.initializationFailed(Self.lastSDLError())
        }

        let rawWindowID = SDL_GetWindowID(createdWindow)
        guard rawWindowID != 0 else {
            SDL_DestroyWindow(createdWindow)
            throw ShellError.initializationFailed("SDL_GetWindowID returned 0")
        }

#if os(macOS)
        let createdMetalView = SDL_Metal_CreateView(createdWindow)
        guard let createdMetalView else {
            SDL_DestroyWindow(createdWindow)
            throw ShellError.initializationFailed(Self.lastSDLError())
        }
#else
        let createdMetalView: UnsafeMutableRawPointer? = nil
#endif

        do {
            let handle = try SDL3WindowHandle(
                id: WindowID(rawWindowID),
                window: createdWindow,
                metalView: createdMetalView
            )
#if os(macOS)
            handle.applyTitleBarStyle(options.titleBarStyle)
            handle.activateNativeWindow()
#endif
            windows[handle.id] = handle
            windowOrder.removeAll { $0 == handle.id }
            windowOrder.append(handle.id)
            let sz = "\(handle.drawableSize.width)x\(handle.drawableSize.height)"
            let lz = "\(handle.logicalSize.width)x\(handle.logicalSize.height)"
            let csf = handle.contentScaleFactor
            let hz = displayRefreshRate(windowID: handle.id).map { String(format: "%.2fHz", $0) } ?? "unknown"
            Logger.platform.info("SDL3 window ready, id=\(handle.id), drawable=\(sz), logical=\(lz), contentScaleFactor=\(csf), displayRefreshRate=\(hz)")
            return handle
        } catch {
#if os(macOS)
            SDL_Metal_DestroyView(createdMetalView)
#endif
            SDL_DestroyWindow(createdWindow)
            throw error
        }
    }

    public func window(for id: WindowID) -> (any WindowHandle)? {
        windows[id]
    }

    public func destroyWindow(_ id: WindowID) {
        guard let handle = windows.removeValue(forKey: id) else { return }
        windowOrder.removeAll { $0 == id }
        handle.shutdown()
        if windows.isEmpty {
            tearDownSDLIfNeeded()
        }
    }

    public func initializeWindow(title: String) throws {
        if mainWindowID != nil { return }
        _ = try createWindow(title: title, options: defaultWindowOptions)
    }

    @discardableResult
    public func pollEvents() -> [InputEvent] {
        guard let mainWindowID else { return [] }
        return pollWindowEvents().compactMap { routed in
            routed.windowID == mainWindowID ? routed.event : nil
        }
    }

    @discardableResult
    public func pollWindowEvents() -> [WindowInputEvent] {
        guard didInitializeSDL else { return [] }

        var collected: [WindowInputEvent] = []
        var event = SDL_Event()

        while SDL_PollEvent(&event) {
            let eventType = event.type

            switch eventType {
            case UInt32(GUAVA_SDL_EVENT_QUIT):
                isQuitting = true

            case UInt32(GUAVA_SDL_EVENT_WINDOW_CLOSE_REQUESTED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_DESTROYED):
                destroyWindow(WindowID(event.window.windowID))

            case UInt32(GUAVA_SDL_EVENT_WINDOW_RESIZED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_METAL_VIEW_RESIZED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_FOCUS_GAINED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_FOCUS_LOST),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_MINIMIZED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_RESTORED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_OCCLUDED),
                 UInt32(GUAVA_SDL_EVENT_WINDOW_EXPOSED):
                let windowID = WindowID(event.window.windowID)
                guard let handle = windows[windowID] else { continue }
                handle.handleWindowEvent(eventType)
                if let routed = Self.makeWindowEvent(
                    eventType: eventType,
                    windowID: windowID,
                    data1: event.window.data1,
                    data2: event.window.data2
                ) {
                    collected.append(routed)
                }

            case UInt32(GUAVA_SDL_EVENT_KEY_DOWN):
                let windowID = WindowID(event.key.windowID)
                guard let handle = windows[windowID] else { continue }
                if event.key.scancode.rawValue == 44,
                   event.key.mod & (UInt16(GUAVA_SDL_KMOD_LALT) | UInt16(GUAVA_SDL_KMOD_RALT)) != 0 {
                    _ = SDL_ShowWindowSystemMenu(handle.window, 0, 0)
                    continue
                }
                collected.append(WindowInputEvent(windowID: windowID,
                                                  event: .keyDown(makeKeyEvent(from: event))))

            case UInt32(GUAVA_SDL_EVENT_KEY_UP):
                let windowID = WindowID(event.key.windowID)
                guard windows[windowID] != nil else { continue }
                collected.append(WindowInputEvent(windowID: windowID,
                                                  event: .keyUp(makeKeyEvent(from: event))))

            case UInt32(GUAVA_SDL_EVENT_TEXT_EDITING):
                let windowID = WindowID(event.edit.windowID)
                guard windows[windowID] != nil,
                      let cstr = event.edit.text
                else { continue }
                collected.append(WindowInputEvent(
                    windowID: windowID,
                    event: .textEditing(TextEditingEvent(
                        text: String(cString: cstr),
                        start: event.edit.start,
                        length: event.edit.length
                    ))
                ))

            case UInt32(GUAVA_SDL_EVENT_TEXT_INPUT):
                let windowID = WindowID(event.text.windowID)
                guard windows[windowID] != nil,
                      let cstr = event.text.text
                else { continue }
                collected.append(WindowInputEvent(windowID: windowID,
                                                  event: .textInput(String(cString: cstr))))

            case UInt32(GUAVA_SDL_EVENT_MOUSE_MOTION):
                let windowID = WindowID(event.motion.windowID)
                guard windows[windowID] != nil else { continue }
                collected.append(WindowInputEvent(
                    windowID: windowID,
                    event: .mouseMotion(MouseMotionEvent(
                        x: event.motion.x,
                        y: event.motion.y,
                        deltaX: event.motion.xrel,
                        deltaY: event.motion.yrel
                    ))
                ))

            case UInt32(GUAVA_SDL_EVENT_MOUSE_BUTTON_DOWN):
                let windowID = WindowID(event.button.windowID)
                guard windows[windowID] != nil,
                      let button = makeMouseButtonEvent(from: event)
                else { continue }
                collected.append(WindowInputEvent(windowID: windowID,
                                                  event: .mouseButtonDown(button)))

            case UInt32(GUAVA_SDL_EVENT_MOUSE_BUTTON_UP):
                let windowID = WindowID(event.button.windowID)
                guard windows[windowID] != nil,
                      let button = makeMouseButtonEvent(from: event)
                else { continue }
                collected.append(WindowInputEvent(windowID: windowID,
                                                  event: .mouseButtonUp(button)))

            case UInt32(GUAVA_SDL_EVENT_MOUSE_WHEEL):
                let windowID = WindowID(event.wheel.windowID)
                guard windows[windowID] != nil else { continue }
                let wx = event.wheel.x
                let wy = event.wheel.y
                var mouseX = event.wheel.mouse_x
                var mouseY = event.wheel.mouse_y
                if mouseX == 0, mouseY == 0 {
                    var currentX: Float = 0
                    var currentY: Float = 0
                    _ = SDL_GetMouseState(&currentX, &currentY)
                    mouseX = currentX
                    mouseY = currentY
                }
                collected.append(WindowInputEvent(windowID: windowID,
                                                  event: .mouseWheel(MouseWheelEvent(x: wx,
                                                                                     y: wy,
                                                                                     mouseX: mouseX,
                                                                                     mouseY: mouseY))))

            default:
                break
            }
        }

        if windows.isEmpty {
            tearDownSDLIfNeeded()
        }
        return collected
    }

    public func setTextInputArea(_ area: TextInputArea?) {
        guard let id = mainWindowID else { return }
        setTextInputArea(windowID: id, area)
    }

    public func setTextInputArea(windowID: WindowID, _ area: TextInputArea?) {
        windows[windowID]?.setTextInputArea(area)
    }

    public func setCursor(_ cursor: SystemCursor) {
        guard let id = mainWindowID else { return }
        setCursor(windowID: id, cursor)
    }

    public func setCursor(windowID: WindowID, _ cursor: SystemCursor) {
        windows[windowID]?.setCursor(cursor)
    }

    public func globalPointerPosition() -> (x: Float, y: Float)? {
        guard didInitializeSDL else { return nil }
        var x: Float = 0
        var y: Float = 0
        _ = SDL_GetGlobalMouseState(&x, &y)
        return (x, y)
    }

    public func windowPosition(_ windowID: WindowID) -> (x: Float, y: Float)? {
        guard let handle = windows[windowID] else { return nil }
        var x: Int32 = 0
        var y: Int32 = 0
        guard SDL_GetWindowPosition(handle.window, &x, &y) else { return nil }
        return (Float(x), Float(y))
    }

    public func setWindowPosition(_ windowID: WindowID, x: Float, y: Float) {
        guard let handle = windows[windowID] else { return }
        _ = SDL_SetWindowPosition(handle.window, Int32(x), Int32(y))
    }

    public func raiseWindow(_ windowID: WindowID) {
        guard let handle = windows[windowID] else { return }
        _ = SDL_RaiseWindow(handle.window)
    }

    public func minimizeWindow(_ windowID: WindowID) {
        guard let handle = windows[windowID] else { return }
        _ = SDL_MinimizeWindow(handle.window)
    }

    public func maximizeWindow(_ windowID: WindowID) {
        guard let handle = windows[windowID] else { return }
        _ = SDL_MaximizeWindow(handle.window)
    }

    public func restoreWindow(_ windowID: WindowID) {
        guard let handle = windows[windowID] else { return }
        _ = SDL_RestoreWindow(handle.window)
    }

    public func isWindowMaximized(_ windowID: WindowID) -> Bool {
        guard let handle = windows[windowID] else { return false }
        return (SDL_GetWindowFlags(handle.window) & SDL_WindowFlags(GUAVA_SDL_WINDOW_MAXIMIZED)) != 0
    }

    public func showWindowSystemMenu(_ windowID: WindowID, x: Float, y: Float) {
        guard let handle = windows[windowID] else { return }
        _ = SDL_ShowWindowSystemMenu(handle.window, Int32(x.rounded()), Int32(y.rounded()))
    }

    public func setWindowChromeHitTest(_ windowID: WindowID, _ hitTest: WindowChromeHitTest?) {
        windows[windowID]?.setChromeHitTest(hitTest)
    }

    public func displayRefreshRate(windowID: WindowID? = nil) -> Double? {
        guard didInitializeSDL else { return nil }

        let displayID: SDL_DisplayID
        if let windowID,
           let handle = windows[windowID] {
            displayID = SDL_GetDisplayForWindow(handle.window)
        } else if let mainWindowID,
                  let handle = windows[mainWindowID] {
            displayID = SDL_GetDisplayForWindow(handle.window)
        } else {
            displayID = SDL_GetPrimaryDisplay()
        }

        guard displayID != 0,
              let mode = SDL_GetCurrentDisplayMode(displayID)
        else { return nil }

        let preciseNumerator = mode.pointee.refresh_rate_numerator
        let preciseDenominator = mode.pointee.refresh_rate_denominator
        if preciseNumerator > 0, preciseDenominator > 0 {
            return Double(preciseNumerator) / Double(preciseDenominator)
        }

        let refreshRate = mode.pointee.refresh_rate
        guard refreshRate.isFinite, refreshRate > 0 else { return nil }
        return Double(refreshRate)
    }

    public func shutdown() {
        let ids = windowIDs
        for id in ids {
            destroyWindow(id)
        }
        isQuitting = false
        tearDownSDLIfNeeded()
    }

    private func ensureSDLInitialized() throws {
        guard !didInitializeSDL else { return }
#if os(Windows)
        // Must be set before SDL_Init so SDL3 creates windows in physical-pixel
        // coordinate space, which lets SDL_GetWindowSizeInPixels return the true
        // physical drawable size rather than the logical size.
        let hintOk = SDL_SetHint("SDL_WINDOWS_DPI_AWARENESS", "permonitorv2")
        Logger.platform.info("SDL_SetHint(DPI_AWARENESS=permonitorv2) -> \(hintOk)")
#endif
        guard SDL_Init(SDL_INIT_VIDEO) else {
            throw ShellError.initializationFailed(Self.lastSDLError())
        }
        didInitializeSDL = true
    }

    private func tearDownSDLIfNeeded() {
        guard didInitializeSDL, windows.isEmpty else { return }
        SDL_Quit()
        didInitializeSDL = false
    }

    private func makeKeyEvent(from event: SDL_Event) -> KeyEvent {
        KeyEvent(
            scancode: UInt32(event.key.scancode.rawValue),
            keycode: event.key.key,
            modifiers: Self.convertModifiers(event.key.mod),
            isRepeat: event.key.`repeat`
        )
    }

    private func makeMouseButtonEvent(from event: SDL_Event) -> MouseButtonEvent? {
        guard let button = MouseButton(rawValue: event.button.button) else { return nil }
        return MouseButtonEvent(
            button: button,
            x: event.button.x,
            y: event.button.y,
            clicks: event.button.clicks,
            modifiers: Self.convertModifiers(SDL_GetModState())
        )
    }

    private static func makeWindowEvent(eventType: UInt32,
                                        windowID: WindowID,
                                        data1: Int32,
                                        data2: Int32) -> WindowInputEvent? {
        let event: InputEvent?
        switch eventType {
        case UInt32(GUAVA_SDL_EVENT_WINDOW_RESIZED):
            event = .windowResized(width: data1, height: data2)
        case UInt32(GUAVA_SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED):
            event = .windowPixelSizeChanged(width: data1, height: data2)
        case UInt32(GUAVA_SDL_EVENT_WINDOW_FOCUS_GAINED):
            event = .windowFocusGained
        case UInt32(GUAVA_SDL_EVENT_WINDOW_FOCUS_LOST):
            event = .windowFocusLost
        case UInt32(GUAVA_SDL_EVENT_WINDOW_MINIMIZED):
            event = .windowMinimized
        case UInt32(GUAVA_SDL_EVENT_WINDOW_RESTORED):
            event = .windowRestored
        case UInt32(GUAVA_SDL_EVENT_WINDOW_OCCLUDED):
            event = .windowOccluded
        case UInt32(GUAVA_SDL_EVENT_WINDOW_EXPOSED):
            event = .windowExposed
        default:
            event = nil
        }
        guard let event else { return nil }
        return WindowInputEvent(windowID: windowID, event: event)
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

    private static func lastSDLError() -> String {
        guard let message = SDL_GetError() else {
            return "unknown SDL error"
        }
        return String(cString: message)
    }
}

private final class SDL3ChromeHitTestState {
    var config: WindowChromeHitTest

    init(config: WindowChromeHitTest) {
        self.config = config
    }
}

private let _sdl3ChromeHitTest: @convention(c) (OpaquePointer?, UnsafePointer<SDL_Point>?, UnsafeMutableRawPointer?) -> SDL_HitTestResult
    = { window, point, rawState in
        guard let window, let point, let rawState else {
            return SDL_HITTEST_NORMAL
        }

        let config = Unmanaged<SDL3ChromeHitTestState>
            .fromOpaque(rawState)
            .takeUnretainedValue()
            .config

        let coordinateScale: Float
#if os(Windows)
        let displayScale = SDL_GetWindowDisplayScale(window)
        coordinateScale = (displayScale > 0 && displayScale.isFinite) ? displayScale : 1
#else
        coordinateScale = 1
#endif
        let x = Float(point.pointee.x) / coordinateScale
        let y = Float(point.pointee.y) / coordinateScale
        var width: Int32 = 0
        var height: Int32 = 0
        _ = SDL_GetWindowSize(window, &width, &height)
        let w = Float(max(0, width)) / coordinateScale
        let h = Float(max(0, height)) / coordinateScale
        let isMaximized = (SDL_GetWindowFlags(window) & SDL_WindowFlags(GUAVA_SDL_WINDOW_MAXIMIZED)) != 0
        let border = isMaximized ? 0 : config.resizeBorderWidth

        if border > 0, w > 0, h > 0 {
            let left = x < border
            let right = x >= w - border
            let top = y < border
            let bottom = y >= h - border

            if top && left { return SDL_HITTEST_RESIZE_TOPLEFT }
            if top && right { return SDL_HITTEST_RESIZE_TOPRIGHT }
            if bottom && left { return SDL_HITTEST_RESIZE_BOTTOMLEFT }
            if bottom && right { return SDL_HITTEST_RESIZE_BOTTOMRIGHT }
            if top { return SDL_HITTEST_RESIZE_TOP }
            if bottom { return SDL_HITTEST_RESIZE_BOTTOM }
            if left { return SDL_HITTEST_RESIZE_LEFT }
            if right { return SDL_HITTEST_RESIZE_RIGHT }
        }

        if !config.draggableRects.isEmpty {
            for rect in config.draggableRects where rect.contains(x: x, y: y) {
                return SDL_HITTEST_DRAGGABLE
            }
            return SDL_HITTEST_NORMAL
        }

        if y >= 0,
           y < config.titleBarHeight,
           x >= config.draggableLeadingInset,
           x < w - config.draggableTrailingInset {
            return SDL_HITTEST_DRAGGABLE
        }

        return SDL_HITTEST_NORMAL
    }
