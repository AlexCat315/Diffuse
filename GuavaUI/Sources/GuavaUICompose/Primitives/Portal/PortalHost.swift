import Foundation
import GuavaUIRuntime

public struct PortalHost: View {
    /// The root view can be constructed before AppRuntime enters its per-window
    /// `withCurrent` scope. Resolve the owning store from the primitive node's
    /// first update, then retain that identity across later recompositions.
    /// The shared fallback is deliberately not retained; only a real window
    /// store becomes this host's stable owner.
    @State private var store: PortalStore?
    @State private var revision: Int

    public init() {
        _store = State(wrappedValue: nil)
        _revision = State(wrappedValue: 0)
    }

    public var body: some View {
        _PortalHostPrimitive(
            store: store,
            revision: revision,
            onStoreResolved: { resolvedStore in
                if store !== resolvedStore {
                    store = resolvedStore
                    revision &+= 1
                }
            },
            onRevisionChanged: { _ in
                // This state is an invalidation token, not the store's raw
                // revision. Incrementing avoids equality collisions when a
                // late window-store capture and its first entry share `1`.
                revision &+= 1
            }
        )
    }
}

private struct _PortalHostPrimitive: _PrimitiveView {
    let store: PortalStore?
    let revision: Int
    let onStoreResolved: (PortalStore) -> Void
    let onRevisionChanged: (Int) -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.attachments[LayoutDebugAttachmentKey.layoutRole] = "portal-host"
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments[LayoutDebugAttachmentKey.layoutRole] = "portal-host"
        // The ambient only identifies ownership while this host is being
        // mounted. Once captured, later updates may run after the window's
        // scoped ambient has unwound (or while another window is current).
        // Re-resolving on every update would silently migrate the observer and
        // eventually paint this window's overlays into another window.
        let ambientStore = PortalStoreHolder.current
        let treeStore = node.compositionValue(of: PortalStoreEnvironment.key)
        // AppRuntime may install the root once before the per-window ambient
        // is active. The process-shared fallback is not ownership evidence;
        // wait until a real window store is observed. Tests and simple hosts
        // that intentionally use the shared store continue to observe it, but
        // do not pin it and therefore need no extra initial composition.
        if store == nil, let treeStore {
            onStoreResolved(treeStore)
        } else if store == nil,
                  ambientStore !== PortalStoreHolder.shared {
            onStoreResolved(ambientStore)
        }
        let resolvedStore = store ?? treeStore ?? ambientStore
        InteractionRegistryHolder.current?.setPointer(node, route: .overlay) { event, phase, _ in
            if phase == .down {
                resolvedStore.dismissOutside(CGPoint(x: CGFloat(event.x), y: CGFloat(event.y)))
            }
            return .ignored
        }
        node.attachments[LayoutDebugAttachmentKey.debugName] =
            "portal-host-\(ObjectIdentifier(resolvedStore))-entries-\(resolvedStore.entries.count)"
        if let observer = node.attachments[PortalHostObserver.attachmentKey] as? PortalHostObserver {
            observer.onRevisionChanged = onRevisionChanged
            observer.bind(to: resolvedStore)
        } else {
            let observer = PortalHostObserver(onRevisionChanged: onRevisionChanged)
            observer.bind(to: resolvedStore)
            node.attachments[PortalHostObserver.attachmentKey] = observer
        }
    }

    func _makeLayoutNode() -> LayoutNode? { nil }

    func _updateLayout(_ layout: LayoutNode) {}

    var _children: [any View] {
        _ = revision
        let resolvedStore = store ?? PortalStoreHolder.current
        return resolvedStore.renderedEntries.map { entry in
            _PortalEntrySlot(store: resolvedStore, entry: entry)
                .id(entry.id)
        }
    }
}

private final class PortalHostObserver {
    static let attachmentKey = "GuavaUICompose.portalHost.observer"

    var onRevisionChanged: (Int) -> Void
    var token: UUID?
    /// The store this observer registered with. Weak: the store belongs to the
    /// window's input context; a lingering observer must not keep it alive.
    weak var store: PortalStore?

    init(onRevisionChanged: @escaping (Int) -> Void) {
        self.onRevisionChanged = onRevisionChanged
    }

    func bind(to nextStore: PortalStore) {
        guard store !== nextStore else { return }
        if let token {
            store?.removeObserver(token)
        }
        store = nextStore
        token = nextStore.addObserver { [weak self] revision in
            self?.notify(revision)
        }
    }

    deinit {
        if let token {
            store?.removeObserver(token)
        }
    }

    func notify(_ revision: Int) {
        onRevisionChanged(revision)
    }
}

private struct _PortalEntrySlot: _PrimitiveView {
    let store: PortalStore
    let entry: PortalEntry

    func _makeNode() -> Node {
        let node = Node()
        node.attachments[LayoutDebugAttachmentKey.layoutRole] = "portal-entry"
        node.attachments[PortalOwnership.entryKey] = entry.id
        node.attachments[LayoutDebugAttachmentKey.debugName] = entry.id
        node.attachments[WheelRoutingAttachmentKey.priority] = WheelRoutingPriority.preferHit
        return node
    }

    func _updateNode(_ node: Node) {
        store.attachSlotNode(entry.id, node: node)
        node.allowsHitTesting = !entry.isExiting
        node.isInteractionEnabled = !entry.isExiting
        node.clipsToBounds = !entry.fillsWindow
        node.layoutDidUpdate = { node in
            guard !entry.fillsWindow else { return }
            let window = portalWindowBounds(node)
            let fitted = PortalPlacement.fit(position: entry.position, size: node.frame.size,
                                              in: window, anchor: store.anchor(for: entry.id), placement: entry.placement)
            node.frame = fitted
            node.layoutNode?.maxWidth = Float(max(0, window.width - 12))
            node.layoutNode?.maxHeight = Float(max(0, window.height - 12))
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.positionType = .absolute
        layout.setPosition(Float(entry.position.x), edge: .left)
        layout.setPosition(Float(entry.position.y), edge: .top)
        if let width = entry.width {
            layout.width = width
        }
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.positionType = .absolute
        layout.setPosition(Float(entry.position.x), edge: .left)
        layout.setPosition(Float(entry.position.y), edge: .top)
        layout.width = entry.fillsWindow ? nil : entry.width
        if entry.fillsWindow {
            layout.setPosition(0, edge: .left); layout.setPosition(0, edge: .top)
            layout.setPosition(0, edge: .right); layout.setPosition(0, edge: .bottom)
        }
    }

    func _children(for node: Node) -> [any View] {
        if entry.fillsWindow { return [entry.content] }
        let window = portalWindowBounds(node)
        return [ScrollView(.vertical, scrollbarGutter: .overlay) { entry.content }
            .frame(maxWidth: Float(max(0, window.width - 12)), maxHeight: Float(max(0, window.height - 12)))]
    }
}
