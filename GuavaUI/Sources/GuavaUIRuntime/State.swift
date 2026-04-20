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
}
