import GuavaPlatformCore

/// A phased stream keeps its consuming viewport even when the pointer moves.
/// A click catches OS momentum; only fresh input can start scrolling again.
final class WheelGesture {
    private weak var target: Node?
    private var hasTarget = false
    private var interrupted = false

    func interrupt() { interrupted = true }

    func prepare(_ input: ScrollInput) -> Bool {
        if input.phase == .mayBegin {
            target = nil; hasTarget = false; interrupted = true
            return true
        }
        if input.phase == .began || !input.isContinuation {
            target = nil; hasTarget = false; interrupted = false
        }
        if input.momentumPhase == .none && (input.phase == .changed || input.phase == .stationary) {
            interrupted = false
        }
        return !interrupted
    }

    func path(in tree: NodeTree) -> [Node]? {
        guard hasTarget else { return nil }
        var path: [Node] = []
        var current = target
        while let node = current {
            guard node.acceptsSubtreeInput else { return [] }
            path.append(node); current = node.parent
        }
        guard path.last === tree.root else { return [] }
        return path.reversed()
    }

    func consumed(by node: Node, input: ScrollInput) {
        guard input.phase != .none || input.momentumPhase != .none else { return }
        target = node; hasTarget = true
    }

    func finish(_ input: ScrollInput) {
        if input.phase == .cancelled || input.momentumPhase == .ended || input.momentumPhase == .cancelled {
            target = nil; hasTarget = false
        }
        if input.phase == .cancelled || input.momentumPhase == .cancelled { interrupted = true }
    }
}
