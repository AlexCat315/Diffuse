public struct EntityID: Hashable, Sendable, CustomStringConvertible {
    public let index: UInt32
    public let generation: UInt32

    public init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }

    public var rawValue: UInt64 {
        (UInt64(generation) << 32) | UInt64(index)
    }

    public var description: String {
        "EntityID(index: \(index), generation: \(generation))"
    }
}

public protocol RuntimeComponent: Sendable {}
