import Foundation
@_spi(CustomLayout) import GuavaUIScene

/// A proposal expresses the space a parent offers, in logical points. A nil
/// axis asks for intrinsic size; zero asks for the smallest fitting size.
/// Fixed child dimensions and minimums may exceed the offered space.
public struct ProposedViewSize: Equatable, Sendable {
    public var width: CGFloat?
    public var height: CGFloat?

    public init(width: CGFloat? = nil, height: CGFloat? = nil) {
        self.width = width.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.height = height.flatMap { $0.isFinite ? max(0, $0) : nil }
    }

    public static let unspecified = ProposedViewSize()
    public static let zero = ProposedViewSize(width: 0, height: 0)
}

/// A short-lived value used during measurement and placement. It exposes no
/// nodes, storage, lifecycle, or mutable view state.
public struct LayoutSubview {
    private let measure: (ProposedViewSize) -> CGSize
    private let place: (CGPoint, ProposedViewSize) -> Void
    /// The owning container's logical direction. A child may override its
    /// own content direction without changing the container's placement.
    public let layoutDirection: Direction

    init(_ node: LayoutNode) {
        layoutDirection = node.parent?.customLayoutDirection ?? node.customLayoutDirection
        measure = { node.measureForCustomLayout(width: $0.width, height: $0.height) }
        place = { node.placeForCustomLayout(at: $0, width: $1.width, height: $1.height) }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { measure(proposal) }
    public func place(at point: CGPoint, proposal: ProposedViewSize = .unspecified) { place(point, proposal) }
}

/// Implement only the geometry of a container. Ordinary child views need no
/// adaptation. Measurement must be deterministic and must not mutate UI state.
public protocol Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview])
}

public extension Layout {
    func callAsFunction<Content: View>(@ViewBuilder content: () -> Content) -> LayoutContainer<Self, Content> {
        LayoutContainer(self, content: content)
    }
}

public struct LayoutContainer<Algorithm: Layout, Content: View>: _PrimitiveView {
    private let algorithm: Algorithm
    private let content: Content

    public init(_ algorithm: Algorithm, @ViewBuilder content: () -> Content) {
        self.algorithm = algorithm
        self.content = content()
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }
    public func _updateNode(_ node: Node) {}
    public func _updateLayout(_ layout: LayoutNode) {
        layout.setCustomLayout(measure: { width, height, children in
            let result = algorithm.sizeThatFits(proposal: ProposedViewSize(width: width, height: height),
                                                subviews: children.map(LayoutSubview.init))
            return CGSize(width: result.width.isFinite ? max(0, result.width) : 0,
                          height: result.height.isFinite ? max(0, result.height) : 0)
        }, place: { bounds, children in
            algorithm.placeSubviews(in: bounds,
                                    proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
                                    subviews: children.map(LayoutSubview.init))
        })
    }
    public var _children: [any View] { [content] }
}
