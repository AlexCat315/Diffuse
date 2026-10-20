import GuavaUIRuntime

package extension Node {
    /// Effective writing direction from the nearest explicit `layoutDirection`.
    /// Direction can be applied after a primitive's update pass, so input and
    /// drawing resolve it lazily rather than snapshotting a stale value.
    var resolvesRightToLeft: Bool {
        var layout = layoutNode
        while let current = layout {
            if current.direction != .inherit { return current.direction == .rtl }
            layout = current.parent
        }
        return false
    }
}
