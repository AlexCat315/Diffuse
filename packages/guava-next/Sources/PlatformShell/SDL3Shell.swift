import CSDL3
import Foundation

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

#if os(macOS)
    private var metalLayer: CAMetalLayer?
#endif

    public private(set) var isRunning = true

    public init(width: Int32 = 1280, height: Int32 = 720) throws {
        self.initialWidth = width
        self.initialHeight = height
    }

    public var renderSurface: NativeRenderSurface? {
#if os(macOS)
        guard let metalLayer else { return nil }
        return .metalLayer(Unmanaged.passUnretained(metalLayer).toOpaque())
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
        print("[PlatformShell] SDL3 window ready, drawable=\(drawableSize.width)x\(drawableSize.height)")
    }

    public func pollEvents() {
        guard window != nil else { return }

        var event = SDL_Event()
        while SDL_PollEvent(&event) {
              let eventType = event.type
            switch eventType {
                 case UInt32(GUAVA_SDL_EVENT_QUIT),
                     UInt32(GUAVA_SDL_EVENT_WINDOW_CLOSE_REQUESTED),
                     UInt32(GUAVA_SDL_EVENT_WINDOW_DESTROYED):
                    isRunning = false

                 case UInt32(GUAVA_SDL_EVENT_WINDOW_RESIZED),
                     UInt32(GUAVA_SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED),
                     UInt32(GUAVA_SDL_EVENT_WINDOW_METAL_VIEW_RESIZED):
                    syncDrawableSize()

                default:
                    break
            }
        }

        syncDrawableSize()
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
}