import CYoga
import CoreGraphics

/// Wraps a `YGNodeRef` and owns its lifetime.
///
/// Create a `LayoutNode` for every `Node` that participates in flexbox layout,
/// mirroring the GuavaUI node tree. After calling `calculateLayout()` on the root,
/// read back `frame` to obtain the Yoga-computed rectangle.
///
/// - Important: The tree owns its children — adding a `LayoutNode` as a child
///   transfers responsibility for its memory to the parent.
public final class LayoutNode: @unchecked Sendable {

    let ygNode: YGNodeRef

    /// Retained children — prevents the underlying YGNodeRefs from dangling.
    public private(set) var children: [LayoutNode] = []

    // MARK: - Init / deinit

    public init() {
        ygNode = YGNodeNew()
    }

    deinit {
        // YGNodeFreeRecursive frees this node and the whole subtree.
        YGNodeFreeRecursive(ygNode)
    }

    // MARK: - Tree

    public func addChild(_ child: LayoutNode) {
        YGNodeInsertChild(ygNode, child.ygNode, children.count)
        children.append(child)
    }

    // MARK: - Style setters

    public var flexDirection: FlexDirection = .column {
        didSet { YGNodeStyleSetFlexDirection(ygNode, flexDirection.ygValue) }
    }

    public var alignItems: Align = .stretch {
        didSet { YGNodeStyleSetAlignItems(ygNode, alignItems.ygValue) }
    }

    public var justifyContent: Justify = .flexStart {
        didSet { YGNodeStyleSetJustifyContent(ygNode, justifyContent.ygValue) }
    }

    public var flexGrow: Float = 0 {
        didSet { YGNodeStyleSetFlexGrow(ygNode, flexGrow) }
    }

    public var flexShrink: Float = 1 {
        didSet { YGNodeStyleSetFlexShrink(ygNode, flexShrink) }
    }

    public var width: Float? {
        didSet {
            if let w = width { YGNodeStyleSetWidth(ygNode, w) }
            else { YGNodeStyleSetWidthAuto(ygNode) }
        }
    }

    public var height: Float? {
        didSet {
            if let h = height { YGNodeStyleSetHeight(ygNode, h) }
            else { YGNodeStyleSetHeightAuto(ygNode) }
        }
    }

    public func setPadding(_ value: Float, edge: Edge = .all) {
        YGNodeStyleSetPadding(ygNode, edge.ygValue, value)
    }

    public func setMargin(_ value: Float, edge: Edge = .all) {
        YGNodeStyleSetMargin(ygNode, edge.ygValue, value)
    }

    // MARK: - Layout calculation

    /// Run Yoga layout from this node as the root.
    ///
    /// - Parameters:
    ///   - availableWidth: Container width (`Float.nan` = unconstrained).
    ///   - availableHeight: Container height (`Float.nan` = unconstrained).
    public func calculateLayout(
        availableWidth: Float = Float.nan,
        availableHeight: Float = Float.nan
    ) {
        YGNodeCalculateLayout(ygNode, availableWidth, availableHeight, YGDirection.LTR)
    }

    // MARK: - Layout readback

    /// The computed rectangle. Valid only after `calculateLayout()` has been called.
    public var frame: CGRect {
        CGRect(
            x: Double(YGNodeLayoutGetLeft(ygNode)),
            y: Double(YGNodeLayoutGetTop(ygNode)),
            width: Double(YGNodeLayoutGetWidth(ygNode)),
            height: Double(YGNodeLayoutGetHeight(ygNode))
        )
    }
}
