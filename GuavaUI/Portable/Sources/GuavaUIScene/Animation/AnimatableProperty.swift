import GuavaUICore
import Foundation

private enum _AnimatablePropertyAttachmentKey {
    static let registry = "__guava_animatable_property_registry"
}

private final class _WeakAnimationControllerBox {
    weak var controller: (any AnyAnimationController)?
    weak var scheduler: AnimatorScheduler?

    init(_ controller: (any AnyAnimationController)?) {
        self.controller = controller
        scheduler = AnimatorScheduler.current
    }
}

/// Per-node registry for active per-property animation controllers.
///
/// `Node.animatableSet` uses this to cancel a previous controller when the
/// same property is retargeted before completion, matching the Phase 8 rule
/// that new animations start from the current instantaneous value and older
/// ones are discarded.
final class AnimatablePropertyRegistry: NodeResource {
    private var controllers: [AnyHashable: _WeakAnimationControllerBox] = [:]
    func mount(node: Node) {}
    func unmount(node: Node) {
        for box in controllers.values {
            if let controller = box.controller { controller.cancel(); box.scheduler?.unregister(controller) }
        }
        controllers.removeAll()
    }

    func replaceController(for propertyKey: AnyHashable,
                           with controller: (any AnyAnimationController)?) {
        if let existing = controllers[propertyKey]?.controller {
            existing.cancel()
            controllers[propertyKey]?.scheduler?.unregister(existing)
        }

        if let controller {
            controllers[propertyKey] = _WeakAnimationControllerBox(controller)
        } else {
            controllers.removeValue(forKey: propertyKey)
        }
    }

    /// The controller currently driving `propertyKey`, if it is still alive
    /// and unfinished. Peeked rather than taken: the successor reads the
    /// outgoing controller's motion *before* replacing it, so the rate is
    /// still there.
    func liveController(for propertyKey: AnyHashable) -> (any AnyAnimationController)? {
        guard let box = controllers[propertyKey], let controller = box.controller,
              !controller.isFinished else {
            controllers.removeValue(forKey: propertyKey)
            return nil
        }
        return controller
    }

    func hasActiveController(for propertyKey: AnyHashable) -> Bool {
        guard let box = controllers[propertyKey] else { return false }
        guard let controller = box.controller, !controller.isFinished else {
            controllers.removeValue(forKey: propertyKey)
            return false
        }
        return true
    }
}

extension Node {
    private var existingAnimatablePropertyRegistry: AnimatablePropertyRegistry? {
        attachments[_AnimatablePropertyAttachmentKey.registry] as? AnimatablePropertyRegistry
    }

    private var animatablePropertyRegistry: AnimatablePropertyRegistry {
        if let existing = attachments[_AnimatablePropertyAttachmentKey.registry] as? AnimatablePropertyRegistry {
            return existing
        }
        let created = AnimatablePropertyRegistry()
        attachments[_AnimatablePropertyAttachmentKey.registry] = created
        addResource(created)
        return created
    }

    func replaceAnimationController(for propertyKey: AnyHashable,
                                    with controller: (any AnyAnimationController)?) {
        guard controller != nil || existingAnimatablePropertyRegistry != nil else {
            return
        }
        animatablePropertyRegistry.replaceController(for: propertyKey, with: controller)
    }

    func hasAnimationController(for propertyKey: AnyHashable) -> Bool {
        existingAnimatablePropertyRegistry?.hasActiveController(for: propertyKey) ?? false
    }

    func inheritMotion<Value>(for propertyKey: AnyHashable, into controller: AnimationController<Value>) {
        if let previous = existingAnimatablePropertyRegistry?.liveController(for: propertyKey) as? AnimationController<Value> {
            controller.inheritMotion(from: previous)
        }
    }
    func continuesAnimation<Value: Interpolatable & Equatable>(for propertyKey: AnyHashable, to target: Value) -> Bool {
        guard !prefersReducedMotion, !ActiveAnimationContext.disablesAnimations,
              let controller = existingAnimatablePropertyRegistry?.liveController(for: propertyKey) as? AnimationController<Value>
        else { return false }
        return controller.to == target
    }
    func finishesReducedAnimation<Value: Interpolatable & Equatable>(for propertyKey: AnyHashable, to target: Value) -> Bool {
        guard prefersReducedMotion,
              let controller = existingAnimatablePropertyRegistry?.liveController(for: propertyKey) as? AnimationController<Value>,
              controller.to == target else { return false }
        controller.finishImmediately()
        replaceAnimationController(for: propertyKey, with: nil)
        return true
    }

}
