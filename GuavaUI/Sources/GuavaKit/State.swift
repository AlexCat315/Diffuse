// `@State` and `Binding`.
//
// A view struct is recreated on every recompose, so `@State` can't store its
// value in the struct. Instead each `@State` is *linked* (before the view's body
// runs) to a persistent `StateBox` owned by the view's scope, keyed by the
// property's declaration order. Writing the value mutates that box and invalidates
// the scope, scheduling a recompose. State therefore survives recomposition while
// living entirely outside the (disposable) view value.

/// Persistent storage for one `@State`, owned by a `ViewScope`.
final class StateBox<Value> {
    var value: Value
    /// Called after a write to schedule a recompose of the owning scope.
    var onChange: () -> Void
    init(_ value: Value, onChange: @escaping () -> Void) {
        self.value = value
        self.onChange = onChange
    }
}

/// Internal hook the reconciler uses to bind a wrapper to its scope's box.
protocol _StateProperty {
    func _link(scope: ViewScope, index: Int)
}

@propertyWrapper
public struct State<Value> {
    private let initialValue: Value
    // A class holder so the (value-type) wrapper copy can be pointed at the
    // shared persistent box during linking.
    private final class Holder { var box: StateBox<Value>? }
    private let holder = Holder()

    public init(wrappedValue: Value) { self.initialValue = wrappedValue }

    public var wrappedValue: Value {
        get { holder.box?.value ?? initialValue }
        nonmutating set {
            guard let box = holder.box else { return }
            box.value = newValue
            box.onChange()
        }
    }

    public var projectedValue: Binding<Value> {
        let holder = self.holder
        let initial = self.initialValue
        return Binding(
            get: { holder.box?.value ?? initial },
            set: { newValue in
                guard let box = holder.box else { return }
                box.value = newValue
                box.onChange()
            }
        )
    }
}

extension State: _StateProperty {
    func _link(scope: ViewScope, index: Int) {
        if let existing = scope.stateBox(at: index) as? StateBox<Value> {
            holder.box = existing
        } else {
            let box = StateBox(initialValue) { [weak scope] in scope?.invalidate() }
            scope.setStateBox(box, at: index)
            holder.box = box
        }
    }
}

/// A read/write reference to a value owned elsewhere (typically `@State`).
@propertyWrapper
public struct Binding<Value> {
    private let get: () -> Value
    private let set: (Value) -> Void
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get; self.set = set
    }
    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }
    public var projectedValue: Binding<Value> { self }

    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }
}
