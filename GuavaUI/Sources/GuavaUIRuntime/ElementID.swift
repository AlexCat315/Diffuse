import Foundation

/// Opaque, monotonically allocated identifier for a runtime element.
///
/// Every `Node` is minted an `ElementID` at construction. Future phases of
/// the runtime rebuild key state, layout, render and input data off this id
/// instead of `ObjectIdentifier(node)`. Phase 1 only uses it as a stable
/// debug identifier surfaced through `SceneInspector`.
///
/// IDs are unique within a process for the lifetime of the host. They are
/// never recycled.
public struct ElementID: Hashable, Sendable, CustomStringConvertible {

    public let rawValue: UInt64

    @usableFromInline
    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String {
        "e\(rawValue)"
    }
}

/// Process-wide allocator for `ElementID`s. Thread-safe.
public final class IdentityAllocator: @unchecked Sendable {

    public static let shared = IdentityAllocator()

    private let lock = NSLock()
    private var next: UInt64 = 1

    public init() {}

    public func allocate() -> ElementID {
        lock.lock()
        defer { lock.unlock() }
        let value = next
        next &+= 1
        return ElementID(rawValue: value)
    }
}
