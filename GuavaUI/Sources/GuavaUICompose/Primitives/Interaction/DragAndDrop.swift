import Foundation
import GuavaUIRuntime

/// Shares a typed drag payload between descendants of one `DragScope`.
///
/// The scope owns the session so payloads never escape into global state. A
/// drag preview is portal-rendered above clipping; dropping calls the target's
/// typed callback. Keyboard reordering is intentionally not implied: use
/// `ReorderableList` when the same collection needs an Up/Down path.
public struct DragScope<Content: View>: View {
    private let content: Content
    @State private var session = DragSession()
    @State private var revision = 0

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        session.onChange = { revision &+= 1 }
        return Box(direction: .column, alignItems: .stretch) {
            content
            DragPreviewPortal(session: session, revision: revision)
        }
        .compositionLocal(DragScopeEnvironment.key, session)
    }
}

/// A view that can start a drag with a typed payload and preview.
///
/// A six-point movement starts the drag; a tap that never crosses the threshold
/// still reaches nested controls. Avoid placing a draggable directly inside a
/// vertical `ScrollView` unless the drag gesture is wanted to win over
/// scrolling; `ReorderableList` is the list-specific alternative.
public struct Draggable<Payload: Hashable, Content: View, Preview: View>: View {
    public let payload: Payload
    private let content: Content
    private let preview: Preview

    public init(_ payload: Payload,
                @ViewBuilder preview: () -> Preview,
                @ViewBuilder content: () -> Content) {
        self.payload = payload
        self.preview = preview()
        self.content = content()
    }

    public var body: some View {
        DragSourceHost(payload: payload, preview: AnyView(preview), content: content)
    }
}

/// A drop area for one payload type. The closure runs once when a drag ends
/// inside this target; a cancelled drag never calls it.
public struct DropTarget<Payload: Hashable, Content: View>: View {
    private let onDrop: (Payload) -> Void
    private let onTargeted: ((Bool) -> Void)?
    private let content: Content

    public init(onTargeted: ((Bool) -> Void)? = nil,
                onDrop: @escaping (Payload) -> Void,
                @ViewBuilder content: () -> Content) {
        self.onTargeted = onTargeted
        self.onDrop = onDrop
        self.content = content()
    }

    public var body: some View {
        DropTargetHost(accepts: { $0 is Payload },
                       onDrop: { payload in
            if let typed = payload as? Payload { onDrop(typed) }
        },
                       onTargeted: onTargeted,
                       content: content)
    }
}

enum DragScopeEnvironment {
    static let key = CompositionLocal<DragSession?>(defaultValue: nil)
}

final class DragSession {
    struct Target {
        weak var node: Node?
        let accepts: (AnyHashable) -> Bool
        let drop: (AnyHashable) -> Void
        let onTargeted: ((Bool) -> Void)?
    }

    var payload: AnyHashable?
    var preview: AnyView?
    var pointer = CGPoint.zero
    var targets: [ObjectIdentifier: Target] = [:]
    var activeID: ObjectIdentifier?
    var onChange: (() -> Void)?

    var isDragging: Bool { payload != nil }

    func register(node: Node, accepts: @escaping (AnyHashable) -> Bool,
                  drop: @escaping (AnyHashable) -> Void,
                  onTargeted: ((Bool) -> Void)?) {
        targets[ObjectIdentifier(node)] = Target(node: node, accepts: accepts,
                                                 drop: drop, onTargeted: onTargeted)
    }

    func begin(payload: AnyHashable, preview: AnyView, pointer: CGPoint) {
        self.payload = payload
        self.preview = preview
        self.pointer = pointer
        activeID = nil
        onChange?()
    }

    func move(to point: CGPoint) {
        pointer = point
        refreshTarget()
        onChange?()
    }

    func end() {
        guard let payload else { return }
        refreshTarget()
        if let activeID, let target = targets[activeID] {
            target.drop(payload)
        }
        cancel()
    }

