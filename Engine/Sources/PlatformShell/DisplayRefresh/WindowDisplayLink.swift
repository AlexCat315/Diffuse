#if os(macOS)
import AppKit
import QuartzCore

/// The window's display link follows screen moves and variable refresh rates.
/// SDL's Cocoa event pump services NSDefaultRunLoopMode, including while waiting.
@available(macOS 14, *)
@MainActor
final class WindowDisplayRefreshSource: NSObject, MacDisplayRefreshDriver {
    private let inbox: DisplayRefreshInbox
    private weak var window: NSWindow?
    private var link: CADisplayLink?

    init(wake: @escaping @Sendable () -> Void) {
        inbox = DisplayRefreshInbox(wake: wake)
        super.init()
    }

    func configure(window: NSWindow, active: Bool) -> Bool {
        if self.window !== window || link == nil {
            stop()
            self.window = window
            let link = window.displayLink(target: self, selector: #selector(displayDidRefresh(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
        inbox.setEnabled(active)
        link?.isPaused = !active
        return true
    }

    @objc private func displayDidRefresh(_ link: CADisplayLink) {
        inbox.publish(DisplayRefreshTick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp))
    }

    func take() -> DisplayRefreshTick? { inbox.take() }

    func stop() {
        inbox.setEnabled(false)
        link?.invalidate()
        link = nil
        window = nil
    }
}
#endif
