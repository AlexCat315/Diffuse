internal import Foundation
internal import GuavaUIRuntime

/// Blinks the cursor while the terminal is focused and the program wants a
/// blinking cursor (DECSCUSR / mode 12; on by default).
///
/// A coarse timer toggles visibility twice per period, so an idle terminal
/// costs two repaints a second instead of a frame-rate animation. Input and
/// output keep the cursor solid, as in other terminals.
final class CursorBlink {
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
