// Overlays (popovers, menus, tooltips) rendered on top of everything, anchored
// anywhere. This is where the legacy stack leaked: a global registry plus
// cleanup-by-modifier-side-effect. The rewrite fixes both root causes:
//
//   * `PortalStore` is **scoped to the `UIContext`** — never a process global,
//     so one tree's overlays can't corrupt another's.
//   * A popover's entry is owned by a `PortalResource` attached to the popover's
//     node. `UIContext.detach` releases it whenever the node leaves the tree —
//     closed, parent removed, panel swapped — with no modifier required. Leaking
//     an entry is therefore not expressible.

public final class PortalStore {
    public struct Entry: Identifiable {
        public let id: Int
        public var content: any View
        public var position: Rect
    }

    private var entries: [Int: Entry] = [:]
    private var nextID = 1

    /// Called whenever entries change, so the `ViewGraph` re-renders the host.
    var onChange: () -> Void = {}

    /// Entries in stable order (by id).
    public var orderedEntries: [Entry] { entries.values.sorted { $0.id < $1.id } }
    public var count: Int { entries.count }
    public func contains(_ id: Int) -> Bool { entries[id] != nil }

    func register(content: any View, position: Rect) -> Int {
        let id = nextID; nextID += 1
        entries[id] = Entry(id: id, content: content, position: position)
        onChange()
        return id
    }
    func update(id: Int, content: any View, position: Rect) {
        guard entries[id] != nil else { return }
        // Updating an existing entry does NOT notify: the entry *set* is
        // unchanged, so the host needn't re-reconcile its slots. New
        // content/position flow through on the next normal recompose. (Notifying
        // here would make every reconcile schedule another → an infinite loop.)
        entries[id] = Entry(id: id, content: content, position: position)
    }
    func unregister(_ id: Int) {
        if entries.removeValue(forKey: id) != nil { onChange() }
    }
    /// Clear every entry at once (press-outside / Escape). Owning
    /// `PortalResource`s self-heal: a stale `entryID` fails the `contains` guard
    /// in `present`, so the next open re-registers cleanly.
    func dismissAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        onChange()
    }
}

/// Marks the node that hosts the portal layer. Place one near the root, after
/// normal content. The `ViewGraph` supplies its children from the `PortalStore`.
public struct PortalHost: _PrimitiveView, _PortalHostMarker {
    public init() {}
    public func makeNode() -> UINode {
        let node = UINode()
        node.setZIndex(1_000_000) // overlays paint and hit-test above everything
        return node
    }
    public func updateNode(_ node: UINode) {}
}

protocol _PortalHostMarker {}

/// One overlay entry, positioned absolutely at its anchor.
struct _PortalSlot: _PrimitiveView {
    let entry: PortalStore.Entry
    func makeNode() -> UINode { UINode() }
    func updateNode(_ node: UINode) {
        node.modifyLayout { $0.position = .absolute(entry.position) }
    }
    var childViews: [any View] { [AnyView(entry.content)] }
}

/// The entry's lifetime is bound to the owning node via this resource.
final class PortalResource: NodeResource {
    private weak var context: UIContext?
    private var entryID: Int?

    func mount(node: UINode, context: UIContext) { self.context = context }

    /// Guaranteed cleanup: the popover node leaving the tree releases the entry.
    func unmount(node: UINode, context: UIContext) {
        if let id = entryID { context.portals.unregister(id) }
        entryID = nil
        self.context = nil
    }

    func present(content: any View, position: Rect) {
        guard let context else { return }
        if let id = entryID, context.portals.contains(id) {
            context.portals.update(id: id, content: content, position: position)
        } else {
            entryID = context.portals.register(content: content, position: position)
        }
    }
    func dismiss() {
        guard let context, let id = entryID else { return }
        context.portals.unregister(id)
        entryID = nil
    }
}

/// A trigger with overlay content shown while `isPresented` is true. The content
/// renders in the `PortalHost` (on top), anchored just below the trigger.
public struct Popover<Trigger: View, Content: View>: _PrimitiveView {
    let isPresented: Binding<Bool>
    let content: Content
    let trigger: Trigger

    public init(isPresented: Binding<Bool>,
                @ViewBuilder content: () -> Content,
                @ViewBuilder trigger: () -> Trigger) {
        self.isPresented = isPresented
        self.content = content()
        self.trigger = trigger()
    }

    public func makeNode() -> UINode {
        let node = UINode()
        node.addResource(PortalResource()) // attached for the node's whole life
        return node
    }

    public func updateNode(_ node: UINode) {
        guard let resource = node.firstResource(PortalResource.self) else { return }
        if isPresented.wrappedValue {
            let anchor = absoluteFrame(of: node)
            let position = Rect(x: anchor.minX, y: anchor.maxY,
                                width: anchor.size.width, height: 0)
            resource.present(content: content, position: position)
        } else {
            resource.dismiss()
        }
    }

    public var childViews: [any View] { [trigger] }

    private func absoluteFrame(of node: UINode) -> Rect {
        var x: Float = 0, y: Float = 0
        var current: UINode? = node
        while let n = current { x += n.geometry.frame.minX; y += n.geometry.frame.minY; current = n.parent }
        return Rect(x: x, y: y, width: node.geometry.frame.size.width, height: node.geometry.frame.size.height)
    }
}
