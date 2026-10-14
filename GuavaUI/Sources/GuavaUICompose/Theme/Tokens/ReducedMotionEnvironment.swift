import GuavaUIRuntime

public extension View {
    /// Marks the subtree as preferring reduced motion. The preference is read
    /// by the scene-layer `ReducedMotionEnvironment` key: framework motion
    /// (animated visibility, generic animatable writes, scroll physics and
    /// loading indicators) snaps to its final state instead of scheduling.
    func reducedMotion(_ enabled: Bool = true) -> some View {
        compositionLocal(ReducedMotionEnvironment.key, enabled)
    }
}
