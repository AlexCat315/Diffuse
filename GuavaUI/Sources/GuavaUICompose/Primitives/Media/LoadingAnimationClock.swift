import Foundation
import GuavaUIRuntime

/// Node-owned adapter to the shared repeating animation controller.
final class LoadingAnimationClock: NodeResource {
    private weak var node: Node?
    private weak var scheduler: AnimatorScheduler?
    private var duration = 2.0
    private var controller: AnimationController<Double>?
    private(set) var phase = 0.0
    func mount(node: Node) { self.node = node; scheduler = AnimatorScheduler.current }
    func unmount(node: Node) { stop(); self.node = nil; scheduler = nil }
    func configure(duration: Double, isActive: Bool) {
        let duration = duration.isFinite ? min(60, max(0.25, duration)) : 2
        if !isActive { stop(); return }
        if self.duration == duration, controller?.isFinished == false { return }
        stop(); self.duration = duration
        let controller = AnimationController(from: 0.0, to: 1.0,
            animation: Animation(duration: duration, curve: .linear).repeatForever(autoreverses: false)) { [weak self] value in
                guard let self else { return }
                self.phase = value; self.node?.markRenderDirty(reason: .styleSet(field: "loading.phase"))
            }
        self.controller = controller; scheduler?.register(controller)
    }
    private func stop() {
        if let controller { controller.cancel(); scheduler?.unregister(controller) }
        controller = nil; phase = 0
        node?.markRenderDirty(reason: .styleSet(field: "loading.phase"))
    }
}
