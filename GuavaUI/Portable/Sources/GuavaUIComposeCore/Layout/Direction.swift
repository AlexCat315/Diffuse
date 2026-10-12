import GuavaUIScene

private struct LayoutDirectionModifier: ViewModifier {
    let direction: Direction
    func apply(layout: LayoutNode) { layout.direction = direction }
}

public extension View {
    /// Logical leading/trailing edges, flex rows, and custom layouts inherit
    /// this direction. Explicit physical left/right positions stay physical.
    func layoutDirection(_ direction: Direction) -> some View {
        modifier(LayoutDirectionModifier(direction: direction))
    }
}
