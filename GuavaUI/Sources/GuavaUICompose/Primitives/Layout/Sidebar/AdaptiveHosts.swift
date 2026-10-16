private import GuavaUIRuntime

struct SidebarShellHost<Content: View>: _PrimitiveView {
  let geometry: SidebarGeometry
  let focus: SidebarFocusHandoff
  @ViewBuilder let content: Content
  func _makeNode() -> Node {
    let node = Node()
    node.isHitTestable = false
    return node
  }
  func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
  func _updateLayout(_ layout: LayoutNode) {
    layout.alignItems = .stretch
    layout.minHeight = 0
    layout.minWidth = 0
  }
  func _updateNode(_ node: Node) {
    focus.prepare(mode: geometry.mode, isModal: geometry.isModal, chain: FocusChainHolder.current)
    let chain = FocusChainHolder.current
    node.layoutDidUpdate = { _ in focus.complete(chain: chain) }
  }
  var _children: [any View] { [content] }
}

struct SidebarLayer<Content: View>: _PrimitiveView {
  let geometry: SidebarGeometry
  let focus: SidebarFocusHandoff
  let dismissal: ModalDismissal
  let onDismiss: () -> Void
  @ViewBuilder let content: Content
  func _makeNode() -> Node {
    let node = Node()
    node.isHitTestable = false
    node.addResource(ModalFocusResource())
    return node
  }
  func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
  func _updateNode(_ node: Node) {
    focus.navigation = node
    node.isFocusable = geometry.isModal
    let chain = FocusChainHolder.current
    let resource = node.firstResource(ModalFocusResource.self)
    if geometry.isModal {
      resource?.bind(node, chain: chain)
    }
    node.layoutDidUpdate = { node in
      if geometry.isModal { chain?.settleScope(node) }
      else {
        // The rail opener lives in this retained subtree. Restore only after
        // its visibility has been updated, so it is eligible to receive focus.
        resource?.unmount(node: node)
      }
    }
    InteractionRegistryHolder.current?.setKey(node, route: .overlay) { event, _ in
      guard geometry.isModal, event.scancode == Scancode.escape else { return .ignored }
      if dismissal.closesOnEscape { onDismiss() }
      return .handled
    }
  }
  var _children: [any View] { [content] }
}

struct SidebarTrigger<Content: View>: _PrimitiveView {
  let focus: SidebarFocusHandoff
  @ViewBuilder let content: Content
  func _makeNode() -> Node {
    let node = Node()
    node.isHitTestable = false
    return node
  }
  func _makeLayoutNode() -> LayoutNode? { nil }
  func _updateNode(_ node: Node) { focus.trigger = node }
  var _children: [any View] { [content] }
}

struct SidebarBackdrop: _PrimitiveView {
  let dismissal: ModalDismissal
  let onDismiss: () -> Void
  func _makeNode() -> Node { Node() }
  func _makeLayoutNode() -> LayoutNode? {
    let layout = LayoutNode()
    layout.flexGrow = 1
    return layout
  }
  func _updateNode(_ node: Node) {
    node.backgroundColor = node.theme.colors.stateLayerSelected
    node.accessibility = AccessibilitySemantics(.group) { $0.isHidden = true }
    InteractionRegistryHolder.current?.setPointer(
      node,
      route: InputHandlerRoute(role: .control, priority: .modal, debugName: "sidebar.backdrop")
    ) { event, phase, eventPhase in
      guard eventPhase == .target else { return .ignored }
      if event.button == .left, phase == .down, dismissal.closesOnBackdrop { onDismiss() }
      return .handled
    }
    InteractionRegistryHolder.current?.setWheel(node) { _, phase in
      phase == .capture ? .ignored : .handled
    }
  }
}
