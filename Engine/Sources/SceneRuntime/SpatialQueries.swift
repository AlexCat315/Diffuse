import EngineKernel
import SIMDCompat

public struct SpatialAABB: Sendable, Equatable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    public init(center: SIMD3<Float>, halfExtents: SIMD3<Float>) {
        self.init(min: center - halfExtents, max: center + halfExtents)
    }

    public var center: SIMD3<Float> {
        (min + max) * 0.5
    }

    public var halfExtents: SIMD3<Float> {
        (max - min) * 0.5
    }

    public var isValid: Bool {
        min.x <= max.x && min.y <= max.y && min.z <= max.z
    }

    public var surfaceArea: Float {
        let extents = max - min
        return 2 * (extents.x * extents.y + extents.y * extents.z + extents.z * extents.x)
    }

    public func intersects(_ other: SpatialAABB) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x &&
        min.y <= other.max.y && max.y >= other.min.y &&
        min.z <= other.max.z && max.z >= other.min.z
    }

    public func merged(with other: SpatialAABB) -> SpatialAABB {
        SpatialAABB(min: simd_min(min, other.min), max: simd_max(max, other.max))
    }
}

public struct SpatialIndexEntry: Sendable, Equatable {
    public var entity: EntityID
    public var shape: ColliderShape
    public var meshGeometry: MeshColliderGeometry?
    public var worldTransform: WorldTransform
    public var bounds: SpatialAABB
    public var isTrigger: Bool
    public var layerID: UInt16
    public var layerMask: UInt16

    public init(entity: EntityID,
                shape: ColliderShape,
                meshGeometry: MeshColliderGeometry? = nil,
                worldTransform: WorldTransform,
                bounds: SpatialAABB,
                isTrigger: Bool,
                layerID: UInt16,
                layerMask: UInt16) {
        self.entity = entity
        self.shape = shape
        self.meshGeometry = meshGeometry
        self.worldTransform = worldTransform
        self.bounds = bounds
        self.isTrigger = isTrigger
        self.layerID = layerID
        self.layerMask = layerMask
    }
}

public struct SpatialBVHBuildConfig: Sendable, Equatable {
    public var leafSize: Int
    public var sahSampleCount: Int
    public var rebuildThreshold: Float

    public init(leafSize: Int = 8, sahSampleCount: Int = 16, rebuildThreshold: Float = 0.35) {
        self.leafSize = max(1, leafSize)
        self.sahSampleCount = max(1, sahSampleCount)
        self.rebuildThreshold = min(max(rebuildThreshold, 0), 1)
    }

    public static func adaptive(forEntryCount entryCount: Int) -> SpatialBVHBuildConfig {
        switch entryCount {
        case 0..<256:
            return SpatialBVHBuildConfig(leafSize: 6, sahSampleCount: 12, rebuildThreshold: 0.45)
        case 256..<4_096:
            return SpatialBVHBuildConfig(leafSize: 8, sahSampleCount: 16, rebuildThreshold: 0.35)
        default:
            return SpatialBVHBuildConfig(leafSize: 12, sahSampleCount: 24, rebuildThreshold: 0.25)
        }
    }
}

public struct SpatialIndexBuildSettings: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case adaptive
        case custom(SpatialBVHBuildConfig)
    }

    public var mode: Mode

    public init(mode: Mode = .adaptive) {
        self.mode = mode
    }

    public func resolvedConfig(entryCount: Int) -> SpatialBVHBuildConfig {
        switch mode {
        case .adaptive:
            return .adaptive(forEntryCount: entryCount)
        case let .custom(config):
            return config
        }
    }
}

public struct MeshColliderBoundsResource: Sendable, Equatable {
    public var boundsByResourceID: [String: SpatialAABB]
    public var defaultBounds: SpatialAABB?

    public init(boundsByResourceID: [String: SpatialAABB] = [:],
                defaultBounds: SpatialAABB? = nil) {
        self.boundsByResourceID = boundsByResourceID
        self.defaultBounds = defaultBounds
    }

    public func bounds(for resourceID: String?) -> SpatialAABB? {
        if let resourceID, let bounds = boundsByResourceID[resourceID] {
            return bounds
        }
        return defaultBounds
    }
}

public struct MeshColliderGeometry: Sendable, Equatable {
    public var positions: [SIMD3<Float>]
    public var triangleIndices: [UInt32]
    public var localBounds: SpatialAABB

    public init(positions: [SIMD3<Float>],
                triangleIndices: [UInt32],
                localBounds: SpatialAABB? = nil) {
        self.positions = positions
        self.triangleIndices = triangleIndices
        self.localBounds = localBounds ?? Self.computeBounds(positions)
    }

    public var triangleCount: Int {
        triangleIndices.count / 3
    }

    private static func computeBounds(_ positions: [SIMD3<Float>]) -> SpatialAABB {
        guard var minValue = positions.first else {
            return SpatialAABB(min: .zero, max: .zero)
        }
        var maxValue = minValue
        for position in positions.dropFirst() {
            minValue = simd_min(minValue, position)
            maxValue = simd_max(maxValue, position)
        }
        return SpatialAABB(min: minValue, max: maxValue)
    }
}

public struct MeshColliderGeometryResource: Sendable, Equatable {
    public var geometryByResourceID: [String: MeshColliderGeometry]
    public var defaultGeometry: MeshColliderGeometry?

