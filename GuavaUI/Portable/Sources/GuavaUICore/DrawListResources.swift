/// Ownership carried with cached geometry and cross-thread snapshots. A
/// renderer may borrow these resources until it has submitted the draw list.
public struct DrawListResources: Sendable {
    private var retained: [any AnyObject & Sendable] = []
    private var identities: Set<ObjectIdentifier> = []

    public init() {}
    public var count: Int { retained.count }

    public mutating func retain(_ resource: any AnyObject & Sendable) {
        if identities.insert(ObjectIdentifier(resource)).inserted { retained.append(resource) }
    }
    public mutating func append(_ other: Self) {
        for resource in other.retained { retain(resource) }
    }
    /// Inspect owned resources without exposing or mutating the ownership list.
    public func forEach<T>(of type: T.Type, _ visit: (T) throws -> Void) rethrows where T: AnyObject, T: Sendable {
        for resource in retained { if let value = resource as? T { try visit(value) } }
    }

    public mutating func reset() {
        retained.removeAll(keepingCapacity: true)
        identities.removeAll(keepingCapacity: true)
    }
}
