import Foundation
import GuavaUIRuntime

/// Observes the capture phase so a nested button can still receive a tap.
/// Horizontal intent may cancel a button press; sliders and text selections
/// retain their capture and are never taken over by paging.
struct CarouselSwipeHost<Content: View>: _PrimitiveView {
    let onSwipe: (Int) -> Void
    let isEnabled: Bool
    let content: Content
    init(onSwipe: @escaping (Int) -> Void, isEnabled: Bool, @ViewBuilder content: () -> Content) {
        self.onSwipe = onSwipe; self.isEnabled = isEnabled; self.content = content()
    }
    func _makeNode() -> Node {
        let node = Node(); node.clipsToBounds = true
        node.attachments["carousel-swipe-host"] = true
        node.addResource(CarouselSwipeSession()); return node
    }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateNode(_ node: Node) {
        let session = node.firstResource(CarouselSwipeSession.self)!
        session.configure(isEnabled: isEnabled, onSwipe: onSwipe)
        let registry = InteractionRegistryHolder.current
        registry?.setPointer(node) { event, phase, eventPhase in
            guard eventPhase != .bubble, event.button == .left else { return .ignored }
            return session.pointer(event, phase: phase)
        }
        registry?.setMotion(node) { event, phase in
            guard phase != .bubble else { return .ignored }
            return session.motion(event)
        }
        registry?.setHover(node) { phase in
            if phase == .leave { session.pointerLeft() }
        }
        registry?.setKey(node) { event, phase in
            guard phase != .capture, event.scancode == Scancode.escape else { return .ignored }
            return session.cancelGesture() ? .handled : .ignored
        }
    }
    var _children: [any View] { [content] }
}

final class CarouselSwipeSession: NodeResource {
    private enum Gesture {
        case idle, observing(CGPoint), horizontal(CGPoint), rejected
    }
    private weak var node: Node?
    private weak var capture: PointerCapture?
    private var gesture = Gesture.idle
    private var isEnabled = true
    private var onSwipe: ((Int) -> Void)?
    func mount(node: Node) { self.node = node; capture = PointerCaptureHolder.current }
    func unmount(node: Node) { cancelGesture(); self.node = nil; onSwipe = nil; capture = nil }
    func configure(isEnabled: Bool, onSwipe: @escaping (Int) -> Void) {
        self.isEnabled = isEnabled; self.onSwipe = onSwipe
        if !isEnabled { cancelGesture() }
    }
    func pointer(_ event: MouseButtonEvent, phase: PointerPhase) -> EventResult {
        guard isEnabled, let node else { return .ignored }
        let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
        switch phase {
        case .down:
            cancelGesture(); gesture = .observing(point); return .ignored
        case .up:
            let previous = gesture
            let ownedCapture = capture?.target === node
            cancelGesture()
            guard case .horizontal(let start) = previous, ownedCapture else { return .ignored }
            let distance = point.x - start.x
            if abs(distance) >= max(32, node.frame.width * 0.15) { onSwipe?(distance < 0 ? 1 : -1) }
            return .handled
        }
    }
    func motion(_ event: MouseMotionEvent) -> EventResult {
        guard isEnabled, let node else { return .ignored }
        switch gesture {
        case .observing(let start):
            let dx = CGFloat(event.x) - start.x, dy = CGFloat(event.y) - start.y
            guard max(abs(dx), abs(dy)) >= 8 else { return .ignored }
            guard abs(dx) > abs(dy) else { gesture = .rejected; return .ignored }
            if let captured = capture?.target, captured !== node {
                var ancestor: Node? = captured
                while let current = ancestor, current !== node { ancestor = current.parent }
                guard ancestor === node,
                      captured.attachments[PointerCaptureAttachmentKey.didLoseCapture] is () -> Void else {
                    gesture = .rejected; return .ignored
                }
            }
            gesture = .horizontal(start); capture?.acquire(node); return .handled
        case .horizontal:
            guard capture?.target === node else { gesture = .rejected; return .ignored }
            return .handled
        case .idle, .rejected: return .ignored
        }
    }
    func pointerLeft() {
        if case .observing = gesture { cancelGesture() }
    }
    @discardableResult
    func cancelGesture() -> Bool {
        let wasDragging: Bool
        if case .horizontal = gesture { wasDragging = true } else { wasDragging = false }
        gesture = .idle
        if let node, capture?.target === node { capture?.release() }
        return wasDragging
    }
}
