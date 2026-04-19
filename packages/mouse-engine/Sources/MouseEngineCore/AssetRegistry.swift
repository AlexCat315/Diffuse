public struct AssetHandle: Sendable, Hashable {
    public let id: UInt64
    public let path: String

    public init(id: UInt64, path: String) {
        self.id = id
        self.path = path
    }
}

public final class AssetRegistry {
    private var nextID: UInt64 = 1
    private var byPath: [String: AssetHandle] = [:]

    public init() {}

    @discardableResult
    public func register(path: String) -> AssetHandle {
        if let existing = byPath[path] {
            return existing
        }
        let handle = AssetHandle(id: nextID, path: path)
        nextID += 1
        byPath[path] = handle
        return handle
    }

    public func lookup(path: String) -> AssetHandle? {
        byPath[path]
    }

    public var count: Int {
        byPath.count
    }
}
