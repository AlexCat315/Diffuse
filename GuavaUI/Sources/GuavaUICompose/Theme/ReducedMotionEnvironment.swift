import GuavaUIRuntime

/// Application-owned accessibility preference. A nearer provider may override
/// an ancestor; loading indicators keep a visible static form when enabled.
public enum ReducedMotionEnvironment {
    public static let key = CompositionLocal<Bool>(defaultValue: false)
}

public extension View {
    func reducedMotion(_ enabled: Bool = true) -> some View {
        compositionLocal(ReducedMotionEnvironment.key, enabled)
    }
}

extension Node {
    var prefersReducedMotion: Bool { compositionValue(of: ReducedMotionEnvironment.key) }
}