    public init(geometryByResourceID: [String: MeshColliderGeometry] = [:],
                defaultGeometry: MeshColliderGeometry? = nil) {
        self.geometryByResourceID = geometryByResourceID
        self.defaultGeometry = defaultGeometry
    }

    public func geometry(for resourceID: String?) -> MeshColliderGeometry? {
        if let resourceID, let geometry = geometryByResourceID[resourceID] {
            return geometry
        }
        return defaultGeometry
    }
}

public struct SpatialQueryStats: Sendable, Equatable {
    public var nodeVisits: Int
    public var leafTests: Int
    public var narrowPhaseTests: Int

    public init(nodeVisits: Int = 0,
                leafTests: Int = 0,
                narrowPhaseTests: Int = 0) {
        self.nodeVisits = nodeVisits
        self.leafTests = leafTests
        self.narrowPhaseTests = narrowPhaseTests
    }
}

private enum SpatialIndexEntryChange: Sendable {
    case entityMismatch
    case boundsChanged(Int)
}

public final class SpatialQueryScratch: @unchecked Sendable {
    fileprivate var sceneOverlapHitsBuffer: [SceneOverlapHit] = []
    fileprivate var physicsOverlapHitsBuffer: [PhysicsOverlapHit] = []
    fileprivate var overflowNodeStack: [Int] = []

    public init() {}

    fileprivate func resetTraversalOverflow() {
        overflowNodeStack.removeAll(keepingCapacity: true)
    }
}

final class SpatialQueryStatsRecorder {
    var stats = SpatialQueryStats()

    func recordNodeVisit() {
        stats.nodeVisits += 1
    }

    func recordLeafTest() {
        stats.leafTests += 1
    }

    func recordNarrowPhaseTest() {
        stats.narrowPhaseTests += 1
    }
}

public struct SpatialIndexResource: Sendable, Equatable {
    public var entries: [SpatialIndexEntry]
    public var sourceRevision: UInt64
    public var buildConfig: SpatialBVHBuildConfig
    var bvh: SpatialBVH

    public init(entries: [SpatialIndexEntry] = [],
                sourceRevision: UInt64 = 0,
                buildConfig: SpatialBVHBuildConfig = SpatialBVHBuildConfig()) {
        self.entries = entries
        self.sourceRevision = sourceRevision
        self.buildConfig = buildConfig
        bvh = SpatialBVH(entries: entries, buildConfig: buildConfig)
    }

    func updated(entries newEntries: [SpatialIndexEntry],
                 sourceRevision: UInt64) -> SpatialIndexResource {
        updated(entries: newEntries, sourceRevision: sourceRevision, using: .shared).resource
    }

    func updated(
        entries newEntries: [SpatialIndexEntry],
        sourceRevision: UInt64,
        using jobSystem: JobSystem
    ) -> (resource: SpatialIndexResource, report: JobDispatchReport) {
        guard newEntries.count == entries.count,
              !newEntries.isEmpty else {
            return (
                SpatialIndexResource(entries: newEntries,
                                     sourceRevision: sourceRevision,
                                     buildConfig: buildConfig),
                JobDispatchReport(jobCount: 0, workerCount: jobSystem.workerCount, executedInParallel: false)
            )
        }

        let changes = jobSystem.parallelCompactMap(items: Array(newEntries.indices)) { index -> SpatialIndexEntryChange? in
            if entries[index].entity != newEntries[index].entity {
                return .entityMismatch
            }
            if entries[index].bounds != newEntries[index].bounds {
                return .boundsChanged(index)
            }
            return nil
        }

        guard !changes.0.contains(where: {
            if case .entityMismatch = $0 { return true }
            return false
        }) else {
            return (
                SpatialIndexResource(entries: newEntries,
                                     sourceRevision: sourceRevision,
                                     buildConfig: buildConfig),
                changes.1
            )
        }

        let changedEntryIndices = changes.0.compactMap { change -> Int? in
            if case let .boundsChanged(index) = change {
                return index
            }
            return nil
        }

        if changedEntryIndices.isEmpty {
            var next = self
            next.entries = newEntries
            next.sourceRevision = sourceRevision
            return (next, changes.1)
        }

        let changedRatio = Float(changedEntryIndices.count) / Float(newEntries.count)
        var next = self
        next.entries = newEntries
        next.sourceRevision = sourceRevision

        if changedRatio >= buildConfig.rebuildThreshold {
            let rebuilt = next.bvh.rebuildDirtySubtrees(entries: newEntries,
                                                        changedEntryIndices: changedEntryIndices,
                                                        triggerRatio: buildConfig.rebuildThreshold)
            if rebuilt {
                return (next, changes.1)
            }
            return (
                SpatialIndexResource(entries: newEntries,
                                     sourceRevision: sourceRevision,
                                     buildConfig: buildConfig),
                changes.1
            )
        }

        next.bvh.refit(entries: newEntries, changedEntryIndices: changedEntryIndices)
        return (next, changes.1)
    }
}

struct SpatialBVHNode: Sendable, Equatable {
    var bounds: SpatialAABB
    var leftChild: Int
    var rightChild: Int
    var start: Int
    var count: Int

    var isLeaf: Bool {
        count > 0
    }
}

