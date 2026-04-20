/// Applies Yoga layout results back to the `Node` tree in a single depth-first pass.
///
/// Usage:
/// ```swift
/// LayoutPass.run(rootLayoutNode: rootLayout, rootNode: rootNode,
///                availableWidth: 800, availableHeight: 600)
/// // rootNode.frame and all descendants are now populated.
/// ```
public struct LayoutPass {

    /// Calculate layout and write results to every `Node.frame`.
    ///
    /// Both trees must have the same structure (same child count and order at every level).
    ///
    /// - Parameters:
    ///   - rootLayoutNode: Root of the `LayoutNode` tree (Yoga side).
    ///   - rootNode: Root of the `Node` tree (GuavaUI side).
    ///   - availableWidth: Viewport width (`Float.nan` = unconstrained).
    ///   - availableHeight: Viewport height (`Float.nan` = unconstrained).
    public static func run(
        rootLayoutNode: LayoutNode,
        rootNode: Node,
        availableWidth: Float = Float.nan,
        availableHeight: Float = Float.nan
    ) {
        rootLayoutNode.calculateLayout(
            availableWidth: availableWidth,
            availableHeight: availableHeight
        )
        apply(layoutNode: rootLayoutNode, node: rootNode)
    }

    private static func apply(layoutNode: LayoutNode, node: Node) {
        node.frame = layoutNode.frame
        for (lc, nc) in zip(layoutNode.children, node.children) {
            apply(layoutNode: lc, node: nc)
        }
    }
}
