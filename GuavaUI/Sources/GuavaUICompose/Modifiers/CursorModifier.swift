import GuavaUIRuntime
import PlatformShell

/// Sets the OS mouse cursor that should appear while the pointer is hovering
/// over the modified subtree. The `EventDispatcher` walks the hover path
/// leaf → root and uses the deepest non-nil value; ancestors therefore act as
/// fall-backs and `.cursor(.arrow)` can be used to "reset" within a subtree.
///
/// Built-in primitives that imply a cursor (`Button` → `.pointer`,
/// `TextField` → `.ibeam`, `SplitView` divider → `.resizeHorizontal` /
/// `.resizeVertical`, `Slider` thumb → `.pointer`) wire their cursor through
/// this same `Node.cursor` slot, so user overrides win when nested closer to
/// the leaf.
public struct CursorModifier: ViewModifier {
    public let cursor: SystemCursor
    public init(_ cursor: SystemCursor) { self.cursor = cursor }

    public func apply(node: Node) {
        node.cursor = cursor
    }
}

public extension View {
    func cursor(_ cursor: SystemCursor) -> some View {
        modifier(CursorModifier(cursor))
    }
}