struct SpatialBVHStorage: Sendable, Equatable {
    private(set) var minX: [Float] = []
    private(set) var minY: [Float] = []
    private(set) var minZ: [Float] = []
    private(set) var maxX: [Float] = []
    private(set) var maxY: [Float] = []
    private(set) var maxZ: [Float] = []
    private(set) var leftChild: [Int] = []
    private(set) var rightChild: [Int] = []
    private(set) var start: [Int] = []
    private(set) var count: [Int] = []

    mutating func rebuild(from nodes: [SpatialBVHNode]) {
        let nodeCount = nodes.count
        minX.removeAll(keepingCapacity: true)
        minY.removeAll(keepingCapacity: true)
        minZ.removeAll(keepingCapacity: true)
        maxX.removeAll(keepingCapacity: true)
        maxY.removeAll(keepingCapacity: true)
        maxZ.removeAll(keepingCapacity: true)
        leftChild.removeAll(keepingCapacity: true)
        rightChild.removeAll(keepingCapacity: true)
        start.removeAll(keepingCapacity: true)
        count.removeAll(keepingCapacity: true)

        minX.reserveCapacity(nodeCount)
        minY.reserveCapacity(nodeCount)
        minZ.reserveCapacity(nodeCount)
        maxX.reserveCapacity(nodeCount)
        maxY.reserveCapacity(nodeCount)
        maxZ.reserveCapacity(nodeCount)
        leftChild.reserveCapacity(nodeCount)
        rightChild.reserveCapacity(nodeCount)
        start.reserveCapacity(nodeCount)
        count.reserveCapacity(nodeCount)

        for node in nodes {
            minX.append(node.bounds.min.x)
            minY.append(node.bounds.min.y)
            minZ.append(node.bounds.min.z)
            maxX.append(node.bounds.max.x)
            maxY.append(node.bounds.max.y)
            maxZ.append(node.bounds.max.z)
            leftChild.append(node.leftChild)
            rightChild.append(node.rightChild)
            start.append(node.start)
            count.append(node.count)
        }
    }

    func isLeaf(_ nodeIndex: Int) -> Bool {
        count[nodeIndex] > 0
    }

    func rangeStart(_ nodeIndex: Int) -> Int {
        start[nodeIndex]
    }

    func rangeCount(_ nodeIndex: Int) -> Int {
        count[nodeIndex]
    }

    func left(_ nodeIndex: Int) -> Int {
        leftChild[nodeIndex]
    }

    func right(_ nodeIndex: Int) -> Int {
        rightChild[nodeIndex]
    }

    func intersects(nodeIndex: Int, bounds: SpatialAABB) -> Bool {
        minX[nodeIndex] <= bounds.max.x && maxX[nodeIndex] >= bounds.min.x &&
        minY[nodeIndex] <= bounds.max.y && maxY[nodeIndex] >= bounds.min.y &&
        minZ[nodeIndex] <= bounds.max.z && maxZ[nodeIndex] >= bounds.min.z
    }

}

struct SpatialBVH: Sendable, Equatable {
    private static let traversalStackCapacity = 128

    private(set) var nodes: [SpatialBVHNode] = []
    private(set) var soa = SpatialBVHStorage()
    private(set) var orderedEntryIndices: [Int] = []
    private(set) var parentNodeIndices: [Int] = []
    private(set) var leafNodeByEntryIndex: [Int] = []
    private let leafSize: Int
    private let sahSampleCount: Int

    init(entries: [SpatialIndexEntry], buildConfig: SpatialBVHBuildConfig) {
        self.leafSize = max(1, buildConfig.leafSize)
        self.sahSampleCount = max(1, buildConfig.sahSampleCount)
        guard !entries.isEmpty else { return }

        orderedEntryIndices = Array(entries.indices)
        leafNodeByEntryIndex = Array(repeating: -1, count: entries.count)
        _ = buildNode(entries: entries, start: 0, count: entries.count, parent: -1)
        soa.rebuild(from: nodes)
    }

    mutating func refit(entries: [SpatialIndexEntry], changedEntryIndices: [Int]) {
        guard !nodes.isEmpty, !changedEntryIndices.isEmpty else { return }

        var dirtyLeafNodes = Set<Int>()
        for entryIndex in changedEntryIndices {
            guard entryIndex >= 0, entryIndex < leafNodeByEntryIndex.count else { continue }
            let leafNode = leafNodeByEntryIndex[entryIndex]
            guard leafNode >= 0 else { continue }
            dirtyLeafNodes.insert(leafNode)
        }
        guard !dirtyLeafNodes.isEmpty else { return }

        for leafNode in dirtyLeafNodes {
            var merged: SpatialAABB?
            let node = nodes[leafNode]
            for offset in 0..<node.count {
                let entryIndex = orderedEntryIndices[node.start + offset]
                let bounds = entries[entryIndex].bounds
                merged = merged.map { $0.merged(with: bounds) } ?? bounds
            }
            if let merged {
                nodes[leafNode].bounds = merged
            }
        }

        var frontier = Array(dirtyLeafNodes)
        var queued = dirtyLeafNodes

        while let nodeIndex = frontier.popLast() {
            let parent = parentNodeIndices[nodeIndex]
            guard parent >= 0 else { continue }
            guard nodes[parent].leftChild >= 0, nodes[parent].rightChild >= 0 else { continue }

            let leftBounds = nodes[nodes[parent].leftChild].bounds
            let rightBounds = nodes[nodes[parent].rightChild].bounds
            let merged = leftBounds.merged(with: rightBounds)
            if merged != nodes[parent].bounds {
                nodes[parent].bounds = merged
            }

            if queued.insert(parent).inserted {
                frontier.append(parent)
            }
        }

        soa.rebuild(from: nodes)
    }

