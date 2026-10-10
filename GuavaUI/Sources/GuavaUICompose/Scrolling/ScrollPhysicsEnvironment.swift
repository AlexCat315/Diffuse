import GuavaUIRuntime

/// Scroll overscroll behaviour shared by every scrollable container below the
/// provider.
///
/// The key is global rather than per-axis on purpose: a horizontal carousel
/// nested in a vertical list opts out by adding its own nearer provider, and
/// everything else keeps agreeing with its surroundings.
public enum ScrollPhysicsEnvironment {
    public static let key = CompositionLocal<ScrollPhysics>(defaultValue: .default)
}

public extension View {
    /// Override how descendant scrollable containers react past their bounds.
    ///
    /// ```swift
    /// ScrollView { console }
    ///     .scrollPhysics(.bouncy)
    /// ```
    func scrollPhysics(_ physics: ScrollPhysics) -> some View {
        compositionLocal(ScrollPhysicsEnvironment.key, physics)
    }
}

extension Node {
    /// Physics resolved for this node's position in the tree.
    var scrollPhysics: ScrollPhysics { compositionValue(of: ScrollPhysicsEnvironment.key) }
}
