import Foundation
import Logging
import EngineKernel

#if os(macOS)
import AppKit
import QuartzCore
#endif

public enum NativeRenderSurface: @unchecked Sendable {
    case metalLayer(UnsafeMutableRawPointer)
    case win32Window(hwnd: UnsafeMutableRawPointer, hinstance: UnsafeMutableRawPointer?)
    case xlibWindow(display: UnsafeMutableRawPointer, window: UInt64)
    case waylandSurface(display: UnsafeMutableRawPointer, surface: UnsafeMutableRawPointer)
}

public struct WindowOptions: Sendable, Equatable {
    public var width: Int32
    public var height: Int32

    public init(width: Int32 = 1280, height: Int32 = 720) {
        self.width = width
        self.height = height
    }
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
public protocol WindowHandle: AnyObject {
    var id: WindowID { get }
    var renderSurface: NativeRenderSurface? { get }
    var drawableSize: (width: UInt32, height: UInt32) { get }
    var logicalSize: (width: UInt32, height: UInt32) { get }
    var isFocused: Bool { get }
    var isMinimized: Bool { get }
    var isOccluded: Bool { get }
}

@MainActor
public protocol Shell: AnyObject {
    var mainWindowID: WindowID? { get }
    var windowIDs: [WindowID] { get }
    var renderSurface: NativeRenderSurface? { get }
    var drawableSize: (width: UInt32, height: UInt32) { get }
    var logicalSize: (width: UInt32, height: UInt32) { get }
    var isRunning: Bool { get }
    var isFocused: Bool { get }
    var isMinimized: Bool { get }
    var isOccluded: Bool { get }

    @discardableResult
    func createWindow(title: String, options: WindowOptions) throws -> any WindowHandle
    func window(for id: WindowID) -> (any WindowHandle)?
    func destroyWindow(_ id: WindowID)

    func initializeWindow(title: String) throws
    @discardableResult func pollEvents() -> [InputEvent]
    @discardableResult func pollWindowEvents() -> [WindowInputEvent]
    func setTextInputArea(_ area: TextInputArea?)
    func setTextInputArea(windowID: WindowID, _ area: TextInputArea?)
    /// Switch the OS mouse cursor to a system style. Defaults to `.arrow`
    /// when the request fails or the platform does not implement it.
    func setCursor(_ cursor: SystemCursor)
    func setCursor(windowID: WindowID, _ cursor: SystemCursor)

    /// Pointer position in the desktop coordinate space (logical / DIP),
    /// independent of any window. Returns `nil` when the platform does not
    /// expose a global mouse query.
    func globalPointerPosition() -> (x: Float, y: Float)?

    /// Top-left corner of `windowID` in the desktop coordinate space
    /// (logical / DIP). Returns `nil` when the window is unknown or the
    /// platform refuses the query.
    func windowPosition(_ windowID: WindowID) -> (x: Float, y: Float)?

    /// Move `windowID` to the supplied desktop position (logical / DIP).
    func setWindowPosition(_ windowID: WindowID, x: Float, y: Float)

    /// Bring `windowID` to the front and request focus. No-op when the
    /// window is unknown.
    func raiseWindow(_ windowID: WindowID)

    /// Refresh rate of the display currently containing `windowID`.
    /// Returns `nil` when the platform cannot report it.
    func displayRefreshRate(windowID: WindowID?) -> Double?

    func shutdown()
}

public extension Shell {
    var mainWindowID: WindowID? { nil }
    var windowIDs: [WindowID] { mainWindowID.map { [$0] } ?? [] }
    var logicalSize: (width: UInt32, height: UInt32) {
        window(for: mainWindowID ?? .main)?.logicalSize ?? drawableSize
    }
    var isRunning: Bool { true }
    var renderSurface: NativeRenderSurface? {
        guard let id = mainWindowID else { return nil }
        return window(for: id)?.renderSurface
    }
    var drawableSize: (width: UInt32, height: UInt32) {
        guard let id = mainWindowID else { return (1, 1) }
        return window(for: id)?.drawableSize ?? (1, 1)
    }
    var isFocused: Bool {
        guard let id = mainWindowID else { return true }
        return window(for: id)?.isFocused ?? true
    }
    var isMinimized: Bool {
        guard let id = mainWindowID else { return false }
        return window(for: id)?.isMinimized ?? false
    }
    var isOccluded: Bool {
        guard let id = mainWindowID else { return false }
        return window(for: id)?.isOccluded ?? false
    }

