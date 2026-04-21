import Foundation
import Logging
import EngineKernel

#if os(macOS)
import AppKit
import QuartzCore
#endif

public enum NativeRenderSurface {
    case metalLayer(UnsafeMutableRawPointer)
    case win32Window(hwnd: UnsafeMutableRawPointer, hinstance: UnsafeMutableRawPointer?)
    case xlibWindow(display: UnsafeMutableRawPointer, window: UInt64)
    case waylandSurface(display: UnsafeMutableRawPointer, surface: UnsafeMutableRawPointer)
}

public enum ShellError: Error, CustomStringConvertible {
    case initializationFailed(String)
    case unsupportedPlatform(String)

    public var description: String {
        switch self {
            case let .initializationFailed(message):
                return message
            case let .unsupportedPlatform(message):
                return message
        }
    }
}

@MainActor
public protocol Shell: AnyObject {
    var renderSurface: NativeRenderSurface? { get }
    var drawableSize: (width: UInt32, height: UInt32) { get }
    var logicalSize: (width: UInt32, height: UInt32) { get }
    var isRunning: Bool { get }
    var isFocused: Bool { get }
    var isMinimized: Bool { get }
    var isOccluded: Bool { get }
    func initializeWindow(title: String) throws
    @discardableResult func pollEvents() -> [InputEvent]
    func setTextInputArea(_ area: TextInputArea?)
    /// Switch the OS mouse cursor to a system style. Defaults to `.arrow`
    /// when the request fails or the platform does not implement it.
    func setCursor(_ cursor: SystemCursor)
    func shutdown()
}

public extension Shell {
    var logicalSize: (width: UInt32, height: UInt32) { drawableSize }
    var isRunning: Bool { true }
    var isFocused: Bool { true }
    var isMinimized: Bool { false }
    var isOccluded: Bool { false }
    func setTextInputArea(_ area: TextInputArea?) {}
    func setCursor(_ cursor: SystemCursor) {}
}

@MainActor
public func makeDefaultShell() throws -> any Shell {
#if os(macOS) || os(Windows) || os(Linux)
    try SDL3Shell()
#else
    throw ShellError.unsupportedPlatform("no default shell is implemented for this platform yet")
#endif
}

#if os(macOS)
@MainActor
public final class AppKitShell: Shell {
    private var window: NSWindow?
    private var contentView: NSView?
    private var metalLayer: CAMetalLayer?
    public private(set) var isRunning = true

    public init() {}

    public var renderSurface: NativeRenderSurface? {
        guard let metalLayer else { return nil }
        return .metalLayer(Unmanaged.passUnretained(metalLayer).toOpaque())
    }

    public var drawableSize: (width: UInt32, height: UInt32) {
        guard let layer = metalLayer else { return (1, 1) }
        let size = layer.drawableSize
        return (UInt32(max(1, size.width)), UInt32(max(1, size.height)))
    }

    public var logicalSize: (width: UInt32, height: UInt32) {
        guard let view = contentView else { return (1, 1) }
        let size = view.bounds.size
        return (UInt32(max(1, Int(size.width.rounded(.up)))),
                UInt32(max(1, Int(size.height.rounded(.up)))))
    }

    public func initializeWindow(title: String) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let frame = NSRect(x: 100, y: 100, width: 1280, height: 720)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let win = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        win.title = title
        win.isReleasedWhenClosed = false

        let view = NSView(frame: frame)
        view.wantsLayer = true

        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.contentsScale = win.backingScaleFactor
        layer.frame = view.bounds
        layer.drawableSize = CGSize(
            width: view.bounds.width * win.backingScaleFactor,
            height: view.bounds.height * win.backingScaleFactor
        )
        view.layer = layer

        win.contentView = view
        win.center()
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        self.window = win
        self.contentView = view
        self.metalLayer = layer
        self.isRunning = true

        Logger.platform.info("window ready, drawable=\(String(describing: layer.drawableSize))")
    }

    @discardableResult
    public func pollEvents() -> [InputEvent] {
        let app = NSApplication.shared
        while let event = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
        if window?.isVisible == false {
            isRunning = false
        }
        return []
    }

    public func shutdown() {
        window?.orderOut(nil)
        window = nil
        contentView = nil
        metalLayer = nil
        isRunning = false
    }
}

public typealias MacShell = AppKitShell
#endif
