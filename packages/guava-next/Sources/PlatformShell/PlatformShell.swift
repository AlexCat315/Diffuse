import AppKit
import QuartzCore

@MainActor
public protocol Shell: AnyObject {
    var metalLayer: CAMetalLayer? { get }
    var drawableSize: (width: UInt32, height: UInt32) { get }
    func initializeWindow(title: String)
    func pollEvents()
    func shutdown()
}

@MainActor
public final class MacShell: Shell {
    private var window: NSWindow?
    private var contentView: NSView?
    public private(set) var metalLayer: CAMetalLayer?

    public init() {}

    public var drawableSize: (width: UInt32, height: UInt32) {
        guard let layer = metalLayer else { return (1, 1) }
        let size = layer.drawableSize
        return (UInt32(max(1, size.width)), UInt32(max(1, size.height)))
    }

    public func initializeWindow(title: String) {
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

        print("[PlatformShell] window ready, drawable=\(layer.drawableSize)")
    }

    public func pollEvents() {
        let app = NSApplication.shared
        while let event = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
    }

    public func shutdown() {
        window?.orderOut(nil)
        window = nil
        contentView = nil
        metalLayer = nil
    }
}