    func cancel() {
        if let activeID, let target = targets[activeID] {
            target.onTargeted?(false)
        }
        activeID = nil
        payload = nil
        preview = nil
        pointer = .zero
        onChange?()
    }

    private func refreshTarget() {
        targets = targets.filter { $0.value.node != nil }
        let next = target(at: pointer)
        let nextID = next.map { ObjectIdentifier($0) }
        guard nextID != activeID else { return }
        if let activeID, let previous = targets[activeID] {
            previous.onTargeted?(false)
        }
        activeID = nextID
        if let next, let target = targets[ObjectIdentifier(next)] {
            target.onTargeted?(true)
        }
    }

    private func target(at point: CGPoint) -> Node? {
        guard let payload else { return nil }
        var best: (node: Node, depth: Int)?
        for target in targets.values {
            guard target.accepts(payload), let node = target.node,
                  node.isLayoutVisible, node.isInteractionEnabled,
                  node.absoluteFrame.contains(point) else { continue }
            let depth = depth(of: node)
            if best == nil || depth > best!.depth { best = (node, depth) }
        }
        return best?.node
    }

    private func depth(of node: Node) -> Int {
        var depth = 0
        var current = node.parent
        while let parent = current { depth += 1; current = parent.parent }
        return depth
    }
}

private struct DragSourceHost<Payload: Hashable, Content: View>: _PrimitiveView {
    let payload: Payload
    let preview: AnyView
    let content: Content

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.alignItems = .stretch
        return layout
    }

    func _updateNode(_ node: Node) {
        guard let session = node.compositionValue(of: DragScopeEnvironment.key),
              let registry = InteractionRegistryHolder.current else { return }
        registry.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                node.attachments["drag.start"] = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
                node.attachments["drag.active"] = false
                return .ignored
            case .up:
                let active = node.attachments["drag.active"] as? Bool == true
                node.attachments.removeValue(forKey: "drag.start")
                node.attachments["drag.active"] = false
                if active {
                    if PointerCaptureHolder.current?.target === node {
                        PointerCaptureHolder.current?.release()
                    }
                    session.end()
                    return .handled
                }
                return .ignored
            }
        }
        registry.setMotion(node) { event, _ in
            guard let start = node.attachments["drag.start"] as? CGPoint else { return .ignored }
            let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
            if node.attachments["drag.active"] as? Bool != true {
                guard hypot(point.x - start.x, point.y - start.y) >= 6 else { return .ignored }
                node.attachments["drag.active"] = true
                PointerCaptureHolder.current?.acquire(node)
                session.begin(payload: AnyHashable(payload), preview: preview, pointer: point)
            }
            session.move(to: point)
            return .handled
        }
    }

    var _children: [any View] { [content] }
}

private struct DropTargetHost<Content: View>: _PrimitiveView {
    let accepts: (AnyHashable) -> Bool
    let onDrop: (AnyHashable) -> Void
    let onTargeted: ((Bool) -> Void)?
    let content: Content

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.alignItems = .stretch
        return layout
    }

    func _updateNode(_ node: Node) {
        guard let session = node.compositionValue(of: DragScopeEnvironment.key) else { return }
        session.register(node: node, accepts: accepts, drop: onDrop, onTargeted: onTargeted)
    }

    var _children: [any View] { [content] }
}

private struct DragPreviewPortal: _PrimitiveView {
    let session: DragSession
    let revision: Int

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.addResource(PortalResource())
        return node
    }

    func _makeLayoutNode() -> LayoutNode? { nil }

    func _updateNode(_ node: Node) {
        guard let resource = node.firstResource(PortalResource.self) else { return }
        guard session.isDragging, let preview = session.preview else {
            resource.unmount(node: node)
            return
        }
        let store = node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current
        let position = CGPoint(x: session.pointer.x + 12, y: session.pointer.y + 12)
        resource.present(in: store, position: position, width: nil,
                         content: AnyView(preview.theme(node.theme).allowsHitTesting(false)))
    }
}