    mutating func rebuildDirtySubtrees(entries: [SpatialIndexEntry],
                                       changedEntryIndices: [Int],
                                       triggerRatio: Float) -> Bool {
        guard !nodes.isEmpty, !changedEntryIndices.isEmpty else { return true }
        let boundedTrigger = min(max(triggerRatio, 0), 1)

        var dirtyLeafNodes = Set<Int>()
        for entryIndex in changedEntryIndices {
            guard entryIndex >= 0, entryIndex < leafNodeByEntryIndex.count else { continue }
            let leafNode = leafNodeByEntryIndex[entryIndex]
            guard leafNode >= 0 else { continue }
            dirtyLeafNodes.insert(leafNode)
        }
        guard !dirtyLeafNodes.isEmpty else { return true }

        var subtreeItemCounts = Array(repeating: 0, count: nodes.count)
        _ = computeSubtreeItemCounts(nodeIndex: 0, into: &subtreeItemCounts)

        var dirtyCountByNode = Array(repeating: 0, count: nodes.count)
        for leafNode in dirtyLeafNodes {
            var cursor = leafNode
            while cursor >= 0 {
                dirtyCountByNode[cursor] += 1
                cursor = parentNodeIndices[cursor]
            }
        }

        var rebuildRoots: [Int] = []
        for nodeIndex in 0..<nodes.count {
            let dirtyCount = dirtyCountByNode[nodeIndex]
            guard dirtyCount > 0 else { continue }

            let subtreeItems = max(subtreeItemCounts[nodeIndex], 1)
            let ratio = Float(dirtyCount) / Float(subtreeItems)
            guard ratio >= boundedTrigger else { continue }

            let parent = parentNodeIndices[nodeIndex]
            if parent >= 0 {
                let parentItems = max(subtreeItemCounts[parent], 1)
                let parentRatio = Float(dirtyCountByNode[parent]) / Float(parentItems)
                if parentRatio >= boundedTrigger {
                    continue
                }
            }
            rebuildRoots.append(nodeIndex)
        }

        if rebuildRoots.isEmpty {
            refit(entries: entries, changedEntryIndices: changedEntryIndices)
            return true
        }

        for root in rebuildRoots {
            guard rebuildSubtree(rootNode: root, entries: entries) else {
                return false
            }
        }

        var frontier = rebuildRoots
        var queued = Set(rebuildRoots)
        while let nodeIndex = frontier.popLast() {
            let parent = parentNodeIndices[nodeIndex]
            guard parent >= 0 else { continue }
            guard nodes[parent].leftChild >= 0, nodes[parent].rightChild >= 0 else { continue }

            let leftBounds = nodes[nodes[parent].leftChild].bounds
            let rightBounds = nodes[nodes[parent].rightChild].bounds
            nodes[parent].bounds = leftBounds.merged(with: rightBounds)

            if queued.insert(parent).inserted {
                frontier.append(parent)
            }
        }

        soa.rebuild(from: nodes)
        return true
    }

    func forEachOverlapping(_ bounds: SpatialAABB,
                            scratch: SpatialQueryScratch? = nil,
                            statsRecorder: SpatialQueryStatsRecorder? = nil,
                            _ body: (Int) -> Void) {
        guard !nodes.isEmpty else { return }

        scratch?.resetTraversalOverflow()
        var localOverflowNodeStack: [Int] = []

        withUnsafeTemporaryAllocation(of: Int.self, capacity: Self.traversalStackCapacity) { stack in
            var stackSize = 1
            stack[0] = 0

            func push(_ nodeIndex: Int) {
                if stackSize < stack.count {
                    stack[stackSize] = nodeIndex
                    stackSize += 1
                    return
                }

                if let scratch {
                    scratch.overflowNodeStack.append(nodeIndex)
                } else {
                    localOverflowNodeStack.append(nodeIndex)
                }
            }

            func pop() -> Int? {
                if stackSize > 0 {
                    stackSize -= 1
                    return stack[stackSize]
                }

                if let scratch {
                    return scratch.overflowNodeStack.popLast()
                }
                return localOverflowNodeStack.popLast()
            }

            while let nodeIndex = pop() {
                statsRecorder?.recordNodeVisit()
                guard soa.intersects(nodeIndex: nodeIndex, bounds: bounds) else { continue }

                if soa.isLeaf(nodeIndex) {
                    statsRecorder?.recordLeafTest()
                    let start = soa.rangeStart(nodeIndex)
                    let count = soa.rangeCount(nodeIndex)
                    for offset in 0..<count {
                        body(orderedEntryIndices[start + offset])
                    }
                    continue
                }

                let leftChild = soa.left(nodeIndex)
                let rightChild = soa.right(nodeIndex)
                if leftChild >= 0 {
                    push(leftChild)
                }
                if rightChild >= 0 {
                    push(rightChild)
                }
            }
        }
    }

