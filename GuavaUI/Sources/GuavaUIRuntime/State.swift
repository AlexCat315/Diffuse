import Foundation

// MARK: - Backing store

/// Reference-type storage for a `@State` property.
///
/// `@usableFromInline` so the compiler can inline `State`'s accessors
/// while keeping the type internal (not part of the public API surface).
@usableFromInline
final class StateStorage<Value>: @unchecked Sendable {
    var value: Value
    /// Called immediately after `value` is mutated. Wired by the composition scope.
    var onChange: (() -> Void)?

    init(value: Value) {
        self.value = value
    }
}

// MARK: - @State

/// A property wrapper for view-local mutable state.
///
/// Writing `wrappedValue` fires `StateStorage.onChange`, which the composition
/// runtime connects to `Recomposer.invalidate(scopeID:body:)`.
///
/// ```swift
/// @State var count = 0
/// Button("Tap") { count += 1 }   // triggers recompose of the owning scope
/// ```
@propertyWrapper
public struct State<Value>: DynamicProperty {

    @usableFromInline
    internal let _storage: StateStorage<Value>

    public init(wrappedValue: Value) {
        _storage = StateStorage(value: wrappedValue)
    }

    public var wrappedValue: Value {
        get { _storage.value }
        nonmutating set {
            _storage.value = newValue
            _storage.onChange?()
        }
    }

    /// Use `$property` to pass a `Binding` to child views.
    public var projectedValue: Binding<Value> {
        Binding(
            get: { self._storage.value },
            set: { newValue in
                self._storage.value = newValue
                self._storage.onChange?()
            }
        )
    }

    // MARK: - ViewGraph escape hatch (Phase 6.2)

    /// Identity of the underlying storage — `ViewGraph` uses this as a stable
    /// scope key across body re-evaluations.
    public var _storageIdentity: ObjectIdentifier {
        ObjectIdentifier(_storage)
    }

    /// Install (or clear) the change observer. `ViewGraph` wires this to
    /// `Recomposer.invalidate` so writes trigger a recompose.
    public func _setOnChange(_ handler: (() -> Void)?) {
        _storage.onChange = handler
    }

    /// Copy the underlying value from `other` into this state's storage,
    /// without firing `onChange`. Used by `ViewGraph` when a parent recompose
    /// produces a new view value at the same slot — the new view's @State
    /// would otherwise reset to its initial value.
    public func _copyRuntimeValue(from other: State<Value>) {
        _storage.value = other._storage.value
    }
}

// MARK: - Sendable

// State is Sendable when the wrapped value is. StateStorage is already
// @unchecked Sendable, and writes are safe from any thread because
// StateStorage propagates through the recomposer (main-thread queue).
extension State: @unchecked Sendable where Value: Sendable {}
