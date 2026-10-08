import Foundation
import GuavaUIRuntime

/// Per-node repeating phase; authored timing and transient progress stay separate.
final class LoadingAnimationClock: NodeResource, AnyAnimationController {
    private weak var node: Node?
    private weak var scheduler: AnimatorScheduler?
    private var duration = 2.0
    private(set) var phase = 0.0
    private(set) var isFinished = true

    func mount(node: Node) { self.node = node; scheduler = AnimatorScheduler.current }
    func unmount(node: Node) { cancel(); self.node = nil; scheduler = nil }

    func configure(duration: Double, isActive: Bool) {
        let duration = duration.isFinite ? min(60, max(0.25, duration)) : 2
        if self.duration != duration { self.duration = duration; phase = 0 }
        if isActive, node != nil {
            guard isFinished else { return }
            isFinished = false; scheduler?.register(self)
        } else { cancel() }
    }
    func tick(deltaTime: Double) {
        guard !isFinished, let node, deltaTime.isFinite, deltaTime > 0 else { return }
        // Reduce before adding to keep very large elapsed times finite.
        phase = (phase + deltaTime.truncatingRemainder(dividingBy: duration) / duration)
            .truncatingRemainder(dividingBy: 1)
        node.markRenderDirty(reason: .styleSet(field: "loading.phase"))
    }
    func finishImmediately() { cancel() }
    func cancel() {
        isFinished = true; phase = 0; scheduler?.unregister(self)
        node?.markRenderDirty(reason: .styleSet(field: "loading.phase"))
    }
}