    /// Like `forEachOverlapping` but the body returns `false` to stop traversal early.
    /// When stopped early the overflow scratch is left dirty; it is reset on the next query.
    func forEachOverlappingWhile(_ bounds: SpatialAABB,
                                 scratch: SpatialQueryScratch? = nil,
                                 statsRecorder: SpatialQueryStatsRecorder? = nil,
                                 _ body: (Int) -> Bool) {
        guard !nodes.isEmpty else { return }

        scratch?.resetTraversalOverflow()
        var localOverflowNodeStack: [Int] = []
        var stopped = false

        withUnsafeTemporaryAllocation(of: Int.self, capacity: Self.traversalStackCapacity) { stack in
            var stackSize = 1
            stack[0] = 0

            func push(_ nodeIndex: Int) {
                if stackSize < stack.count {
                    stack[stackSize] = nodeIndex
                    stackSize += 1
                    return
                }
                if let scratch {
                    scratch.overflowNodeStack.append(nodeIndex)
                } else {
                    localOverflowNodeStack.append(nodeIndex)
                }
            }

            func pop() -> Int? {
                if stackSize > 0 {
                    stackSize -= 1
                    return stack[stackSize]
                }
                if let scratch {
                    return scratch.overflowNodeStack.popLast()
                }
                return localOverflowNodeStack.popLast()
            }

            while !stopped, let nodeIndex = pop() {
                statsRecorder?.recordNodeVisit()
                guard soa.intersects(nodeIndex: nodeIndex, bounds: bounds) else { continue }

                if soa.isLeaf(nodeIndex) {
                    statsRecorder?.recordLeafTest()
                    let start = soa.rangeStart(nodeIndex)
                    let count = soa.rangeCount(nodeIndex)
                    for offset in 0..<count {
                        if !body(orderedEntryIndices[start + offset]) {
                            stopped = true
                            break
                        }
                    }
                    continue
                }

                let leftChild = soa.left(nodeIndex)
                let rightChild = soa.right(nodeIndex)
                if leftChild >= 0 { push(leftChild) }
                if rightChild >= 0 { push(rightChild) }
            }
        }
    }

    private mutating func buildNode(entries: [SpatialIndexEntry],
                                    start: Int,
                                    count: Int,
                                    parent: Int) -> Int {
        let bounds = combinedBounds(entries: entries, start: start, count: count)
        let nodeIndex = nodes.count
        nodes.append(
            SpatialBVHNode(bounds: bounds,
                           leftChild: -1,
                           rightChild: -1,
                           start: start,
                           count: count)
        )
        parentNodeIndices.append(parent)

        guard count > leafSize else {
            for offset in 0..<count {
                let entryIndex = orderedEntryIndices[start + offset]
                leafNodeByEntryIndex[entryIndex] = nodeIndex
            }
            return nodeIndex
        }

        let axis = splitAxis(entries: entries, start: start, count: count)
        let lowerBound = start
        let upperBound = start + count
        orderedEntryIndices[lowerBound..<upperBound].sort { lhs, rhs in
            entries[lhs].bounds.center[axis] < entries[rhs].bounds.center[axis]
        }

        let leafCost = Float(count)
        let parentArea = max(bounds.surfaceArea, 0.000_001)
        let splitSamples = min(sahSampleCount, count - 1)
        var bestSplit: Int?
        var bestCost = Float.greatestFiniteMagnitude

        if splitSamples > 0 {
            for sample in 1...splitSamples {
                let split = start + (sample * count) / (splitSamples + 1)
                if split <= start || split >= start + count {
                    continue
                }

                let leftBounds = combinedBounds(entries: entries, range: start..<split)
                let rightBounds = combinedBounds(entries: entries, range: split..<(start + count))
                let leftCount = split - start
                let rightCount = count - leftCount
                let sahCost = 1 +
                    (leftBounds.surfaceArea / parentArea) * Float(leftCount) +
                    (rightBounds.surfaceArea / parentArea) * Float(rightCount)

                if sahCost < bestCost {
                    bestCost = sahCost
                    bestSplit = split
                }
            }
        }

        guard let splitIndex = bestSplit, bestCost < leafCost else {
            return nodeIndex
        }

        let leftCount = splitIndex - start
        let rightCount = count - leftCount
        let leftChild = buildNode(entries: entries,
                      start: start,
                      count: leftCount,
                      parent: nodeIndex)
        let rightChild = buildNode(entries: entries,
                       start: splitIndex,
                       count: rightCount,
                       parent: nodeIndex)

        nodes[nodeIndex] = SpatialBVHNode(bounds: bounds,
                                          leftChild: leftChild,
                                          rightChild: rightChild,
                                          start: start,
                                          count: 0)
        return nodeIndex
    }

    private mutating func rebuildSubtree(rootNode: Int,
                                         entries: [SpatialIndexEntry]) -> Bool {
        let rangeStart = nodes[rootNode].start
        let rangeCount = subtreeItemCount(nodeIndex: rootNode)
        guard rangeCount > 0 else {
            nodes[rootNode].leftChild = -1
            nodes[rootNode].rightChild = -1
            nodes[rootNode].count = 0
            return true
        }

        var reusableNodes = collectSubtreeNodes(rootNode: rootNode)
        reusableNodes.removeAll { $0 == rootNode }
        var reuseCursor = 0

        let rebuilt = rebuildSubtreeInPlace(nodeIndex: rootNode,
                                            start: rangeStart,
                                            count: rangeCount,
                                            parent: parentNodeIndices[rootNode],
                                            entries: entries,
                                            reusableNodes: &reusableNodes,
                                            reuseCursor: &reuseCursor)
        return rebuilt
    }

