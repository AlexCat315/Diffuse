/// Process-wide bridge for work that must run on the UI run-loop thread.
///
/// Background loaders use this to hand renderer/state mutations back to the
/// host without depending on a concrete `SDL3PlatformHost`.
public enum UIWorkSchedulerHolder {
    nonisolated(unsafe) public static var enqueue: ((@escaping () -> Void) -> Void)?

    public static func schedule(_ work: @escaping () -> Void) {
        enqueue?(work)
    }
}
