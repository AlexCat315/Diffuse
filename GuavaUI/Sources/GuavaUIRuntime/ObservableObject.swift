import Foundation

public protocol _ObservableObject: AnyObject {
    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable
    func _unregisterObserver(_ token: AnyHashable)
}

public final class _ObservablePublisher<Root: AnyObject> {
    private var observers: [AnyHashable: () -> Void] = [:]
    private var nextKey: UInt64 = 0

    public init() {}

    public func register(on root: Root, handler: @escaping () -> Void) -> AnyHashable {
        let key = AnyHashable(nextKey)
        nextKey &+= 1
        observers[key] = handler
        return key
    }

    public func unregister(_ token: AnyHashable) {
        observers.removeValue(forKey: token)
    }

    public func send() {
        for handler in observers.values { handler() }
    }
}
