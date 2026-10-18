internal import Foundation
internal import GuavaUIRuntime
@_spi(CustomLayout) public import GuavaUIScene

/// The shared portal boundary for popovers, confirmation bubbles and menus.
struct AnchoredOverlayHost<Content: View>: _PrimitiveView {
  let isPresented: Bool
  let width: Float?
  let placement: PopoverPlacement
  let sizing: PopoverSizing
  let surface: PopoverSurface
  let overflow: PopoverOverflow
  let onDismiss: () -> Void
  let keyHandler: ((KeyEvent, EventPhase) -> EventResult)?
  let content: Content
  init(isPresented: Bool, width: Float?, placement: PopoverPlacement, sizing: PopoverSizing = .content,
       surface: PopoverSurface = .content, overflow: PopoverOverflow = .flip,
       onDismiss: @escaping () -> Void, keyHandler: ((KeyEvent, EventPhase) -> EventResult)? = nil,
       @ViewBuilder content: () -> Content) {
    self.isPresented = isPresented; self.width = width; self.placement = placement; self.sizing = sizing
    self.surface = surface; self.overflow = overflow; self.onDismiss = onDismiss
    self.keyHandler = keyHandler; self.content = content()
  }
  func _makeNode() -> Node {
    let node = Node(); node.isHitTestable = false; node.addResource(PortalResource()); return node
  }
  func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
  func _updateLayout(_ layout: LayoutNode) {
    layout.positionType = .absolute; layout.setPosition(0, edge: .left)
    layout.setPositionPercent(100, edge: .top); layout.width = 0; layout.height = 0
  }
  func _updateNode(_ node: Node) {
    guard let resource = node.firstResource(PortalResource.self) else { return }
    guard isPresented else { resource.dismiss(node: node); return }
    guard node.acceptsSubtreeInput else { resource.unmount(node: node); onDismiss(); return }
    let margin: CGFloat = sizing == .anchor ? 12 : surface == .bubble ? 8 : 6
    let anchor = PopoverAnchor(owner: node, overflow: overflow, surface: surface, margin: margin)
    let minimumWidth = sizing == .anchor ? Float(anchor.frame.width) : 0
    let desiredWidth = width.map { max(minimumWidth, $0) }
    let provisional = CGSize(width: CGFloat(desiredWidth ?? 300), height: 160)
    let geometry = anchor.geometry(size: resource.frame?.size ?? provisional,
                                   placement: placement)
    resource.present(in: node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current,
      position: geometry.frame.origin, width: desiredWidth,
      content: AnyView(FocusScope(restoresCommands: true) {
        _MenuKeyHost(onKey: { event in
          if event.scancode == Scancode.escape { onDismiss(); return true }
          return keyHandler?(event, .target) == .handled
        }) {
          if surface == .bubble { PopoverSurfaceHost(anchor: anchor, placement: placement) { content } }
          else {
            Box(direction: .column, alignItems: .stretch, spacing: 0) { content }
              .padding(EdgeInsets(top: 2))
          }
        }
      }), placement: .fixed,
      positionForSize: { anchor.geometry(size: $0, placement: placement).frame.origin },
      transition: .opacity.combined(with: .offset(y: surface == .content ? -6 : 0)).combined(with: PortalResource.surfaceReveal(
        anchor: surface == .bubble ? CGPoint(x: 0.5, y: 0.5) : CGPoint(x: placement.alignment > 0 ? 1 : 0, y: 0), theme: node.theme)))
    func place() {
      anchor.refreshPaint()
      let geometry = anchor.geometry(size: resource.frame?.size ?? provisional, placement: placement)
      let currentMinimum = sizing == .anchor ? Float(anchor.frame.width) : 0
      resource.updateFit(.init(minimumWidth: currentMinimum, viewportMargin: Float(margin),
                               maximumWidth: Float(geometry.maximumSize.width), maximumHeight: Float(geometry.maximumSize.height)))
      resource.updatePosition(geometry.frame.origin)
    }
    resource.setDismissal(anchor: { anchor.frame }, dismiss: onDismiss)
    place()
    node.layoutDidUpdate = { _ in place() }
    node.updateOverlayDraw(identity: Identity(width: width, placement: placement, sizing: sizing, surface: surface, overflow: overflow)) { _, _ in place() }
  }
  private struct Identity: Equatable {
    let width: Float?
    let placement: PopoverPlacement
    let sizing: PopoverSizing
    let surface: PopoverSurface
    let overflow: PopoverOverflow
  }
}

final class PopoverAnchor {
  weak var owner: Node?
  weak var surface: Node?
  let overflow: PopoverOverflow
  let style: PopoverSurface
  let margin: CGFloat
  private var paintedAnchor: CGRect?
  init(owner: Node, overflow: PopoverOverflow, surface: PopoverSurface, margin: CGFloat) {
    self.owner = owner; self.overflow = overflow; style = surface; self.margin = margin
  }
  func refreshPaint() {
    let next = frame
    if paintedAnchor != next { paintedAnchor = next; surface?.markRenderDirty() }
    surface?.layoutNode?.direction = isRTL ? .rtl : .ltr
  }
  var frame: CGRect {
    var candidate = owner
    while let node = candidate, let parent = node.parent {
      if let index = parent.children.firstIndex(where: { $0 === node }) {
        for sibling in parent.children[..<index].reversed() {
          if sibling.frame.width > 0 || sibling.frame.height > 0 { return sibling.absoluteFrame }
          var pending = sibling.children
          while let item = pending.popLast() {
            if item.frame.width > 0 || item.frame.height > 0 { return item.absoluteFrame }
            pending.append(contentsOf: item.children.reversed())
          }
        }
      }
      candidate = parent
    }
    return .zero
  }
  func geometry(size: CGSize, placement: PopoverPlacement) -> PopoverGeometry {
    PopoverGeometry(anchor: frame, size: size, window: owner.map(portalWindowBounds) ?? .zero,
                    placement: placement, rtl: isRTL, overflow: overflow,
                    margin: margin, gap: style == .bubble ? 4 : 0)
  }
  var isRTL: Bool {
    var candidate = owner
    while candidate?.layoutNode == nil, let parent = candidate?.parent { candidate = parent }
    return candidate?.layoutNode?.customLayoutDirection == .rtl
  }
}
