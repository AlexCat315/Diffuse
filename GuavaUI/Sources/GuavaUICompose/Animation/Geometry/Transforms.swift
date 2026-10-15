import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import GuavaUIRuntime

private struct TransformHost<Content: View>: _PrimitiveView {
    let factor: Float
    let anchor: CGPoint
    let offset: CGPoint
    let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) { layout.flexDirection = .column; layout.alignItems = .stretch }
    func _updateNode(_ node: Node) {
        node.transform.anchor = anchor; node.transform.scalesShadow = true
        if node.attachments["motion.transform.mounted"] == nil {
            node.transform.scale = factor; node.contentOffset = offset
            node.attachments["motion.transform.mounted"] = true
        } else {
            node.animatableSet(propertyKey: "motion.scale", current: node.transform.scale,
                               to: factor) { [weak node] in node?.transform.scale = max(0, $0) }
            node.animatableSet(\.contentOffset, to: offset)
        }
    }
    var _children: [any View] { [content] }
}
public extension View {
    func scaleEffect(_ factor: Float, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> some View {
        TransformHost(factor: factor.isFinite ? max(0, factor) : 1,
                      anchor: CGPoint(x: anchor.x.isFinite ? anchor.x : 0.5, y: anchor.y.isFinite ? anchor.y : 0.5),
                      offset: .zero, content: self)
    }
    func offset(x: Float = 0, y: Float = 0) -> some View {
        TransformHost(factor: 1, anchor: .zero,
                      offset: CGPoint(x: x.isFinite ? -CGFloat(x) : 0, y: y.isFinite ? -CGFloat(y) : 0), content: self)
    }
}
