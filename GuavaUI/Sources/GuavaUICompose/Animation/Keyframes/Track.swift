import GuavaUIRuntime

/// Plays an authored track when `trigger` changes. Repeating tracks start at
/// mount; reducing motion shows their initial static value and stops the clock.
public struct KeyframeAnimator<Value: Interpolatable, Trigger: Equatable, Content: View>: View {
    private let timeline: KeyframeTimeline<Value>
    private let trigger: Trigger
    private let repeating: Bool
    private let content: (Value) -> Content
    @State private var value: Value

    public init(_ timeline: KeyframeTimeline<Value>, trigger: Trigger, repeating: Bool = false,
                @ViewBuilder content: @escaping (Value) -> Content) {
        self.timeline = timeline; self.trigger = trigger; self.repeating = repeating; self.content = content
        _value = State(wrappedValue: timeline.initialValue)
    }
    public var body: some View {
        TrackHost(timeline: timeline, trigger: trigger, repeating: repeating,
                  publish: { value = $0 }, content: content(value))
    }
}

private struct TrackHost<Value: Interpolatable, Trigger: Equatable, Content: View>: _PrimitiveView {
    let timeline: KeyframeTimeline<Value>
    let trigger: Trigger
    let repeating: Bool
    let publish: (Value) -> Void
    let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; node.addResource(TrackSession<Trigger>()); return node }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) { layout.flexDirection = .column; layout.alignItems = .stretch }
    func _updateNode(_ node: Node) {
        let session = node.firstResource(TrackSession<Trigger>.self)!
        session.update(trigger: trigger, repeating: repeating, reducedMotion: node.prefersReducedMotion,
                       duration: timeline.duration, publish: { time in publish(timeline.value(at: time)) })
    }
    var _children: [any View] { [content] }
}

private final class TrackSession<Trigger: Equatable>: NodeResource {
    private var trigger: Trigger?
    private var repeating = false
    private var reduced = false
    private var duration = 0.0
    private var controller: AnimationController<Double>?
    private weak var scheduler: AnimatorScheduler?
    private var publish: (Double) -> Void = { _ in }
    func mount(node: Node) { scheduler = AnimatorScheduler.current }
    func unmount(node: Node) { stop(); publish = { _ in } }
    private func stop() {
        if let controller { controller.cancel(); scheduler?.unregister(controller) }
        controller = nil
    }
    func update(trigger: Trigger, repeating: Bool, reducedMotion: Bool, duration: Double,
                publish: @escaping (Double) -> Void) {
        self.publish = publish
        let mounted = self.trigger != nil
        let triggered = mounted && self.trigger != trigger
        let wasPlaying = controller?.isFinished == false
        let wasRepeating = self.repeating
        let durationChanged = self.duration != duration
        let changed = self.trigger != trigger || self.repeating != repeating || self.reduced != reducedMotion || self.duration != duration
        guard changed else { return }
        self.trigger = trigger; self.repeating = repeating; self.reduced = reducedMotion; self.duration = duration
        if reducedMotion && wasPlaying { controller?.finishImmediately() }
        stop()
        if reducedMotion {
            if repeating { publish(0) }
            else if triggered || wasPlaying { publish(duration) }
            return
        }
        guard triggered || repeating || (durationChanged && wasPlaying) else {
            if wasRepeating { publish(duration) }
            return
        }
        publish(0)
        let animation = Animation(duration: duration, curve: .linear)
        let controller = AnimationController(from: 0.0, to: duration,
            animation: repeating ? animation.repeatForever(autoreverses: false) : animation) { [weak self] in self?.publish($0) }
        self.controller = controller
        ActiveAnimationContext.currentCompletion?.attach(controller)
        scheduler?.register(controller)
    }
}
