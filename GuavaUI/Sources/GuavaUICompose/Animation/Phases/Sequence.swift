import GuavaUIRuntime

/// Discrete domain phases with an animation for entering each phase. The first
/// phase is the resting value; repeating sequences return to it each cycle.
public struct PhaseAnimator<Phase: Equatable, Trigger: Equatable, Content: View>: View {
    private let phases: [Phase]
    private let trigger: Trigger
    private let repeating: Bool
    private let animation: (Phase) -> Animation
    private let content: (Phase) -> Content
    @State private var index = 0
    public init(_ phases: [Phase], trigger: Trigger, repeating: Bool = false,
                animation: @escaping (Phase) -> Animation = { _ in .default },
                @ViewBuilder content: @escaping (Phase) -> Content) {
        precondition(!phases.isEmpty, "A phase animator requires a phase")
        self.phases = phases; self.trigger = trigger; self.repeating = repeating
        self.animation = animation; self.content = content
    }
    public var body: some View {
        PhaseHost(phases: phases, trigger: trigger, repeating: repeating,
                  animations: phases.map(animation), publish: { next, motion in
                      guard index != next else { return }
                      withAnimation(motion) { index = next }
                  }, content: content(phases[min(index, phases.count - 1)]))
    }
}

private struct PhaseHost<Phase: Equatable, Trigger: Equatable, Content: View>: _PrimitiveView {
    let phases: [Phase]
    let trigger: Trigger
    let repeating: Bool
    let animations: [Animation]
    let publish: (Int, Animation?) -> Void
    let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; node.addResource(PhaseSession<Phase, Trigger>()); return node }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) { layout.flexDirection = .column; layout.alignItems = .stretch }
    func _updateNode(_ node: Node) {
        node.firstResource(PhaseSession<Phase, Trigger>.self)!.update(phases: phases, trigger: trigger,
            repeating: repeating, animations: animations, reduced: node.prefersReducedMotion, publish: publish)
    }
    var _children: [any View] { [content] }
}

private final class PhaseSession<Phase: Equatable, Trigger: Equatable>: NodeResource {
    private var phases: [Phase] = []
    private var animations: [Animation] = []
    private var trigger: Trigger?
    private var repeating = false
    private var reduced = false
    private var controller: AnimationController<Double>?
    private weak var scheduler: AnimatorScheduler?
    private var publish: (Int, Animation?) -> Void = { _, _ in }
    func mount(node: Node) { scheduler = AnimatorScheduler.current }
    func unmount(node: Node) { stop(); publish = { _, _ in } }
    private func stop() {
        if let controller { controller.cancel(); scheduler?.unregister(controller) }
        controller = nil
    }
    func update(phases: [Phase], trigger: Trigger, repeating: Bool, animations: [Animation],
                reduced: Bool, publish: @escaping (Int, Animation?) -> Void) {
        self.publish = publish
        let mounted = self.trigger != nil
        let triggered = mounted && self.trigger != trigger
        let wasPlaying = controller?.isFinished == false
        let planChanged = self.phases != phases || self.animations != animations
        let wasRepeating = self.repeating
        let changed = self.trigger != trigger || self.phases != phases || self.animations != animations
            || self.repeating != repeating || self.reduced != reduced
        guard changed else { return }
        self.phases = phases; self.animations = animations; self.trigger = trigger
        self.repeating = repeating; self.reduced = reduced
        if reduced && wasPlaying { controller?.finishImmediately() }
        stop()
        if reduced {
            if repeating { publish(0, nil) }
            else if triggered || wasPlaying { publish(phases.count - 1, nil) }
            return
        }
        guard triggered || repeating || (planChanged && wasPlaying) else {
            if wasRepeating { publish(phases.count - 1, nil) }
            else if mounted && planChanged { publish(0, nil) }
            return
        }
        let targets = Array(phases.indices.dropFirst()) + (repeating ? [0] : [])
        guard !targets.isEmpty else { return }
        var total = 0.0
        let ends = targets.map { target in total += max(0.000001, animations[target].duration + animations[target].delay); return total }
        var lastIndex = -1
        let apply: (Double) -> Void = { [weak self] time in
            var segment = 0
            while segment < ends.count - 1 && time >= ends[segment] { segment += 1 }
            let index = targets[segment]
            guard index != lastIndex else { return }
            lastIndex = index; self?.publish(index, animations[index])
        }
        apply(0)
        let clock = Animation(duration: total, curve: .linear)
        let controller = AnimationController(from: 0.0, to: total,
            animation: repeating ? clock.repeatForever(autoreverses: false) : clock, apply: apply)
        self.controller = controller
        ActiveAnimationContext.currentCompletion?.attach(controller)
        scheduler?.register(controller)
    }
}
