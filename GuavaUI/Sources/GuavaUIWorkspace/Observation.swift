public import GuavaUICompose

/// Views outside the workspace (activity rails, status bars) observe layout
/// changes with `Observed(\.version, on: controller)` instead of keeping their
/// own subscription.
extension WorkspaceController: _ObservableObject {
    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable {
        AnyHashable(subscribe { _ in handler() })
    }

    public func _unregisterObserver(_ token: AnyHashable) {
        if let token = token.base as? SubscriptionToken { unsubscribe(token) }
    }
}
