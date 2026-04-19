public struct RenderPassNode: Sendable, Hashable {
    public let name: String
    public let reads: [String]
    public let writes: [String]

    public init(name: String, reads: [String] = [], writes: [String] = []) {
        self.name = name
        self.reads = reads
        self.writes = writes
    }
}

public struct RenderGraphPlan: Sendable {
    public let orderedPasses: [RenderPassNode]
}

public final class RenderGraph {
    private var passes: [RenderPassNode] = []

    public init() {}

    public func addPass(_ pass: RenderPassNode) {
        passes.append(pass)
    }

    public func clear() {
        passes.removeAll(keepingCapacity: true)
    }

    public func compile() -> RenderGraphPlan {
        RenderGraphPlan(orderedPasses: passes)
    }
}
