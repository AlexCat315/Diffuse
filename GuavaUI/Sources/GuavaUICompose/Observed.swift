import GuavaUIRuntime

private final class TokenBox {
    var token: AnyHashable?
}

@propertyWrapper
public struct Observed<Object: AnyObject & _ObservableObject, Value: Equatable>: DynamicProperty, _StateErased {
    @State private var _value: Value
    private let object: Object
    private let keyPath: KeyPath<Object, Value>
    private let tokenBox = TokenBox()

    public init(_ keyPath: KeyPath<Object, Value>, on object: Object) {
        self.object = object
        self.keyPath = keyPath
        self.__value = State(wrappedValue: object[keyPath: keyPath])
    }

    public var wrappedValue: Value {
        get { _value }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { self._value }, set: { self._value = $0 })
    }

    public func _wire(invalidate: @escaping () -> Void) {
        let kp = keyPath
        tokenBox.token = object._registerObserver { [weak object] in
            guard let object else { return }
            let newValue = object[keyPath: kp]
            if _value != newValue {
                _value = newValue
            }
        }
    }

    public func _copyValue(from other: _StateErased) {
        guard let other = other as? Observed<Object, Value> else { return }
        _value = other._value
    }
}
