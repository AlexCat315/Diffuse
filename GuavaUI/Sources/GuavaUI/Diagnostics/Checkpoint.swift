/// Optional DevTools checkpoint hooks for application-owned state.
/// State capture does not include transient input, composition or GPU resources.
@MainActor
public struct ApplicationCheckpoint {
    let capture: () -> [String: String]
    let restore: ([String: String]) -> Bool

    public init(capture: @escaping () -> [String: String],
                restore: @escaping ([String: String]) -> Bool) {
        self.capture = capture
        self.restore = restore
    }
}
