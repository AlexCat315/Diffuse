import Foundation
import GuavaUIRuntime

public struct PortalHost: View {
    @State private var revision: Int

    public init() {
        _revision = State(wrappedValue: PortalRegistry.revision)
    }

    public var body: some View {
        _PortalHostPrimitive(revision: revision) { nextRevision in
            if revision != nextRevision {
                revision = nextRevision
            }
        }
    }
}

private struct _PortalHostPrimitive: _PrimitiveView {
    let revision: Int
    let onRevisionChanged: (Int) -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.attachments[LayoutDebugAttachmentKey.layoutRole] = "portal-host"
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments[LayoutDebugAttachmentKey.layoutRole] = "portal-host"
        if let observer = node.attachments[PortalHostObserver.attachmentKey] as? PortalHostObserver {
            observer.onRevisionChanged = onRevisionChanged
        } else {
            let observer = PortalHostObserver(onRevisionChanged: onRevisionChanged)
            observer.token = PortalRegistry.addObserver { [weak observer] revision in
                observer?.notify(revision)
            }
            node.attachments[PortalHostObserver.attachmentKey] = observer
        }
    }

    func _makeLayoutNode() -> LayoutNode? { nil }

    func _updateLayout(_ layout: LayoutNode) {}

    var _children: [any View] {
        _ = revision
        return PortalRegistry.entries.map { entry in
            _PortalEntrySlot(entry: entry)
                .id(entry.id)
        }
    }
}

private final class PortalHostObserver {
    static let attachmentKey = "GuavaUICompose.portalHost.observer"

    var onRevisionChanged: (Int) -> Void
    var token: UUID?

    init(onRevisionChanged: @escaping (Int) -> Void) {
        self.onRevisionChanged = onRevisionChanged
    }

    deinit {
        if let token {
            PortalRegistry.removeObserver(token)
        }
    }

    func notify(_ revision: Int) {
        onRevisionChanged(revision)
    }
}

private struct _PortalEntrySlot: _PrimitiveView {
    let entry: PortalEntry

    func _makeNode() -> Node {
        let node = Node()
        node.attachments[LayoutDebugAttachmentKey.layoutRole] = "portal-entry"
        node.attachments[LayoutDebugAttachmentKey.debugName] = entry.id
        return node
    }

    func _updateNode(_ node: Node) {}

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
        layout.width = entry.width
    }

    var _children: [any View] {
        [entry.content]
    }
}
