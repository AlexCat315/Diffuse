// `@Observed` — subscribe to an external `_ObservableObject` and trigger
// recomposition when it changes.
//
// Works like `@State` but the source of truth lives outside the view tree
// (e.g. an `EditorStore`). On link, an observer is registered with the
// observable; on scope teardown (view removed from tree) it is unregistered
// automatically.

import Foundation

// MARK: - Protocol

/// An object that can notify observers when its state changes.
/// Mirrors the GuavaUIRuntime `_ObservableObject` protocol so types that already
/// conform there (like `EditorStore`) work with GuavaKit without changes.
public protocol _ObservableObject: AnyObject {
    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable
    func _unregisterObserver(_ token: AnyHashable)
}

// MARK: - Observed property wrapper

/// Internal hook the reconciler uses to bind an `@Observed` wrapper to its scope.
protocol _ObservedProperty {
    func _linkObserved(scope: ViewScope)
}

@propertyWrapper
public struct Observed<Object: _ObservableObject> {
    private let initialValue: Object

    // Holders so the link can wire things after init.
    private final class Holder {
        var object: Object?
        var token: AnyHashable?
        weak var scope: ViewScope?
        init(object: Object) { self.object = object }
        deinit {
            guard let object, let token else { return }
            object._unregisterObserver(token)
        }
    }
    private let holder: Holder

    public init(wrappedValue: Object) {
        self.initialValue = wrappedValue
        self.holder = Holder(object: wrappedValue)
    }

    public var wrappedValue: Object {
        get { holder.object ?? initialValue }
        nonmutating set {
            holder.object = newValue
            // Re-register if already linked.
            if let scope = holder.scope, let oldToken = holder.token {
                holder.object?._unregisterObserver(oldToken)
                holder.token = newValue._registerObserver { [weak scope] in
                    scope?.invalidate()
                }
            }
        }
    }

    /// Registers a store observer that invalidates the scope on change.
    fileprivate func _link(scope: ViewScope) {
        holder.scope = scope
        holder.token = wrappedValue._registerObserver { [weak scope] in
            scope?.invalidate()
        }
    }
}

extension Observed: _ObservedProperty {
    func _linkObserved(scope: ViewScope) {
        _link(scope: scope)
    }
}
