import Foundation

private enum _AnimatablePropertyAttachmentKey {
    static let registry = "__guava_animatable_property_registry"
}

private final class _WeakAnimationControllerBox {
    weak var controller: (any AnyAnimationController)?

    init(_ controller: (any AnyAnimationController)?) {
        self.controller = controller
    }
}

/// Per-node registry for active per-property animation controllers.
///
/// `Node.animatableSet` uses this to cancel a previous controller when the
/// same property is retargeted before completion, matching the Phase 8 rule
/// that new animations start from the current instantaneous value and older
/// ones are discarded.
final class AnimatablePropertyRegistry {
    private var controllers: [AnyHashable: _WeakAnimationControllerBox] = [:]

    func replaceController(for propertyKey: AnyHashable,
                           with controller: (any AnyAnimationController)?) {
        pruneDeadEntries()
        if let existing = controllers[propertyKey]?.controller {
            existing.cancel()
        }

        if let controller {
            controllers[propertyKey] = _WeakAnimationControllerBox(controller)
        } else {
            controllers.removeValue(forKey: propertyKey)
        }
    }

    private func pruneDeadEntries() {
        controllers = controllers.filter { _, box in box.controller != nil }
    }
}

extension Node {
    private var animatablePropertyRegistry: AnimatablePropertyRegistry {
        if let existing = attachments[_AnimatablePropertyAttachmentKey.registry] as? AnimatablePropertyRegistry {
            return existing
        }
        let created = AnimatablePropertyRegistry()
        attachments[_AnimatablePropertyAttachmentKey.registry] = created
        return created
    }

    func replaceAnimationController(for propertyKey: AnyHashable,
                                    with controller: (any AnyAnimationController)?) {
        animatablePropertyRegistry.replaceController(for: propertyKey, with: controller)
    }
}