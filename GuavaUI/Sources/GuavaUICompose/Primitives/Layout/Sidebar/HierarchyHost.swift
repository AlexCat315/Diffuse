private import GuavaUIRuntime
@_spi(CustomLayout) public import GuavaUIScene

/// Coordinates disclosure and focus without making callers manage node lifetimes.
struct SidebarHierarchyHost<ID: Hashable, Content: View>: _PrimitiveView {
  let hierarchy: SidebarHierarchy<ID>
  let expanded: Binding<Set<ID>>
  let selection: Binding<ID?>
  let session: SidebarHierarchySession<ID>
  let content: Content
  init(hierarchy: SidebarHierarchy<ID>, expanded: Binding<Set<ID>>, selection: Binding<ID?>,
       session: SidebarHierarchySession<ID>, @ViewBuilder content: () -> Content) {
    self.hierarchy = hierarchy; self.expanded = expanded; self.selection = selection
    self.session = session; self.content = content()
  }
  func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
  func _makeLayoutNode() -> LayoutNode? { nil }
  func _updateNode(_ node: Node) {
    session.root = node
    let path = hierarchy.path(to: selection.wrappedValue)
    if session.revealedPath != path {
      session.revealedPath = path
      let ancestors = Set(path.dropLast())
      if !ancestors.isSubset(of: expanded.wrappedValue) { expanded.wrappedValue.formUnion(ancestors) }
    }
    if let focused = session.focusedID(), hierarchy.entry(focused).map({
      $0.isEnabled && $0.isVisible(in: expanded.wrappedValue)
    }) != true {
      session.focus.target = hierarchy.fallback(from: focused, expanded: expanded.wrappedValue,
                                                previous: session.previous).map(AnyHashable.init)
      session.focus.visible = FocusChainHolder.current?.isFocusVisible ?? true
    }
    session.previous = hierarchy
    node.layoutDidUpdate = { node in
      let tabStop = session.tabStop(in: hierarchy, expanded: expanded.wrappedValue,
                                    selection: selection.wrappedValue).map(AnyHashable.init)
      var pending = node.children
      while let item = pending.popLast() {
        if let id = item.attachments["__roving.item"] as? AnyHashable { item.isTabStop = id == tabStop }
        pending.append(contentsOf: item.children)
      }
    }
    InteractionRegistryHolder.current?.setKey(node) { [weak node] event, phase in
      guard phase == .capture, event.modifiers.isEmpty, let node, node.acceptsSubtreeInput,
            let id = session.focusedID(), let entry = hierarchy.entry(id), entry.isEnabled else { return .ignored }
      var layoutOwner: Node? = node
      while layoutOwner?.layoutNode == nil, let parent = layoutOwner?.parent { layoutOwner = parent }
      let rtl = layoutOwner?.layoutNode?.customLayoutDirection == .rtl
      let opening = event.scancode == (rtl ? Scancode.arrowLeft : Scancode.arrowRight)
      let closing = event.scancode == (rtl ? Scancode.arrowRight : Scancode.arrowLeft)
      guard opening || closing else { return .ignored }
      var target: ID?
      if opening {
        guard entry.isBranch else { return .ignored }
        if !expanded.wrappedValue.contains(id) { expanded.wrappedValue.insert(id) }
        else { target = hierarchy.entries.first { $0.ancestors.last == id && $0.isEnabled }?.item.id }
      } else if entry.isBranch && expanded.wrappedValue.contains(id) {
        expanded.wrappedValue.remove(id)
      } else { target = entry.ancestors.last }
      if let target {
        session.focus.target = AnyHashable(target); session.focus.visible = true
        if let next = hierarchy.entry(target), !next.isBranch { selection.wrappedValue = target }
        focusItem(target, in: node)
        node.markDirty()
      }
      return .handled
    }
  }
  private func focusItem(_ id: ID, in node: Node) {
    var pending = node.children
    while let item = pending.popLast() {
      if item.attachments["__roving.item"] as? AnyHashable == AnyHashable(id) {
        FocusChainHolder.current?.focus(item)
        ScrollReveal.reveal(item)
        return
      }
      pending.append(contentsOf: item.children)
    }
  }

  var _children: [any View] { [content] }
}
