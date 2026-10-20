internal import Foundation
internal import GuavaUIRuntime

/// Drives a blink phase: the cursor while focused (DECSCUSR / mode 12, on by
/// default) and SGR 5/6 blinking text while any is on screen.
///
/// A coarse timer toggles visibility, so an idle terminal costs two repaints
/// a second instead of a frame-rate animation. Input and output restart the
/// cursor phase so it stays solid while typing, as in other terminals.
final class BlinkTimer {
    static let interval: DispatchTimeInterval = .milliseconds(600)

    var onToggle: (() -> Void)?
    private(set) var isVisible = true
    private var timer: (any DispatchSourceTimer)?

    /// Called each paint with whether blinking applies right now.
    func update(active: Bool) {
        if active, timer == nil { start() } else if !active, timer != nil { stop() }
    }

    /// Shows the cursor and restarts the period.
    func restart() {
        isVisible = true
        timer?.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isVisible = true
    }

    private func start() {
        let schedule: (@escaping () -> Void) -> Void =
            UIWorkSchedulerHolder.enqueue ?? { work in DispatchQueue.main.async(execute: work) }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "guava.terminal.blink"))
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak self] in
            schedule { [weak self] in
                guard let self, self.timer != nil else { return }
                self.isVisible.toggle()
                self.onToggle?()
            }
        }
        timer.resume()
        self.timer = timer
        isVisible = true
    }

    deinit { timer?.cancel() }
}
