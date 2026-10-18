private import Foundation
private import GuavaUIRuntime
@_spi(CustomLayout) public import GuavaUIScene

/// The resizing lane belongs to layout, so its touch target never covers a
/// destination or an action in the adjacent content.
struct SidebarResizeHandle: _PrimitiveView {
  let value: Binding<Float>?
  let extent: Float
  let range: ClosedRange<Float>
  let viewport: Float
  let resolvedWidth: Float
  let label: String
  let focus: SidebarFocusHandoff
  private static let startKey = "sidebar.resize.start"
  private static let basisKey = "sidebar.resize.basis"
  private static let hoverKey = "sidebar.resize.hover"

  private struct Start { let width: Float; let x: Float }
  private struct Basis: Equatable { let range: ClosedRange<Float>; let extent: Float; let viewport: Float; let rtl: Bool }
  private var isActive: Bool { value != nil && extent > 0 }

  func _makeNode() -> Node {
    let node = Node(); node.addResource(SidebarResizeLifetime()); return node
  }
  func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
  func _updateLayout(_ layout: LayoutNode) {
    layout.display = isActive ? .flex : .none
    layout.width = extent; layout.flexShrink = 0; layout.alignSelf = .stretch
  }
  func _updateNode(_ node: Node) {
    focus.resizer = node
    let chain = FocusChainHolder.current, capture = PointerCaptureHolder.current
    let basis = Basis(range: range, extent: extent, viewport: viewport, rtl: isRTL(node))
    if node.attachments[Self.basisKey] as? Basis != basis { release(node) }
    node.attachments[Self.basisKey] = basis
    node.layoutDidUpdate = { node in
      let placed = Basis(range: range, extent: extent, viewport: viewport, rtl: isRTL(node))
      if node.attachments[Self.basisKey] as? Basis != placed { release(node) }
      node.attachments[Self.basisKey] = placed
    }
    node.isHitTestable = isActive; node.isFocusable = isActive; node.cursor = isActive ? .resizeHorizontal : .arrow
    node.accessibilityActions = AccessibilityActions()
    guard isActive else {
      node.isFocusable = false; node.isHitTestable = false
      release(node); if chain?.focused === node { chain?.clear() }
      node.accessibility = nil; InteractionRegistryHolder.current?.remove(node); return
    }
    node.accessibility = AccessibilitySemantics(.slider) {
      $0.label = label; $0.value = "\(Int(current.rounded())) pt"
      $0.help = "Use Left/Right to resize, Shift for larger steps, Home/End for the limits"
    }
    node.accessibilityActions.increment = { [weak node] in if let node { write(current + 16, node: node) } }
    node.accessibilityActions.decrement = { [weak node] in if let node { write(current - 16, node: node) } }
    node.accessibilityActions.setValue = { [weak node] text in
      let number = text.replacingOccurrences(of: "pt", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
      if let node, let next = Float(number), next.isFinite { write(next, node: node) }
    }
    node.attachments[PointerCaptureAttachmentKey.didLoseCapture] = { [weak node] in
      node?.attachments.removeValue(forKey: Self.startKey); node?.markRenderDirty()
    }
    node.attachments[TextInputAttachmentKey.focusChangeHandler] = { [weak node] (_: Bool) in node?.markRenderDirty() }
    node.updateDraw(identity: basis) { [weak node, weak chain] list, origin in
      guard let node, node.isLayoutVisible else { return }
      let focused = chain?.focused === node && chain?.isFocusVisible == true
      let hot = node.attachments[Self.hoverKey] as? Bool == true || node.attachments[Self.startKey] != nil
      let thickness: Float = focused || hot ? 2 : 1
      list.addRect(.init(x: Float(origin.x) + (Float(node.frame.width) - thickness) / 2,
                         y: Float(origin.y), width: thickness, height: Float(node.frame.height)),
                   color: (focused ? node.theme.colors.focusRing : hot ? node.theme.colors.accent : node.theme.colors.divider)
                    .multipliedAlpha(node.opacity))
    }
    guard let registry = InteractionRegistryHolder.current else { return }
    registry.setHover(node) { event in
      node.attachments[Self.hoverKey] = node.supportsControlHover && event == .enter; node.markRenderDirty()
    }
    registry.setPointer(node) { event, phase, eventPhase in
      guard eventPhase == .target, event.button == .left, node.acceptsSubtreeInput else { return .ignored }
      if phase == .down {
        chain?.focus(node, visible: false)
        node.attachments[Self.startKey] = Start(width: current, x: event.x); capture?.acquire(node)
      } else { release(node) }
      node.markRenderDirty(); return .handled
    }
    registry.setMotion(node) { event, phase in
      guard phase == .target, node.acceptsSubtreeInput, capture?.target === node,
            let start = node.attachments[Self.startKey] as? Start else { return .ignored }
      write(start.width + (event.x - start.x) * (isRTL(node) ? -1 : 1), node: node); return .handled
    }
    registry.setKey(node) { event, phase in
      guard phase == .target, event.modifiers.isDisjoint(with: [.ctrl, .gui, .alt]) else { return .ignored }
      let step: Float = event.modifiers.contains(.shift) ? 32 : 16
      switch event.scancode {
      case Scancode.arrowLeft: write(current + (isRTL(node) ? step : -step), node: node)
      case Scancode.arrowRight: write(current + (isRTL(node) ? -step : step), node: node)
      case Scancode.home: write(range.lowerBound, node: node)
      case Scancode.end: write(range.upperBound, node: node)
      case Scancode.escape:
        guard let start = node.attachments[Self.startKey] as? Start else { return .ignored }
        write(start.width, node: node); release(node)
      default: return .ignored
      }
      return .handled
    }
  }
  private var current: Float {
    let proposed = value?.wrappedValue ?? range.lowerBound
    return max(range.lowerBound, min(range.upperBound, proposed.isFinite ? proposed : resolvedWidth))
  }
  private func write(_ proposed: Float, node: Node) {
    guard node.acceptsSubtreeInput, proposed.isFinite else { return }
    let next = max(range.lowerBound, min(range.upperBound, proposed))
    if value?.wrappedValue != next { value?.wrappedValue = next }
  }
  private func release(_ node: Node) {
    node.attachments.removeValue(forKey: Self.startKey)
    if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
  }
  private func isRTL(_ node: Node) -> Bool {
    node.layoutNode?.customLayoutDirection == .rtl
  }
}

private final class SidebarResizeLifetime: NodeResource {
  private weak var capture: PointerCapture?
  private weak var chain: FocusChain?
  func mount(node: Node) { capture = PointerCaptureHolder.current; chain = FocusChainHolder.current }
  func unmount(node: Node) {
    if capture?.target === node { capture?.release() }
    if chain?.focused === node { chain?.clear() }
  }
}