    func initializeWindow(title: String) throws {
        _ = try createWindow(title: title, options: WindowOptions())
    }

    @discardableResult
    func pollEvents() -> [InputEvent] {
        guard let id = mainWindowID else { return [] }
        return pollWindowEvents().compactMap { routed in
            routed.windowID == id ? routed.event : nil
        }
    }

    func setTextInputArea(_ area: TextInputArea?) {
        guard let id = mainWindowID else { return }
        setTextInputArea(windowID: id, area)
    }

    func setCursor(_ cursor: SystemCursor) {
        guard let id = mainWindowID else { return }
        setCursor(windowID: id, cursor)
    }

    func globalPointerPosition() -> (x: Float, y: Float)? { nil }
    func windowPosition(_ windowID: WindowID) -> (x: Float, y: Float)? { nil }
    func setWindowPosition(_ windowID: WindowID, x: Float, y: Float) {}
    func raiseWindow(_ windowID: WindowID) {}
    func displayRefreshRate(windowID: WindowID? = nil) -> Double? { nil }
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

    private final class AppKitWindowHandle: WindowHandle {
        let id: WindowID
        weak var shell: AppKitShell?

        init(id: WindowID, shell: AppKitShell) {
            self.id = id
            self.shell = shell
        }

        var renderSurface: NativeRenderSurface? { shell?.renderSurface }
        var drawableSize: (width: UInt32, height: UInt32) { shell?.drawableSize ?? (1, 1) }
        var logicalSize: (width: UInt32, height: UInt32) { shell?.logicalSize ?? (1, 1) }
        var isFocused: Bool { shell?.isRunning ?? false }
        var isMinimized: Bool { false }
        var isOccluded: Bool { false }
    }

    private var mainHandle: AppKitWindowHandle?

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

    public var mainWindowID: WindowID? {
        mainHandle?.id
    }

    public var windowIDs: [WindowID] {
        mainHandle.map { [$0.id] } ?? []
    }

    @discardableResult
    public func createWindow(title: String, options: WindowOptions) throws -> any WindowHandle {
        if mainHandle != nil {
            throw ShellError.unsupportedPlatform("AppKitShell does not support multiple windows yet")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let frame = NSRect(x: 100, y: 100,
                           width: Int(options.width),
                           height: Int(options.height))
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
        let handle = AppKitWindowHandle(id: .main, shell: self)
        mainHandle = handle

        Logger.platform.info("window ready, drawable=\(String(describing: layer.drawableSize))")
        return handle
    }

    public func window(for id: WindowID) -> (any WindowHandle)? {
        guard id == .main else { return nil }
        return mainHandle
    }

    public func destroyWindow(_ id: WindowID) {
        guard id == .main else { return }
        shutdown()
    }

    public func initializeWindow(title: String) throws {
        _ = try createWindow(title: title, options: WindowOptions())
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

    @discardableResult
    public func pollWindowEvents() -> [WindowInputEvent] {
        pollEvents().map { WindowInputEvent(windowID: .main, event: $0) }
    }

    public func setTextInputArea(windowID: WindowID, _ area: TextInputArea?) {
        guard windowID == .main else { return }
        setTextInputArea(area)
    }

    public func setCursor(windowID: WindowID, _ cursor: SystemCursor) {
        guard windowID == .main else { return }
        setCursor(cursor)
    }

    public func shutdown() {
        window?.orderOut(nil)
        window = nil
        contentView = nil
        metalLayer = nil
        mainHandle = nil
        isRunning = false
    }
}

public typealias MacShell = AppKitShell
#endif
