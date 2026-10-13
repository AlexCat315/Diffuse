#if os(macOS)
import AppKit
import CoreVideo

/// macOS 13's native display callback runs off-thread while SDL owns the loop.
@MainActor
final class CoreVideoDisplayRefreshSource: MacDisplayRefreshDriver {
    private let inbox: DisplayRefreshInbox
    private var link: CVDisplayLink?
    private var displayID: CGDirectDisplayID?

    init(wake: @escaping @Sendable () -> Void) {
        inbox = DisplayRefreshInbox(wake: wake)
    }

    func configure(window: NSWindow, active: Bool) -> Bool {
        guard let number = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            stop()
            return !active
        }
        let nextDisplay = CGDirectDisplayID(number.uint32Value)
        if nextDisplay != displayID || link == nil {
            stop()
            var created: CVDisplayLink?
            guard CVDisplayLinkCreateWithCGDisplay(nextDisplay, &created) == kCVReturnSuccess,
                  let created else { return false }
            let inbox = self.inbox
            let frequency = CVGetHostClockFrequency()
            guard CVDisplayLinkSetOutputHandler(created, { _, now, output, _, _ in
                inbox.publish(DisplayRefreshTick(
                    timestamp: Double(now.pointee.hostTime) / frequency,
                    targetTimestamp: Double(output.pointee.hostTime) / frequency
                ))
                return kCVReturnSuccess
            }) == kCVReturnSuccess else { return false }
            link = created
            displayID = nextDisplay
        }
        guard let link else { return false }
        if active {
            inbox.setEnabled(true)
            if !CVDisplayLinkIsRunning(link), CVDisplayLinkStart(link) != kCVReturnSuccess {
                stop()
                return false
            }
        } else {
            inbox.setEnabled(false)
            if CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
        }
        return true
    }

    func take() -> DisplayRefreshTick? { inbox.take() }

    func stop() {
        inbox.setEnabled(false)
        if let link, CVDisplayLinkIsRunning(link) { CVDisplayLinkStop(link) }
        link = nil
        displayID = nil
    }
}
#endif
