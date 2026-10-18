private import GuavaUIRuntime

/// A transient projection of authored navigation, shared by drawing and input.
struct SidebarHierarchy<ID: Hashable> {
  struct Entry {
    let item: SidebarItem<ID>
    let ancestors: [ID]
    let isEnabled: Bool
    var isBranch: Bool { !item.children.isEmpty }
    func isVisible(in expanded: Set<ID>) -> Bool { ancestors.allSatisfy(expanded.contains) }
  }
  let groups: [[Entry]]
  var entries: [Entry] { groups.flatMap { $0 } }

  init(_ sections: [SidebarSection<ID>]) {
    func flatten(_ items: [SidebarItem<ID>], ancestors: [ID], enabled: Bool) -> [Entry] {
      items.flatMap { item in
        let entry = Entry(item: item, ancestors: ancestors, isEnabled: enabled && item.isEnabled)
        return [entry] + flatten(item.children, ancestors: ancestors + [item.id], enabled: entry.isEnabled)
      }
    }
    groups = sections.map { flatten($0.items, ancestors: [], enabled: true) }
  }
  func entry(_ id: ID?) -> Entry? { id.flatMap { id in entries.first { $0.item.id == id } } }
  func path(to id: ID?) -> [ID] { entry(id).map { $0.ancestors + [$0.item.id] } ?? [] }
  func context(for entry: Entry) -> String {
    (entry.ancestors.compactMap { self.entry($0)?.item.title } + [entry.item.title]).joined(separator: " / ")
  }
  func fallback(from id: ID, expanded: Set<ID>, previous: Self?) -> ID? {
    let candidates = (entry(id) ?? previous?.entry(id))?.ancestors.reversed() ?? [].reversed()
    return candidates.first { parent in
      entry(parent).map { $0.isEnabled && $0.isVisible(in: expanded) } == true
    } ?? entries.first { $0.isEnabled && $0.isVisible(in: expanded) }?.item.id
  }
}

/// Session data is kept outside authored items and never enters serialization.
final class SidebarHierarchySession<ID: Hashable> {
  weak var root: Node?
  var previous: SidebarHierarchy<ID>?
  var revealedPath: [ID]?
  let focus = RovingFocusRequest()

  func focusedID() -> ID? {
    guard let root else { return nil }
    var candidate = FocusChainHolder.current?.focused, id: ID?
    while let node = candidate, node !== root {
      if let value = node.attachments["__roving.item"] as? AnyHashable, let value = value.base as? ID { id = value }
      candidate = node.parent
    }
    return candidate === root ? id : nil
  }
  func tabStop(in hierarchy: SidebarHierarchy<ID>, expanded: Set<ID>, selection: ID?) -> ID? {
    let enabled = hierarchy.entries.filter { $0.isEnabled && $0.isVisible(in: expanded) }.map { $0.item.id }
    if let focused = focusedID(), enabled.contains(focused) { return focused }
    if let selection, enabled.contains(selection) { return selection }
    if let selection, hierarchy.entry(selection) != nil {
      return hierarchy.fallback(from: selection, expanded: expanded, previous: nil)
    }
    return enabled.first
  }
}