    private mutating func rebuildSubtreeInPlace(nodeIndex: Int,
                                                start: Int,
                                                count: Int,
                                                parent: Int,
                                                entries: [SpatialIndexEntry],
                                                reusableNodes: inout [Int],
                                                reuseCursor: inout Int) -> Bool {
        let bounds = combinedBounds(entries: entries, range: start..<(start + count))
        nodes[nodeIndex].bounds = bounds
        nodes[nodeIndex].start = start
        parentNodeIndices[nodeIndex] = parent

        guard count > leafSize else {
            nodes[nodeIndex].leftChild = -1
            nodes[nodeIndex].rightChild = -1
            nodes[nodeIndex].count = count
            for offset in 0..<count {
                let entryIndex = orderedEntryIndices[start + offset]
                leafNodeByEntryIndex[entryIndex] = nodeIndex
            }
            return true
        }

        let axis = splitAxis(entries: entries, start: start, count: count)
        orderedEntryIndices[start..<(start + count)].sort { lhs, rhs in
            entries[lhs].bounds.center[axis] < entries[rhs].bounds.center[axis]
        }

        let leafCost = Float(count)
        let parentArea = max(bounds.surfaceArea, 0.000_001)
        let splitSamples = min(sahSampleCount, count - 1)
        var bestSplit: Int?
        var bestCost = Float.greatestFiniteMagnitude

        if splitSamples > 0 {
            for sample in 1...splitSamples {
                let split = start + (sample * count) / (splitSamples + 1)
                if split <= start || split >= start + count {
                    continue
                }

                let leftBounds = combinedBounds(entries: entries, range: start..<split)
                let rightBounds = combinedBounds(entries: entries, range: split..<(start + count))
                let leftCount = split - start
                let rightCount = count - leftCount
                let sahCost = 1 +
                    (leftBounds.surfaceArea / parentArea) * Float(leftCount) +
                    (rightBounds.surfaceArea / parentArea) * Float(rightCount)

                if sahCost < bestCost {
                    bestCost = sahCost
                    bestSplit = split
                }
            }
        }

        guard let splitIndex = bestSplit, bestCost < leafCost else {
            nodes[nodeIndex].leftChild = -1
            nodes[nodeIndex].rightChild = -1
            nodes[nodeIndex].count = count
            for offset in 0..<count {
                let entryIndex = orderedEntryIndices[start + offset]
                leafNodeByEntryIndex[entryIndex] = nodeIndex
            }
            return true
        }

        let leftCount = splitIndex - start
        let rightCount = count - leftCount

        guard let leftNode = nextReusableNode(&reusableNodes, &reuseCursor),
              let rightNode = nextReusableNode(&reusableNodes, &reuseCursor) else {
            return false
        }

        nodes[nodeIndex].leftChild = leftNode
        nodes[nodeIndex].rightChild = rightNode
        nodes[nodeIndex].count = 0

        guard rebuildSubtreeInPlace(nodeIndex: leftNode,
                                    start: start,
                                    count: leftCount,
                                    parent: nodeIndex,
                                    entries: entries,
                                    reusableNodes: &reusableNodes,
                                    reuseCursor: &reuseCursor) else {
            return false
        }
        guard rebuildSubtreeInPlace(nodeIndex: rightNode,
                                    start: splitIndex,
                                    count: rightCount,
                                    parent: nodeIndex,
                                    entries: entries,
                                    reusableNodes: &reusableNodes,
                                    reuseCursor: &reuseCursor) else {
            return false
        }

        return true
    }

    private func nextReusableNode(_ reusableNodes: inout [Int], _ cursor: inout Int) -> Int? {
        guard cursor < reusableNodes.count else { return nil }
        let node = reusableNodes[cursor]
        cursor += 1
        return node
    }

    private func collectSubtreeNodes(rootNode: Int) -> [Int] {
        var collected: [Int] = []
        var stack: [Int] = [rootNode]
        while let nodeIndex = stack.popLast() {
            collected.append(nodeIndex)
            let left = nodes[nodeIndex].leftChild
            let right = nodes[nodeIndex].rightChild
            if left >= 0 { stack.append(left) }
            if right >= 0 { stack.append(right) }
        }
        return collected
    }

    private func subtreeItemCount(nodeIndex: Int) -> Int {
        let node = nodes[nodeIndex]
        if node.isLeaf {
            return node.count
        }
        var total = 0
        if node.leftChild >= 0 {
            total += subtreeItemCount(nodeIndex: node.leftChild)
        }
        if node.rightChild >= 0 {
            total += subtreeItemCount(nodeIndex: node.rightChild)
        }
        return total
    }

    @discardableResult
    private func computeSubtreeItemCounts(nodeIndex: Int,
                                          into counts: inout [Int]) -> Int {
        let node = nodes[nodeIndex]
        if node.isLeaf {
            counts[nodeIndex] = node.count
            return node.count
        }

        var total = 0
        if node.leftChild >= 0 {
            total += computeSubtreeItemCounts(nodeIndex: node.leftChild, into: &counts)
        }
        if node.rightChild >= 0 {
            total += computeSubtreeItemCounts(nodeIndex: node.rightChild, into: &counts)
        }
        counts[nodeIndex] = total
        return total
    }

