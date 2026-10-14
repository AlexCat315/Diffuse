/// Application-owned accessibility preference. A nearer provider may override
/// an ancestor; loading indicators keep a visible static form when enabled.
///
/// The key lives in the scene layer because the generic animatable-write path
/// must snap instead of scheduling when the preference is active.
public enum ReducedMotionEnvironment {
    public static let key = CompositionLocal<Bool>(defaultValue: false)
}

public extension Node {
    /// `true` when this node's nearest provider disables motion.
    var prefersReducedMotion: Bool { compositionValue(of: ReducedMotionEnvironment.key) }
}
