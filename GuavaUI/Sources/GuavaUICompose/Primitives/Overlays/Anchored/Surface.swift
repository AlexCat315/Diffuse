internal import Foundation
internal import GuavaUIRuntime

/// One painter owns the card and pointer; its content determines its full size.
struct PopoverSurfaceHost<Content: View>: _PrimitiveView {
  let anchor: PopoverAnchor
  let placement: PopoverPlacement
  @ViewBuilder let content: Content
  func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
  func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
  func _updateLayout(_ layout: LayoutNode) {
    layout.flexDirection = .column; layout.alignItems = .stretch; layout.flexShrink = 0
    layout.direction = anchor.isRTL ? .rtl : .ltr
    layout.maxHeight = Float(anchor.geometry(size: .zero, placement: placement).maximumSize.height)
  }
  func _updateNode(_ node: Node) {
    anchor.surface = node
    node.clipsToBounds = true
    node.attachments[LayoutDebugAttachmentKey.debugName] = "anchored-surface"
    node.updateDraw(identity: placement) { [weak node] list, origin in
      guard let node, node.frame.width > 20, node.frame.height > 20 else { return }
      let inset = Float(PopoverGeometry.inset), x = Float(origin.x), y = Float(origin.y)
      let body = UIRect(x: x + inset, y: y + inset, width: Float(node.frame.width) - inset * 2, height: Float(node.frame.height) - inset * 2)
      let radius = min(node.theme.radius.md, min(body.width, body.height) / 2)
      let fill = node.theme.colors.surfaceFloating.multipliedAlpha(node.opacity)
      let border = node.theme.colors.border.multipliedAlpha(node.opacity)
      list.addShadow(node.theme.elevation.low, rect: body, cornerRadius: radius, opacity: node.opacity)
      list.addRoundedRect(body, radius: radius, color: fill)
      list.addRoundedRectStroke(body, radius: radius, width: 1, color: border)
      let geometry = anchor.geometry(size: node.frame.size, placement: placement)
      let target = anchor.frame
      let half: Float = 7
      let a: CGPoint, b: CGPoint, tip: CGPoint
      if geometry.edge.isVertical {
        let center = max(body.minX + radius + half, min(x + Float(target.midX - node.absoluteFrame.minX), body.maxX - radius - half))
        let base = geometry.edge == .top ? body.maxY : body.minY
        a = CGPoint(x: CGFloat(center - half), y: CGFloat(base)); b = CGPoint(x: CGFloat(center + half), y: CGFloat(base))
        tip = CGPoint(x: CGFloat(center), y: CGFloat(base + (geometry.edge == .top ? inset : -inset)))
        list.addRect(UIRect(x: center - half, y: base - 1, width: half * 2, height: 2), color: fill)
      } else {
        let center = max(body.minY + radius + half, min(y + Float(target.midY - node.absoluteFrame.minY), body.maxY - radius - half))
        let base = geometry.edge == .left ? body.maxX : body.minX
        a = CGPoint(x: CGFloat(base), y: CGFloat(center - half)); b = CGPoint(x: CGFloat(base), y: CGFloat(center + half))
        tip = CGPoint(x: CGFloat(base + (geometry.edge == .left ? inset : -inset)), y: CGFloat(center))
        list.addRect(UIRect(x: base - 1, y: center - half, width: 2, height: half * 2), color: fill)
      }
      list.addTriangle(Float(a.x), Float(a.y), Float(b.x), Float(b.y), Float(tip.x), Float(tip.y), color: fill)
      list.addLine(fromX: Float(a.x), fromY: Float(a.y), toX: Float(tip.x), toY: Float(tip.y), thickness: 1, color: border)
      list.addLine(fromX: Float(b.x), fromY: Float(b.y), toX: Float(tip.x), toY: Float(tip.y), thickness: 1, color: border)
    }
  }
  var _children: [any View] {
    let maximum = Float(anchor.geometry(size: .zero, placement: placement).maximumSize.height)
    return [ScrollView(.both, scrollbarGutter: .overlay) { content }
      .frame(maxHeight: max(0, maximum - 48)).padding(24)]
  }
}
