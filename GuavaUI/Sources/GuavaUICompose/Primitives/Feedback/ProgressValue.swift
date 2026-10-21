internal import GuavaUIRuntime

/// Presentation value shared by linear and circular progress. Ticks invalidate
/// only drawing; progress never needs a layout or a subtree recomposition.
final class ProgressValue: NodeResource {
    private(set) var value = 0.0
    private var isDeterminate = false

    func mount(node: Node) {}
    func unmount(node: Node) { node.cancelAnimation(for: "progress.value") }

    func update(node: Node, target: Double, determinate: Bool) {
        defer { isDeterminate = determinate }
        guard isDeterminate, determinate else {
            node.cancelAnimation(for: "progress.value")
            value = target
            return
        }
        let apply = { [weak self, weak node] (value: Double) in
            guard let self, self.value != value else { return }
            self.value = value
            node?.markRenderDirty(reason: .styleSet(field: "progress.value"))
        }
        let animate = {
            node.animatableSet(propertyKey: "progress.value", current: self.value, to: target, apply: apply)
        }
        if ActiveAnimationContext.current != nil || ActiveAnimationContext.disablesAnimations {
            animate()
        } else {
            ActiveAnimationContext.with(SemanticMotionRef.medium.resolve(node.theme), animate)
        }
    }
}
