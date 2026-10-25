internal import GuavaUIRuntime

/// Active viewports follow display callbacks when VSync is enabled. Idle
/// workspaces return to event-driven updates; uncapped mode stays explicit.
struct EditorFrameCadence {
    private var applied: PlatformFrameRateMode?

    mutating func update(continuous: Bool, vsyncEnabled: Bool) -> PlatformFrameRateMode? {
        let next: PlatformFrameRateMode = continuous && vsyncEnabled ? .displayRefresh : .eventDriven
        guard next != applied else { return nil }
        applied = next
        return next
    }
}
