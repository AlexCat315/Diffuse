#if os(macOS)
import AppKit
@MainActor
final class MacDisplayRefreshSource {
    private let driver: any MacDisplayRefreshDriver

    init(wake: @escaping @Sendable () -> Void) {
        if #available(macOS 14, *) {
            driver = WindowDisplayRefreshSource(wake: wake)
        } else {
            driver = CoreVideoDisplayRefreshSource(wake: wake)
        }
    }

    func configure(window: NSWindow, active: Bool) -> Bool {
        driver.configure(window: window, active: active)
    }

    func take() -> DisplayRefreshTick? { driver.take() }
    func stop() { driver.stop() }
}

@MainActor
protocol MacDisplayRefreshDriver: AnyObject {
    func configure(window: NSWindow, active: Bool) -> Bool
    func take() -> DisplayRefreshTick?
    func stop()
}
#endif