    private func combinedBounds(entries: [SpatialIndexEntry], start: Int, count: Int) -> SpatialAABB {
        combinedBounds(entries: entries, range: start..<(start + count))
    }

    private func combinedBounds(entries: [SpatialIndexEntry], range: Range<Int>) -> SpatialAABB {
        let first = entries[orderedEntryIndices[range.lowerBound]].bounds
        guard range.count > 1 else { return first }

        var merged = first
        for index in range.dropFirst() {
            merged = merged.merged(with: entries[orderedEntryIndices[index]].bounds)
        }
        return merged
    }

    private func splitAxis(entries: [SpatialIndexEntry], start: Int, count: Int) -> Int {
        var minCenter = entries[orderedEntryIndices[start]].bounds.center
        var maxCenter = minCenter

        if count > 1 {
            for offset in 1..<count {
                let center = entries[orderedEntryIndices[start + offset]].bounds.center
                minCenter = simd_min(minCenter, center)
                maxCenter = simd_max(maxCenter, center)
            }
        }

        let extents = maxCenter - minCenter
        if extents.y > extents.x && extents.y >= extents.z {
            return 1
        }
        if extents.z > extents.x && extents.z > extents.y {
            return 2
        }
        return 0
    }
}

public struct SceneRaycastQuery: Sendable, Equatable {
    public var origin: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var maxDistance: Float
    public var includeTriggers: Bool

    public init(origin: SIMD3<Float>,
                direction: SIMD3<Float>,
                maxDistance: Float = .greatestFiniteMagnitude,
                includeTriggers: Bool = false) {
        self.origin = origin
        self.direction = direction
        self.maxDistance = maxDistance
        self.includeTriggers = includeTriggers
    }
}

public struct SceneRaycastHit: Sendable, Equatable {
    public var entity: EntityID
    public var distance: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID,
                distance: Float,
                position: SIMD3<Float>,
                normal: SIMD3<Float>,
                bounds: SpatialAABB,
                isTrigger: Bool) {
        self.entity = entity
        self.distance = distance
        self.position = position
        self.normal = normal
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}

public struct SceneOverlapQuery: Sendable, Equatable {
    public var bounds: SpatialAABB
    public var includeTriggers: Bool

    public init(bounds: SpatialAABB, includeTriggers: Bool = false) {
        self.bounds = bounds
        self.includeTriggers = includeTriggers
    }
}

public struct SceneOverlapHit: Sendable, Equatable {
    public var entity: EntityID
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID, bounds: SpatialAABB, isTrigger: Bool) {
        self.entity = entity
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}

public struct SceneSweepQuery: Sendable, Equatable {
    public var bounds: SpatialAABB
    public var translation: SIMD3<Float>
    public var includeTriggers: Bool

    public init(bounds: SpatialAABB,
                translation: SIMD3<Float>,
                includeTriggers: Bool = false) {
        self.bounds = bounds
        self.translation = translation
        self.includeTriggers = includeTriggers
    }
}

public struct SceneSweepHit: Sendable, Equatable {
    public var entity: EntityID
    public var fraction: Float
    public var distance: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID,
                fraction: Float,
                distance: Float,
                position: SIMD3<Float>,
                normal: SIMD3<Float>,
                bounds: SpatialAABB,
                isTrigger: Bool) {
        self.entity = entity
        self.fraction = fraction
        self.distance = distance
        self.position = position
        self.normal = normal
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}

func buildSpatialIndexResource(in world: RuntimeWorld) -> SpatialIndexResource {
    buildSpatialIndexResource(in: world, using: .shared).resource
}

func buildSpatialIndexResource(
    in world: RuntimeWorld,
    using jobSystem: JobSystem
) -> (resource: SpatialIndexResource, report: JobDispatchReport) {
    let buildSettings = world.resource(SpatialIndexBuildSettings.self) ?? SpatialIndexBuildSettings()
    let previousIndex = world.resource(SpatialIndexResource.self)
    let entities = world.entities()
    let colliders = world.componentSnapshot(Collider.self, matching: entities)
    let worldTransforms = world.worldTransformSnapshot(matching: entities)
    let meshBounds = world.resource(MeshColliderBoundsResource.self)
    let meshGeometries = world.resource(MeshColliderGeometryResource.self)

    let result = jobSystem.parallelCompactMap(items: entities) { entity -> SpatialIndexEntry? in
        guard let collider = colliders[entity],
              let worldTransform = worldTransforms[entity] else {
            return nil
        }
        let meshGeometry = meshColliderGeometry(for: collider.shape, resource: meshGeometries)
        let resolvedShape = resolvedColliderShape(collider.shape,
                                                  meshGeometry: meshGeometry,
                                                  meshBounds: meshBounds)
        guard let bounds = colliderBounds(shape: resolvedShape,
                                          worldTransform: worldTransform,
                                          meshGeometry: meshGeometry) else {
            return nil
        }

        return SpatialIndexEntry(
            entity: entity,
            shape: resolvedShape,
            meshGeometry: meshGeometry,
            worldTransform: worldTransform,
            bounds: bounds,
            isTrigger: collider.isTrigger,
            layerID: collider.layerID,
            layerMask: collider.layerMask
        )
    }

    let buildConfig = buildSettings.resolvedConfig(entryCount: result.0.count)

    let resource: SpatialIndexResource
    let report: JobDispatchReport
    if let previousIndex, previousIndex.buildConfig == buildConfig {
        let update = previousIndex.updated(entries: result.0, sourceRevision: world.revision, using: jobSystem)
        resource = update.resource
        report = JobDispatchReport.merged([result.1, update.report], workerCount: jobSystem.workerCount)
    } else {
        resource = SpatialIndexResource(entries: result.0,
                                       sourceRevision: world.revision,
                                       buildConfig: buildConfig)
        report = result.1
    }

    return (
        resource,
        report
    )
}

