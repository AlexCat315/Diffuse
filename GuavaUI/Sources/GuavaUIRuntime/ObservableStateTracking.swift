import Foundation

public struct ObservableStateScope {
    public let id: ObjectIdentifier
    public let invalidate: () -> Void

    public init(id: ObjectIdentifier,
                invalidate: @escaping () -> Void) {
        self.id = id
        self.invalidate = invalidate
    }
}

public enum ObservableStateTracking {
    public typealias DependencyCleaner = (ObjectIdentifier) -> Void

    nonisolated(unsafe) private static var stack: [ObservableStateScope] = []
    nonisolated(unsafe) private static var cleaners: [DependencyCleaner] = []

    public static var current: ObservableStateScope? {
        stack.last
    }

    public static func registerDependencyCleaner(_ cleaner: @escaping DependencyCleaner) {
        cleaners.append(cleaner)
    }

    @discardableResult
    public static func withScope<R>(id: ObjectIdentifier,
                                    invalidate: @escaping () -> Void,
                                    _ body: () throws -> R) rethrows -> R {
        for cleaner in cleaners {
            cleaner(id)
        }
        stack.append(ObservableStateScope(id: id, invalidate: invalidate))
        defer { _ = stack.popLast() }
        return try body()
    }
}

public final class ObservableStateRegistrar: @unchecked Sendable {
    private struct Observer {
        var id: ObjectIdentifier
        var invalidate: () -> Void
    }

    private let lock = NSLock()
    private var observersByKey: [AnyHashable: [ObjectIdentifier: Observer]] = [:]
    private var keysByScope: [ObjectIdentifier: Set<AnyHashable>] = [:]

    public init() {
        ObservableStateTracking.registerDependencyCleaner { [weak self] scopeID in
            self?.removeDependencies(for: scopeID)
        }
    }

    public func access(_ key: AnyHashable) {
        guard let scope = ObservableStateTracking.current else { return }
        lock.withLock {
            observersByKey[key, default: [:]][scope.id] = Observer(id: scope.id,
                                                                    invalidate: scope.invalidate)
            keysByScope[scope.id, default: []].insert(key)
        }
    }

    public func invalidate(_ key: AnyHashable) {
        let observers: [Observer] = lock.withLock {
            guard let keyed = observersByKey[key] else { return [] }
            return Array(keyed.values)
        }
        for observer in observers {
            observer.invalidate()
        }
    }

    public func invalidateAll() {
        let observers = lock.withLock {
            var byScope: [ObjectIdentifier: Observer] = [:]
            for keyedObservers in observersByKey.values {
                for observer in keyedObservers.values {
                    byScope[observer.id] = observer
                }
            }
            return Array(byScope.values)
        }
        for observer in observers {
            observer.invalidate()
        }
    }

    public func removeDependencies(for scopeID: ObjectIdentifier) {
        lock.withLock {
            guard let keys = keysByScope.removeValue(forKey: scopeID) else { return }
            for key in keys {
                observersByKey[key]?.removeValue(forKey: scopeID)
                if observersByKey[key]?.isEmpty == true {
                    observersByKey.removeValue(forKey: key)
                }
            }
        }
    }
}
