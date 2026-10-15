import Foundation
import GuavaUIRuntime

public extension View {
    /// Move a surface between layout destinations with the same scene-local ID.
    /// Its frame animates while layout reserves the destination immediately.
    func matchedGeometry<ID: Hashable>(_ id: ID, animation: Animation? = nil) -> some View {
        MatchedHost(id: AnyHashable(id), animation: animation, content: self)
    }
}

private struct MatchedHost<Content: View>: _PrimitiveView {
    let id: AnyHashable
    let animation: Animation?
    let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; node.addResource(MatchedSurface()); return node }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) { layout.flexDirection = .column; layout.alignItems = .stretch }
    func _updateNode(_ node: Node) {
        node.firstResource(MatchedSurface.self)!.configure(id: id,
            animation: animation ?? ActiveAnimationContext.current ?? .semantic(.smooth, in: node.theme))
    }
    var _children: [any View] { [content] }
}

/// Owned by the scene root, with no global registration or public namespace.
private final class GeometrySession: NodeResource {
    final class Entry {
        weak var node: Node?
        var frame: CGRect
        var target: CGRect
        var generation: UInt64
        init(node: Node, frame: CGRect, generation: UInt64) {
            self.node = node; self.frame = frame; target = frame; self.generation = generation
        }
    }
    var entries: [AnyHashable: Entry] = [:]
    private(set) var generation: UInt64 = 0
    func mount(node: Node) {
        let previous = node.layoutDidUpdate
        node.layoutDidUpdate = { [weak self] node in previous?(node); self?.completeLayout() }
    }
    func unmount(node: Node) { entries.removeAll() }
    private func completeLayout() {
        generation &+= 1
        entries = entries.filter { $0.value.node?.parent != nil || generation - $0.value.generation <= 1 }
    }
}

private final class MatchedSurface: NodeResource {
    private weak var node: Node?
    private weak var session: GeometrySession?
    private var id: AnyHashable?
    private var animation: Animation = .default
    private var layoutFrame: CGRect?
    private var pending: AnimationController<Float>?
    private var completion: AnimationCompletionGroup?
    private weak var scheduler: AnimatorScheduler?
    private var suppressed = false
    private weak var surface: Node?
    func mount(node: Node) {
        self.node = node; scheduler = AnimatorScheduler.current
        node.layoutDidUpdate = { [weak self] node in self?.layout(node) }
    }
    func unmount(node: Node) {
        if let pending { pending.cancel(); scheduler?.unregister(pending) }
        pending = nil; completion = nil
        if let id, let entry = session?.entries[id], entry.node === node {
            entry.node = nil; entry.generation = session?.generation ?? 0
        }
        self.node = nil
    }
    func configure(id: AnyHashable, animation: Animation) {
        if self.id != id { layoutFrame = nil }
        self.id = id; self.animation = animation
        suppressed = ActiveAnimationContext.disablesAnimations
        if let node, let surface, node.prefersReducedMotion || suppressed,
           let entry = session?.entries[id] {
            surface.animatableSet(propertyKey: "motion.matchedFrame", current: entry.frame, to: entry.target) { [weak surface, weak entry] rect in
                guard let surface, let entry else { return }
                entry.frame = rect; Self.place(surface, at: rect)
            }
        }
        if let group = ActiveAnimationContext.currentCompletion, group !== completion {
            if let pending { pending.cancel(); scheduler?.unregister(pending) }
            completion = group
            // Native hosts tick before layout. Keep this completion open until
            // layout can enroll the real frame controller, even on that order.
            let reservation = AnimationController(from: Float(0), to: Float(1),
                animation: Animation(duration: Double.greatestFiniteMagnitude)) { _ in }
            pending = reservation; group.attach(reservation); scheduler?.register(reservation)
        }
    }
    private func completeRegistration() {
        if let pending { pending.finishImmediately(); scheduler?.unregister(pending) }
        pending = nil; completion = nil
    }
    private func layout(_ owner: Node) {
        defer { completeRegistration() }
        guard let id else { return }
        func surface(_ node: Node) -> Node? {
            if node.layoutNode != nil { return node }
            return node.children.lazy.compactMap(surface).first
        }
        guard let node = owner.children.lazy.compactMap(surface).first else { return }
        self.surface = node
        var root = node
        while let parent = root.parent { root = parent }
        let session: GeometrySession
        if let existing = root.firstResource(GeometrySession.self) { session = existing }
        else { session = GeometrySession(); root.addResource(session) }
        self.session = session
        let target = node.absoluteFrame
        let local = node.frame
        guard let entry = session.entries[id] else {
            session.entries[id] = GeometrySession.Entry(node: owner, frame: target, generation: session.generation)
            layoutFrame = local; return
        }
        precondition(entry.node == nil || entry.node === owner, "Matched geometry IDs must be unique within a scene")
        let changed = entry.node !== owner || entry.target != target || layoutFrame != local
        entry.node = owner; entry.generation = session.generation; layoutFrame = local
        if node.prefersReducedMotion || suppressed || animation.duration == 0 {
            node.cancelAnimation(for: "motion.matchedFrame"); entry.target = target; entry.frame = target
            return
        }
        if changed {
            entry.target = target
            ActiveAnimationContext.with(animation, completion: completion) {
                node.animatableSet(propertyKey: "motion.matchedFrame", current: entry.frame, to: target) { [weak node, weak entry] rect in
                    guard let node, let entry else { return }
                    entry.frame = rect; Self.place(node, at: rect)
                }
            }
        } else { Self.place(node, at: entry.frame) }
    }
    private static func place(_ node: Node, at rect: CGRect) {
        guard let parent = node.parent else { return }
        let point = parent.convertFromWindow(rect.origin)
        let scale = parent.frame.width > 0 ? parent.absoluteFrame.width / parent.frame.width : 1
        guard scale > 0 else { return }
        node.frame = CGRect(x: point.x + parent.contentOffset.x, y: point.y + parent.contentOffset.y,
                            width: rect.width / scale, height: rect.height / scale)
    }
}