private func colliderBounds(shape: ColliderShape,
                            worldTransform: WorldTransform,
                            meshGeometry: MeshColliderGeometry? = nil) -> SpatialAABB? {
    switch shape {
    case let .box(halfExtents, center):
        return transformedBounds(corners: boxCorners(center: center, halfExtents: halfExtents),
                                 matrix: worldTransform.matrix)
    case let .sphere(radius, center):
        let worldCenter = transformPoint(center, matrix: worldTransform.matrix)
        let scaledRadius = radius * maxScaleComponent(of: worldTransform.matrix)
        let radiusVector = SIMD3<Float>(repeating: scaledRadius)
        return SpatialAABB(min: worldCenter - radiusVector, max: worldCenter + radiusVector)
    case let .capsule(radius, halfHeight, center):
        let top = transformPoint(center + SIMD3<Float>(0, halfHeight, 0), matrix: worldTransform.matrix)
        let bottom = transformPoint(center + SIMD3<Float>(0, -halfHeight, 0), matrix: worldTransform.matrix)
        let scaledRadius = radius * maxScaleComponent(of: worldTransform.matrix)
        let radiusVector = SIMD3<Float>(repeating: scaledRadius)
        return SpatialAABB(
            min: simd_min(top, bottom) - radiusVector,
            max: simd_max(top, bottom) + radiusVector
        )
    case let .mesh(_, center),
         let .convex(_, center):
        let localBounds = meshGeometry?.localBounds
            ?? SpatialAABB(center: .zero, halfExtents: SIMD3<Float>(repeating: 0.5))
        let meshCenter = center + localBounds.center
        return transformedBounds(corners: boxCorners(center: meshCenter,
                                                     halfExtents: localBounds.halfExtents),
                                 matrix: worldTransform.matrix)
    }
}

private func meshColliderGeometry(for shape: ColliderShape,
                                  resource: MeshColliderGeometryResource?) -> MeshColliderGeometry? {
    switch shape {
    case let .mesh(resourceID, _),
         let .convex(resourceID, _):
        return resource?.geometry(for: resourceID)
    default:
        return nil
    }
}

func resolvedColliderShape(_ shape: ColliderShape,
                           meshGeometry: MeshColliderGeometry?,
                           meshBounds: MeshColliderBoundsResource?) -> ColliderShape {
    if meshGeometry != nil {
        return shape
    }
    switch shape {
    case let .mesh(resourceID, center),
         let .convex(resourceID, center):
        if let localBounds = meshBounds?.bounds(for: resourceID) {
            return .box(halfExtents: localBounds.halfExtents,
                        center: center + localBounds.center)
        }
        return shape
    default:
        return shape
    }
}

private func boxCorners(center: SIMD3<Float>, halfExtents: SIMD3<Float>) -> [SIMD3<Float>] {
    [
        center + SIMD3<Float>( halfExtents.x,  halfExtents.y,  halfExtents.z),
        center + SIMD3<Float>( halfExtents.x,  halfExtents.y, -halfExtents.z),
        center + SIMD3<Float>( halfExtents.x, -halfExtents.y,  halfExtents.z),
        center + SIMD3<Float>( halfExtents.x, -halfExtents.y, -halfExtents.z),
        center + SIMD3<Float>(-halfExtents.x,  halfExtents.y,  halfExtents.z),
        center + SIMD3<Float>(-halfExtents.x,  halfExtents.y, -halfExtents.z),
        center + SIMD3<Float>(-halfExtents.x, -halfExtents.y,  halfExtents.z),
        center + SIMD3<Float>(-halfExtents.x, -halfExtents.y, -halfExtents.z),
    ]
}

private func transformedBounds(corners: [SIMD3<Float>], matrix: simd_float4x4) -> SpatialAABB? {
    guard let first = corners.first.map({ transformPoint($0, matrix: matrix) }) else {
        return nil
    }

    var minimum = first
    var maximum = first
    for corner in corners.dropFirst() {
        let transformed = transformPoint(corner, matrix: matrix)
        minimum = simd_min(minimum, transformed)
        maximum = simd_max(maximum, transformed)
    }
    return SpatialAABB(min: minimum, max: maximum)
}

private func transformPoint(_ point: SIMD3<Float>, matrix: simd_float4x4) -> SIMD3<Float> {
    let transformed = matrix * SIMD4<Float>(point.x, point.y, point.z, 1)
    return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
}

private func maxScaleComponent(of matrix: simd_float4x4) -> Float {
    max(
        simd_length(SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)),
        max(
            simd_length(SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)),
            simd_length(SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        )
    )
}
