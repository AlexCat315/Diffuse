import EngineKernel
import simd

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
    public var worldTransform: WorldTransform
    public var bounds: SpatialAABB
    public var isTrigger: Bool
    public var layerID: UInt16
    public var layerMask: UInt16

    public init(entity: EntityID,
        shape: ColliderShape,
        worldTransform: WorldTransform,
                bounds: SpatialAABB,
                isTrigger: Bool,
                layerID: UInt16,
                layerMask: UInt16) {
        self.entity = entity
    self.shape = shape
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
    fileprivate var overflowDistanceStack: [Float] = []

    public init() {}

    fileprivate func resetTraversalOverflow() {
        overflowNodeStack.removeAll(keepingCapacity: true)
        overflowDistanceStack.removeAll(keepingCapacity: true)
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

    func raycastInterval(nodeIndex: Int,
                         origin: SIMD3<Float>,
                         direction: SIMD3<Float>,
                         maxDistance: Float) -> (entryDistance: Float, exitDistance: Float, normal: SIMD3<Float>)? {
        raycastBoxInterval(min: SIMD3<Float>(minX[nodeIndex], minY[nodeIndex], minZ[nodeIndex]),
                           max: SIMD3<Float>(maxX[nodeIndex], maxY[nodeIndex], maxZ[nodeIndex]),
                           origin: origin,
                           direction: direction,
                           maxDistance: maxDistance)
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

    func forEachRayCandidate(origin: SIMD3<Float>,
                             direction: SIMD3<Float>,
                             maxDistance: Float,
                             scratch: SpatialQueryScratch? = nil,
                             statsRecorder: SpatialQueryStatsRecorder? = nil,
                             _ body: (Int, Float) -> Void) {
        guard !nodes.isEmpty else { return }

        scratch?.resetTraversalOverflow()
        var localOverflowNodeStack: [Int] = []
        var localOverflowDistanceStack: [Float] = []

        withUnsafeTemporaryAllocation(of: Int.self, capacity: Self.traversalStackCapacity) { nodeStack in
            withUnsafeTemporaryAllocation(of: Float.self, capacity: Self.traversalStackCapacity) { distanceStack in
                var stackSize = 1
                nodeStack[0] = 0
                distanceStack[0] = 0

                func push(nodeIndex: Int, distance: Float) {
                    if stackSize < nodeStack.count {
                        nodeStack[stackSize] = nodeIndex
                        distanceStack[stackSize] = distance
                        stackSize += 1
                        return
                    }

                    if let scratch {
                        scratch.overflowNodeStack.append(nodeIndex)
                        scratch.overflowDistanceStack.append(distance)
                    } else {
                        localOverflowNodeStack.append(nodeIndex)
                        localOverflowDistanceStack.append(distance)
                    }
                }

                func pop() -> (nodeIndex: Int, distance: Float)? {
                    if stackSize > 0 {
                        stackSize -= 1
                        return (nodeStack[stackSize], distanceStack[stackSize])
                    }

                    if let scratch,
                       let nodeIndex = scratch.overflowNodeStack.popLast(),
                       let distance = scratch.overflowDistanceStack.popLast() {
                        return (nodeIndex, distance)
                    }

                    if let nodeIndex = localOverflowNodeStack.popLast(),
                       let distance = localOverflowDistanceStack.popLast() {
                        return (nodeIndex, distance)
                    }

                    return nil
                }

                while let next = pop() {
                    statsRecorder?.recordNodeVisit()
                    let nodeIndex = next.nodeIndex
                    let nodeEntryDistance = next.distance

                    guard nodeEntryDistance <= maxDistance else { continue }

                    if soa.isLeaf(nodeIndex) {
                        statsRecorder?.recordLeafTest()
                        let start = soa.rangeStart(nodeIndex)
                        let count = soa.rangeCount(nodeIndex)
                        for offset in 0..<count {
                            body(orderedEntryIndices[start + offset], nodeEntryDistance)
                        }
                        continue
                    }

                    let leftChild = soa.left(nodeIndex)
                    let rightChild = soa.right(nodeIndex)
                    let leftHit = leftChild >= 0
                        ? soa.raycastInterval(nodeIndex: leftChild,
                                              origin: origin,
                                              direction: direction,
                                              maxDistance: maxDistance)
                        : nil
                    let rightHit = rightChild >= 0
                        ? soa.raycastInterval(nodeIndex: rightChild,
                                              origin: origin,
                                              direction: direction,
                                              maxDistance: maxDistance)
                        : nil

                    if let leftHit, let rightHit {
                        if leftHit.entryDistance <= rightHit.entryDistance {
                            push(nodeIndex: rightChild, distance: rightHit.entryDistance)
                            push(nodeIndex: leftChild, distance: leftHit.entryDistance)
                        } else {
                            push(nodeIndex: leftChild, distance: leftHit.entryDistance)
                            push(nodeIndex: rightChild, distance: rightHit.entryDistance)
                        }
                    } else if let leftHit {
                        push(nodeIndex: leftChild, distance: leftHit.entryDistance)
                    } else if let rightHit {
                        push(nodeIndex: rightChild, distance: rightHit.entryDistance)
                    }
                }
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

    let result = jobSystem.parallelCompactMap(items: entities) { entity -> SpatialIndexEntry? in
        guard let collider = colliders[entity],
              let worldTransform = worldTransforms[entity],
              let bounds = colliderBounds(shape: collider.shape, worldTransform: worldTransform) else {
            return nil
        }

        return SpatialIndexEntry(
            entity: entity,
            shape: collider.shape,
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

func performSpatialRaycast(_ query: SceneRaycastQuery,
                           using index: SpatialIndexResource) -> SceneRaycastHit? {
    performPhysicsRaycast(
        PhysicsRaycastQuery(
            origin: query.origin,
            direction: query.direction,
            maxDistance: query.maxDistance
        ),
        filter: PhysicsQueryFilter(includeTriggers: query.includeTriggers),
        using: index
    ).map(makeSceneRaycastHit)
}

func performSpatialOverlap(_ query: SceneOverlapQuery,
                           using index: SpatialIndexResource,
                           scratch: SpatialQueryScratch? = nil,
                           statsRecorder: SpatialQueryStatsRecorder? = nil) -> [SceneOverlapHit] {
    let physicsHits = performPhysicsOverlapAABB(
        PhysicsOverlapAABBQuery(bounds: query.bounds),
        filter: PhysicsQueryFilter(includeTriggers: query.includeTriggers),
        using: index,
        scratch: scratch,
        statsRecorder: statsRecorder
    )

    if let scratch {
        scratch.sceneOverlapHitsBuffer.removeAll(keepingCapacity: true)
        scratch.sceneOverlapHitsBuffer.reserveCapacity(physicsHits.count)
        for hit in physicsHits {
            scratch.sceneOverlapHitsBuffer.append(makeSceneOverlapHit(hit))
        }
        return scratch.sceneOverlapHitsBuffer
    }

    return physicsHits.map(makeSceneOverlapHit)
}

func performSpatialSweep(_ query: SceneSweepQuery,
                         using index: SpatialIndexResource) -> SceneSweepHit? {
    performPhysicsSweepAABB(
        PhysicsSweepAABBQuery(bounds: query.bounds, translation: query.translation),
        filter: PhysicsQueryFilter(includeTriggers: query.includeTriggers),
        using: index
    ).map(makeSceneSweepHit)
}

func performPhysicsRaycast(_ query: PhysicsRaycastQuery,
                           filter: PhysicsQueryFilter,
                           using index: SpatialIndexResource,
                           scratch: SpatialQueryScratch? = nil,
                           statsRecorder: SpatialQueryStatsRecorder? = nil) -> PhysicsRaycastHit? {
    let directionLength = simd_length(query.direction)
    guard directionLength > 0.000_001 else { return nil }
    let direction = query.direction / directionLength
    let maxDistance = max(query.maxDistance, 0)

    var resolvedHit: PhysicsRaycastHit?
    var bestDistance = maxDistance
    index.bvh.forEachRayCandidate(origin: query.origin,
                                  direction: direction,
                                  maxDistance: maxDistance,
                                  scratch: scratch,
                                  statsRecorder: statsRecorder) { entryIndex, entryDistance in
        guard entryDistance <= bestDistance else { return }

        let entry = index.entries[entryIndex]
        guard matchesPhysicsQueryFilter(entry, filter: filter) else { return }
        guard raycastBox(min: entry.bounds.min,
                         max: entry.bounds.max,
                         origin: query.origin,
                         direction: direction,
                         maxDistance: bestDistance) != nil else {
            return
        }
        statsRecorder?.recordNarrowPhaseTest()
        guard let result = preciseRaycast(shape: entry.shape,
                                          worldTransform: entry.worldTransform,
                                          origin: query.origin,
                                          direction: direction,
                                          maxDistance: bestDistance) else {
            return
        }

        if let existing = resolvedHit, existing.distance <= result.distance {
            return
        }

        resolvedHit = PhysicsRaycastHit(
            entity: entry.entity,
            distance: result.distance,
            position: result.position,
            normal: result.normal,
            bounds: entry.bounds,
            isTrigger: entry.isTrigger
        )
        bestDistance = result.distance
    }

    return resolvedHit
}

func performPhysicsOverlapAABB(_ query: PhysicsOverlapAABBQuery,
                               filter: PhysicsQueryFilter,
                               using index: SpatialIndexResource,
                               scratch: SpatialQueryScratch? = nil,
                               statsRecorder: SpatialQueryStatsRecorder? = nil) -> [PhysicsOverlapHit] {
    let maxResults = query.maxResults
    // Use forEachOverlappingWhile so the traversal can stop the moment we reach maxResults.
    // Filter checks are ordered cheapest-first (trigger flag → layer masks → per-entry AABB →
    // narrow phase) to minimise work before the expensive preciseOverlap call.
    if let scratch {
        scratch.physicsOverlapHitsBuffer.removeAll(keepingCapacity: true)
        var hitCount = 0
        index.bvh.forEachOverlappingWhile(query.bounds,
                                          scratch: scratch,
                                          statsRecorder: statsRecorder) { candidateIndex in
            let entry = index.entries[candidateIndex]
            // Layer/trigger filter: cheapest tests first, before any AABB or narrow work.
            guard matchesPhysicsQueryFilter(entry, filter: filter) else { return true }
            // Per-entry AABB coarse cull (leaf node AABB is a union; individual entries may miss).
            guard entry.bounds.intersects(query.bounds) else { return true }
            statsRecorder?.recordNarrowPhaseTest()
            guard preciseOverlap(shape: entry.shape,
                                 worldTransform: entry.worldTransform,
                                 queryBounds: query.bounds) else { return true }
            scratch.physicsOverlapHitsBuffer.append(
                PhysicsOverlapHit(entity: entry.entity,
                                  bounds: entry.bounds,
                                  isTrigger: entry.isTrigger)
            )
            hitCount += 1
            return hitCount < maxResults
        }
        // Sort for determinism only when collecting all results.
        if maxResults == .max {
            scratch.physicsOverlapHitsBuffer.sort { $0.entity.rawValue < $1.entity.rawValue }
        }
        return scratch.physicsOverlapHitsBuffer
    }

    var hits: [PhysicsOverlapHit] = []
    var hitCount = 0
    index.bvh.forEachOverlappingWhile(query.bounds,
                                      scratch: nil,
                                      statsRecorder: statsRecorder) { candidateIndex in
        let entry = index.entries[candidateIndex]
        guard matchesPhysicsQueryFilter(entry, filter: filter) else { return true }
        guard entry.bounds.intersects(query.bounds) else { return true }
        statsRecorder?.recordNarrowPhaseTest()
        guard preciseOverlap(shape: entry.shape,
                             worldTransform: entry.worldTransform,
                             queryBounds: query.bounds) else { return true }
        hits.append(PhysicsOverlapHit(entity: entry.entity,
                                      bounds: entry.bounds,
                                      isTrigger: entry.isTrigger))
        hitCount += 1
        return hitCount < maxResults
    }
    if maxResults == .max {
        hits.sort { $0.entity.rawValue < $1.entity.rawValue }
    }
    return hits
}

func performPhysicsSweepAABB(_ query: PhysicsSweepAABBQuery,
                             filter: PhysicsQueryFilter,
                             using index: SpatialIndexResource,
                             scratch: SpatialQueryScratch? = nil,
                             statsRecorder: SpatialQueryStatsRecorder? = nil) -> PhysicsSweepHit? {
    guard query.bounds.isValid else { return nil }

    let travelDistance = simd_length(query.translation)
    guard travelDistance > 0.000_001 else { return nil }

    let direction = query.translation / travelDistance
    let queryCenter = query.bounds.center
    let queryHalfExtents = query.bounds.halfExtents
    let sweptBounds = query.bounds.merged(with: translatedAABB(query.bounds, by: query.translation))

    var resolvedHit: PhysicsSweepHit?
    index.bvh.forEachOverlapping(sweptBounds,
                                 scratch: scratch,
                                 statsRecorder: statsRecorder) { entryIndex in
        let entry = index.entries[entryIndex]
        guard matchesPhysicsQueryFilter(entry, filter: filter) else { return }

        let expandedBounds = expandedAABB(entry.bounds, by: queryHalfExtents)
        guard let interval = raycastBoxInterval(min: expandedBounds.min,
                                               max: expandedBounds.max,
                                               origin: queryCenter,
                                               direction: direction,
                                               maxDistance: travelDistance) else {
            return
        }
        statsRecorder?.recordNarrowPhaseTest()
        guard let hit = preciseSweep(shape: entry.shape,
                                     worldTransform: entry.worldTransform,
                                     queryBounds: query.bounds,
                                     direction: direction,
                                     maxDistance: travelDistance,
                                     broadPhaseInterval: interval) else {
            return
        }

        if let existing = resolvedHit, existing.distance <= hit.distance {
            return
        }

        resolvedHit = PhysicsSweepHit(
            entity: entry.entity,
            fraction: hit.distance / travelDistance,
            distance: hit.distance,
            position: hit.position,
            normal: hit.normal,
            bounds: entry.bounds,
            isTrigger: entry.isTrigger
        )
    }

    return resolvedHit
}

private func matchesPhysicsQueryFilter(_ entry: SpatialIndexEntry,
                                       filter: PhysicsQueryFilter) -> Bool {
    if let excluded = filter.excludeEntity, excluded == entry.entity {
        return false
    }
    if !filter.includeTriggers && entry.isTrigger {
        return false
    }
    if let requiredLayerID = filter.layerID, entry.layerID != requiredLayerID {
        return false
    }
    return (entry.layerMask & filter.layerMask) != 0
}

private func makeSceneRaycastHit(_ hit: PhysicsRaycastHit) -> SceneRaycastHit {
    SceneRaycastHit(
        entity: hit.entity,
        distance: hit.distance,
        position: hit.position,
        normal: hit.normal,
        bounds: hit.bounds,
        isTrigger: hit.isTrigger
    )
}

private func makeSceneOverlapHit(_ hit: PhysicsOverlapHit) -> SceneOverlapHit {
    SceneOverlapHit(entity: hit.entity, bounds: hit.bounds, isTrigger: hit.isTrigger)
}

private func makeSceneSweepHit(_ hit: PhysicsSweepHit) -> SceneSweepHit {
    SceneSweepHit(
        entity: hit.entity,
        fraction: hit.fraction,
        distance: hit.distance,
        position: hit.position,
        normal: hit.normal,
        bounds: hit.bounds,
        isTrigger: hit.isTrigger
    )
}

private func colliderBounds(shape: ColliderShape,
                            worldTransform: WorldTransform) -> SpatialAABB? {
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
    case let .mesh(_, center):
        let placeholderHalfExtents = SIMD3<Float>(repeating: 0.5)
        return transformedBounds(corners: boxCorners(center: center, halfExtents: placeholderHalfExtents),
                                 matrix: worldTransform.matrix)
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

private func preciseRaycast(shape: ColliderShape,
                            worldTransform: WorldTransform,
                            origin: SIMD3<Float>,
                            direction: SIMD3<Float>,
                            maxDistance: Float) -> (distance: Float, position: SIMD3<Float>, normal: SIMD3<Float>)? {
    let inverseMatrix = simd_inverse(worldTransform.matrix)
    let localOrigin = transformPoint(origin, matrix: inverseMatrix)
    let localDirection = transformVector(direction, matrix: inverseMatrix)

    switch shape {
    case let .box(halfExtents, center):
        guard let localHit = raycastBox(min: center - halfExtents,
                                        max: center + halfExtents,
                                        origin: localOrigin,
                                        direction: localDirection,
                                        maxDistance: maxDistance) else {
            return nil
        }
        return makeWorldRaycastHit(localHit: localHit,
                                   worldDirection: direction,
                                   worldTransform: worldTransform.matrix,
                                   inverseMatrix: inverseMatrix)
    case let .sphere(radius, center):
        guard let localHit = raycastSphere(center: center,
                                           radius: radius,
                                           origin: localOrigin,
                                           direction: localDirection,
                                           maxDistance: maxDistance) else {
            return nil
        }
        return makeWorldRaycastHit(localHit: localHit,
                                   worldDirection: direction,
                                   worldTransform: worldTransform.matrix,
                                   inverseMatrix: inverseMatrix)
    case let .capsule(radius, halfHeight, center):
        guard let localHit = raycastCapsule(center: center,
                                            radius: radius,
                                            halfHeight: halfHeight,
                                            origin: localOrigin,
                                            direction: localDirection,
                                            maxDistance: maxDistance) else {
            return nil
        }
        return makeWorldRaycastHit(localHit: localHit,
                                   worldDirection: direction,
                                   worldTransform: worldTransform.matrix,
                                   inverseMatrix: inverseMatrix)
    case .mesh:
        return raycastBox(min: SIMD3<Float>(repeating: -0.5),
                          max: SIMD3<Float>(repeating: 0.5),
                          origin: localOrigin,
                          direction: localDirection,
                          maxDistance: maxDistance).map { localHit in
            makeWorldRaycastHit(localHit: localHit,
                                worldDirection: direction,
                                worldTransform: worldTransform.matrix,
                                inverseMatrix: inverseMatrix)
        }
    }
}

private func preciseOverlap(shape: ColliderShape,
                            worldTransform: WorldTransform,
                            queryBounds: SpatialAABB) -> Bool {
    switch shape {
    case let .box(halfExtents, center):
        return orientedBoxIntersectsAABB(
            makeWorldOrientedBox(center: center,
                                 halfExtents: halfExtents,
                                 matrix: worldTransform.matrix),
            bounds: queryBounds
        )
    case let .sphere(radius, center):
        let worldCenter = transformPoint(center, matrix: worldTransform.matrix)
        let scaledRadius = radius * maxScaleComponent(of: worldTransform.matrix)
        return sphereIntersectsAABB(center: worldCenter, radius: scaledRadius, bounds: queryBounds)
    case let .capsule(radius, halfHeight, center):
        let top = transformPoint(center + SIMD3<Float>(0, halfHeight, 0), matrix: worldTransform.matrix)
        let bottom = transformPoint(center + SIMD3<Float>(0, -halfHeight, 0), matrix: worldTransform.matrix)
        let scaledRadius = radius * maxScaleComponent(of: worldTransform.matrix)
        return segmentAABBDistanceSquared(start: top, end: bottom, bounds: queryBounds) <= (scaledRadius * scaledRadius)
    case let .mesh(_, center):
        return orientedBoxIntersectsAABB(
            makeWorldOrientedBox(center: center,
                                 halfExtents: SIMD3<Float>(repeating: 0.5),
                                 matrix: worldTransform.matrix),
            bounds: queryBounds
        )
    }
}

private struct SpatialOrientedBox {
    var center: SIMD3<Float>
    var axes: [SIMD3<Float>]
    var halfExtents: SIMD3<Float>
}

private struct SpatialOverlapResult {
    var normal: SIMD3<Float>
}

private func makeWorldOrientedBox(center: SIMD3<Float>,
                                  halfExtents: SIMD3<Float>,
                                  matrix: simd_float4x4) -> SpatialOrientedBox {
    let basisX = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
    let basisY = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
    let basisZ = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
    let scale = SIMD3<Float>(simd_length(basisX), simd_length(basisY), simd_length(basisZ))
    return SpatialOrientedBox(
        center: transformPoint(center, matrix: matrix),
        axes: [
            normalizedAxis(basisX, fallback: SIMD3<Float>(1, 0, 0)),
            normalizedAxis(basisY, fallback: SIMD3<Float>(0, 1, 0)),
            normalizedAxis(basisZ, fallback: SIMD3<Float>(0, 0, 1)),
        ],
        halfExtents: SIMD3<Float>(
            halfExtents.x * scale.x,
            halfExtents.y * scale.y,
            halfExtents.z * scale.z
        )
    )
}

private func orientedBoxIntersectsAABB(_ box: SpatialOrientedBox,
                                       bounds: SpatialAABB) -> Bool {
    orientedBoxOverlapResult(box, bounds: bounds) != nil
}

private func orientedBoxOverlapResult(_ box: SpatialOrientedBox,
                                      bounds: SpatialAABB) -> SpatialOverlapResult? {
    let queryCenter = bounds.center
    let queryHalfExtents = bounds.halfExtents
    let translation = box.center - queryCenter
    let queryExtents = [queryHalfExtents.x, queryHalfExtents.y, queryHalfExtents.z]
    let boxExtents = [box.halfExtents.x, box.halfExtents.y, box.halfExtents.z]
    let queryAxes = [
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, 1, 0),
        SIMD3<Float>(0, 0, 1),
    ]
    var bestAxis = SIMD3<Float>(-1, 0, 0)
    var bestPenetration = Float.greatestFiniteMagnitude

    var rotation = Array(repeating: Array(repeating: Float(0), count: 3), count: 3)
    var absoluteRotation = Array(repeating: Array(repeating: Float(0), count: 3), count: 3)
    for axis in 0..<3 {
        for boxAxis in 0..<3 {
            rotation[axis][boxAxis] = box.axes[boxAxis][axis]
            absoluteRotation[axis][boxAxis] = abs(rotation[axis][boxAxis]) + 0.000_001
        }
    }

    let translationComponents = [translation.x, translation.y, translation.z]
    for axis in 0..<3 {
        let radiusA = queryExtents[axis]
        let radiusB = boxExtents[0] * absoluteRotation[axis][0] +
            boxExtents[1] * absoluteRotation[axis][1] +
            boxExtents[2] * absoluteRotation[axis][2]
        let overlap = radiusA + radiusB - abs(translationComponents[axis])
        if overlap < 0 {
            return nil
        }
        if overlap < bestPenetration {
            bestPenetration = overlap
            bestAxis = queryAxes[axis] * (translationComponents[axis] < 0 ? -1 : 1)
        }
    }

    for axis in 0..<3 {
        let radiusA = queryExtents[0] * absoluteRotation[0][axis] +
            queryExtents[1] * absoluteRotation[1][axis] +
            queryExtents[2] * absoluteRotation[2][axis]
        let radiusB = boxExtents[axis]
        let signedProjection = translationComponents[0] * rotation[0][axis] +
            translationComponents[1] * rotation[1][axis] +
            translationComponents[2] * rotation[2][axis]
        let overlap = radiusA + radiusB - abs(signedProjection)
        if overlap < 0 {
            return nil
        }
        if overlap < bestPenetration {
            bestPenetration = overlap
            bestAxis = box.axes[axis] * (signedProjection < 0 ? -1 : 1)
        }
    }

    for queryAxis in 0..<3 {
        for boxAxis in 0..<3 {
            let axisVector = simd_cross(queryAxes[queryAxis], box.axes[boxAxis])
            if simd_length_squared(axisVector) <= 0.000_001 {
                continue
            }
            let radiusA = queryExtents[(queryAxis + 1) % 3] * absoluteRotation[(queryAxis + 2) % 3][boxAxis] +
                queryExtents[(queryAxis + 2) % 3] * absoluteRotation[(queryAxis + 1) % 3][boxAxis]
            let radiusB = boxExtents[(boxAxis + 1) % 3] * absoluteRotation[queryAxis][(boxAxis + 2) % 3] +
                boxExtents[(boxAxis + 2) % 3] * absoluteRotation[queryAxis][(boxAxis + 1) % 3]
            let signedProjection = translationComponents[(queryAxis + 2) % 3] * rotation[(queryAxis + 1) % 3][boxAxis] -
                translationComponents[(queryAxis + 1) % 3] * rotation[(queryAxis + 2) % 3][boxAxis]
            let overlap = radiusA + radiusB - abs(signedProjection)
            if overlap < 0 {
                return nil
            }
            if overlap < bestPenetration {
                bestPenetration = overlap
                bestAxis = normalizedAxis(axisVector, fallback: bestAxis) * (signedProjection < 0 ? -1 : 1)
            }
        }
    }

    return SpatialOverlapResult(normal: normalizedAxis(bestAxis, fallback: SIMD3<Float>(-1, 0, 0)))
}

private func sphereIntersectsAABB(center: SIMD3<Float>,
                                  radius: Float,
                                  bounds: SpatialAABB) -> Bool {
    pointAABBDistanceSquared(point: center, bounds: bounds) <= (radius * radius)
}

private func segmentAABBDistanceSquared(start: SIMD3<Float>,
                                        end: SIMD3<Float>,
                                        bounds: SpatialAABB) -> Float {
    if segmentIntersectsAABB(start: start, end: end, bounds: bounds) {
        return 0
    }

    var lower: Float = 0
    var upper: Float = 1
    for _ in 0..<24 {
        let left = (2 * lower + upper) / 3
        let right = (lower + 2 * upper) / 3
        let leftPoint = simd_mix(start, end, SIMD3<Float>(repeating: left))
        let rightPoint = simd_mix(start, end, SIMD3<Float>(repeating: right))
        if pointAABBDistanceSquared(point: leftPoint, bounds: bounds) < pointAABBDistanceSquared(point: rightPoint, bounds: bounds) {
            upper = right
        } else {
            lower = left
        }
    }

    let midpoint = simd_mix(start, end, SIMD3<Float>(repeating: (lower + upper) * 0.5))
    return min(
        pointAABBDistanceSquared(point: midpoint, bounds: bounds),
        min(
            pointAABBDistanceSquared(point: start, bounds: bounds),
            pointAABBDistanceSquared(point: end, bounds: bounds)
        )
    )
}

private func segmentIntersectsAABB(start: SIMD3<Float>,
                                   end: SIMD3<Float>,
                                   bounds: SpatialAABB) -> Bool {
    let delta = end - start
    var entry: Float = 0
    var exit: Float = 1

    for axis in 0..<3 {
        let startValue = start[axis]
        let deltaValue = delta[axis]
        let minValue = bounds.min[axis]
        let maxValue = bounds.max[axis]

        if abs(deltaValue) <= 0.000_001 {
            guard startValue >= minValue && startValue <= maxValue else { return false }
            continue
        }

        var t0 = (minValue - startValue) / deltaValue
        var t1 = (maxValue - startValue) / deltaValue
        if t0 > t1 {
            swap(&t0, &t1)
        }

        entry = Swift.max(entry, t0)
        exit = Swift.min(exit, t1)
        guard entry <= exit else { return false }
    }

    return true
}

private func pointAABBDistanceSquared(point: SIMD3<Float>, bounds: SpatialAABB) -> Float {
    let clamped = simd_min(simd_max(point, bounds.min), bounds.max)
    let delta = point - clamped
    return simd_length_squared(delta)
}

private func expandedAABB(_ bounds: SpatialAABB, by halfExtents: SIMD3<Float>) -> SpatialAABB {
    SpatialAABB(min: bounds.min - halfExtents, max: bounds.max + halfExtents)
}

private func translatedAABB(_ bounds: SpatialAABB, by translation: SIMD3<Float>) -> SpatialAABB {
    SpatialAABB(min: bounds.min + translation, max: bounds.max + translation)
}

private func closestPointOnAABB(to point: SIMD3<Float>, bounds: SpatialAABB) -> SIMD3<Float> {
    simd_min(simd_max(point, bounds.min), bounds.max)
}

private func closestSegmentPointToAABB(start: SIMD3<Float>,
                                       end: SIMD3<Float>,
                                       bounds: SpatialAABB) -> (segmentPoint: SIMD3<Float>, aabbPoint: SIMD3<Float>) {
    var lower: Float = 0
    var upper: Float = 1
    for _ in 0..<24 {
        let left = (2 * lower + upper) / 3
        let right = (lower + 2 * upper) / 3
        let leftPoint = simd_mix(start, end, SIMD3<Float>(repeating: left))
        let rightPoint = simd_mix(start, end, SIMD3<Float>(repeating: right))
        if pointAABBDistanceSquared(point: leftPoint, bounds: bounds) < pointAABBDistanceSquared(point: rightPoint, bounds: bounds) {
            upper = right
        } else {
            lower = left
        }
    }

    let segmentPoint = simd_mix(start, end, SIMD3<Float>(repeating: (lower + upper) * 0.5))
    let aabbPoint = closestPointOnAABB(to: segmentPoint, bounds: bounds)
    return (segmentPoint, aabbPoint)
}

private func preciseSweep(shape: ColliderShape,
                          worldTransform: WorldTransform,
                          queryBounds: SpatialAABB,
                          direction: SIMD3<Float>,
                          maxDistance: Float,
                          broadPhaseInterval: (entryDistance: Float, exitDistance: Float, normal: SIMD3<Float>)) -> (distance: Float, position: SIMD3<Float>, normal: SIMD3<Float>)? {
    let fallbackNormal = alignedContactNormal(
        broadPhaseInterval.normal,
        direction: direction,
        fallback: -normalizedAxis(direction, fallback: SIMD3<Float>(1, 0, 0))
    )
    if preciseOverlap(shape: shape,
                      worldTransform: worldTransform,
                      queryBounds: queryBounds) {
        return (
            0,
            queryBounds.center,
            preciseSweepContactNormal(
                shape: shape,
                worldTransform: worldTransform,
                queryBounds: queryBounds,
                direction: direction,
                fallbackNormal: fallbackNormal
            )
        )
    }

    let entryDistance = Swift.max(broadPhaseInterval.entryDistance, 0)
    let exitDistance = Swift.min(broadPhaseInterval.exitDistance, maxDistance)
    guard entryDistance <= exitDistance else { return nil }

    let sampleCount = 64
    var previousDistance = entryDistance
    var previousOverlaps = preciseOverlap(shape: shape,
                                          worldTransform: worldTransform,
                                          queryBounds: translatedAABB(queryBounds, by: direction * entryDistance))

    if previousOverlaps {
        let hitBounds = translatedAABB(queryBounds, by: direction * entryDistance)
        return (
            entryDistance,
            queryBounds.center + direction * entryDistance,
            preciseSweepContactNormal(
                shape: shape,
                worldTransform: worldTransform,
                queryBounds: hitBounds,
                direction: direction,
                fallbackNormal: fallbackNormal
            )
        )
    }

    for step in 1...sampleCount {
        let alpha = Float(step) / Float(sampleCount)
        let sampleDistance = simd_mix(entryDistance, exitDistance, alpha)
        let sampleBounds = translatedAABB(queryBounds, by: direction * sampleDistance)
        let overlaps = preciseOverlap(shape: shape,
                                      worldTransform: worldTransform,
                                      queryBounds: sampleBounds)
        if !overlaps {
            previousDistance = sampleDistance
            previousOverlaps = false
            continue
        }

        var lowerBound = previousOverlaps ? previousDistance : previousDistance
        var upperBound = sampleDistance
        if !previousOverlaps {
            for _ in 0..<20 {
                let midpoint = (lowerBound + upperBound) * 0.5
                let midpointBounds = translatedAABB(queryBounds, by: direction * midpoint)
                if preciseOverlap(shape: shape,
                                  worldTransform: worldTransform,
                                  queryBounds: midpointBounds) {
                    upperBound = midpoint
                } else {
                    lowerBound = midpoint
                }
            }
        }

        let hitBounds = translatedAABB(queryBounds, by: direction * upperBound)
        return (
            upperBound,
            queryBounds.center + direction * upperBound,
            preciseSweepContactNormal(
                shape: shape,
                worldTransform: worldTransform,
                queryBounds: hitBounds,
                direction: direction,
                fallbackNormal: fallbackNormal
            )
        )
    }

    return nil
}

private func preciseSweepContactNormal(shape: ColliderShape,
                                       worldTransform: WorldTransform,
                                       queryBounds: SpatialAABB,
                                       direction: SIMD3<Float>,
                                       fallbackNormal: SIMD3<Float>) -> SIMD3<Float> {
    switch shape {
    case let .box(halfExtents, center):
        let box = makeWorldOrientedBox(center: center,
                                       halfExtents: halfExtents,
                                       matrix: worldTransform.matrix)
        guard let result = orientedBoxOverlapResult(box, bounds: queryBounds) else {
            return fallbackNormal
        }
        return alignedContactNormal(result.normal, direction: direction, fallback: fallbackNormal)
    case let .sphere(radius, center):
        let worldCenter = transformPoint(center, matrix: worldTransform.matrix)
        let scaledRadius = radius * maxScaleComponent(of: worldTransform.matrix)
        let closestPoint = closestPointOnAABB(to: worldCenter, bounds: queryBounds)
        let offset = closestPoint - worldCenter
        guard simd_length_squared(offset) <= (scaledRadius * scaledRadius) + 0.000_1 else {
            return fallbackNormal
        }
        return alignedContactNormal(offset, direction: direction, fallback: fallbackNormal)
    case let .capsule(radius, halfHeight, center):
        let top = transformPoint(center + SIMD3<Float>(0, halfHeight, 0), matrix: worldTransform.matrix)
        let bottom = transformPoint(center + SIMD3<Float>(0, -halfHeight, 0), matrix: worldTransform.matrix)
        let scaledRadius = radius * maxScaleComponent(of: worldTransform.matrix)
        let nearest = closestSegmentPointToAABB(start: top, end: bottom, bounds: queryBounds)
        let offset = nearest.aabbPoint - nearest.segmentPoint
        guard simd_length_squared(offset) <= (scaledRadius * scaledRadius) + 0.000_1 else {
            return fallbackNormal
        }
        return alignedContactNormal(offset, direction: direction, fallback: fallbackNormal)
    case let .mesh(_, center):
        let box = makeWorldOrientedBox(center: center,
                                       halfExtents: SIMD3<Float>(repeating: 0.5),
                                       matrix: worldTransform.matrix)
        guard let result = orientedBoxOverlapResult(box, bounds: queryBounds) else {
            return fallbackNormal
        }
        return alignedContactNormal(result.normal, direction: direction, fallback: fallbackNormal)
    }
}

private func alignedContactNormal(_ candidate: SIMD3<Float>,
                                  direction: SIMD3<Float>,
                                  fallback: SIMD3<Float>) -> SIMD3<Float> {
    var resolved = candidate
    if simd_length_squared(resolved) <= 0.000_001 {
        resolved = fallback
    }
    if simd_dot(resolved, direction) > 0 {
        resolved *= -1
    }
    return normalizedAxis(resolved, fallback: fallback)
}

private func raycastBoxInterval(min: SIMD3<Float>,
                                max: SIMD3<Float>,
                                origin: SIMD3<Float>,
                                direction: SIMD3<Float>,
                                maxDistance: Float) -> (entryDistance: Float, exitDistance: Float, normal: SIMD3<Float>)? {
    var entryDistance: Float = 0
    var exitDistance = maxDistance
    var entryNormal = SIMD3<Float>.zero

    for axis in 0..<3 {
        let originValue = origin[axis]
        let directionValue = direction[axis]
        let minValue = min[axis]
        let maxValue = max[axis]

        if abs(directionValue) <= 0.000_001 {
            guard originValue >= minValue && originValue <= maxValue else { return nil }
            continue
        }

        let inverseDirection = 1 / directionValue
        var t0 = (minValue - originValue) * inverseDirection
        var t1 = (maxValue - originValue) * inverseDirection
        var axisNormal = SIMD3<Float>.zero
        axisNormal[axis] = -1

        if t0 > t1 {
            swap(&t0, &t1)
            axisNormal[axis] = 1
        }

        if t0 > entryDistance {
            entryDistance = t0
            entryNormal = axisNormal
        }
        exitDistance = Swift.min(exitDistance, t1)

        guard entryDistance <= exitDistance else { return nil }
    }

    guard entryDistance <= maxDistance else { return nil }
    return (entryDistance, exitDistance, entryNormal)
}

private func raycastBox(min: SIMD3<Float>,
                        max: SIMD3<Float>,
                        origin: SIMD3<Float>,
                        direction: SIMD3<Float>,
                        maxDistance: Float) -> (distance: Float, position: SIMD3<Float>, normal: SIMD3<Float>)? {
    guard let interval = raycastBoxInterval(min: min,
                                            max: max,
                                            origin: origin,
                                            direction: direction,
                                            maxDistance: maxDistance) else {
        return nil
    }
    let hitDistance = Swift.max(interval.entryDistance, 0)
    let position = origin + direction * hitDistance
    return (hitDistance, position, interval.normal)
}

private func raycastSphere(center: SIMD3<Float>,
                           radius: Float,
                           origin: SIMD3<Float>,
                           direction: SIMD3<Float>,
                           maxDistance: Float) -> (distance: Float, position: SIMD3<Float>, normal: SIMD3<Float>)? {
    let offset = origin - center
    let a = simd_dot(direction, direction)
    guard a > 0.000_001 else { return nil }
    let b = 2 * simd_dot(offset, direction)
    let c = simd_dot(offset, offset) - radius * radius
    let discriminant = b * b - 4 * a * c
    guard discriminant >= 0 else { return nil }

    let root = sqrt(discriminant)
    let inverseDenominator = 0.5 / a
    let first = (-b - root) * inverseDenominator
    let second = (-b + root) * inverseDenominator
    let hitDistance = smallestPositiveRayDistance(first, second, maxDistance: maxDistance)
    guard let hitDistance else { return nil }
    let position = origin + direction * hitDistance
    let normal = simd_normalize(position - center)
    return (hitDistance, position, normal)
}

private func raycastCapsule(center: SIMD3<Float>,
                            radius: Float,
                            halfHeight: Float,
                            origin: SIMD3<Float>,
                            direction: SIMD3<Float>,
                            maxDistance: Float) -> (distance: Float, position: SIMD3<Float>, normal: SIMD3<Float>)? {
    let localOrigin = origin - center
    let capTop = SIMD3<Float>(0, halfHeight, 0)
    let capBottom = SIMD3<Float>(0, -halfHeight, 0)

    var bestHit = raycastSphere(center: capTop,
                                radius: radius,
                                origin: localOrigin,
                                direction: direction,
                                maxDistance: maxDistance)

    if let bottomHit = raycastSphere(center: capBottom,
                                     radius: radius,
                                     origin: localOrigin,
                                     direction: direction,
                                     maxDistance: maxDistance),
       (bestHit == nil || bottomHit.distance < bestHit!.distance) {
        bestHit = bottomHit
    }

    let a = direction.x * direction.x + direction.z * direction.z
    if a > 0.000_001 {
        let b = 2 * (localOrigin.x * direction.x + localOrigin.z * direction.z)
        let c = localOrigin.x * localOrigin.x + localOrigin.z * localOrigin.z - radius * radius
        let discriminant = b * b - 4 * a * c
        if discriminant >= 0 {
            let root = sqrt(discriminant)
            let inverseDenominator = 0.5 / a
            let first = (-b - root) * inverseDenominator
            let second = (-b + root) * inverseDenominator

            for candidate in [first, second] where candidate >= 0 && candidate <= maxDistance {
                let y = localOrigin.y + direction.y * candidate
                guard y >= -halfHeight && y <= halfHeight else { continue }
                let position = localOrigin + direction * candidate
                let normal = simd_normalize(SIMD3<Float>(position.x, 0, position.z))
                let hit = (distance: candidate, position: position + center, normal: normal)
                if bestHit == nil || hit.distance < bestHit!.distance {
                    bestHit = hit
                }
                break
            }
        }
    }

    return bestHit
}

private func makeWorldRaycastHit(localHit: (distance: Float, position: SIMD3<Float>, normal: SIMD3<Float>),
                                 worldDirection: SIMD3<Float>,
                                 worldTransform: simd_float4x4,
                                 inverseMatrix: simd_float4x4) -> (distance: Float, position: SIMD3<Float>, normal: SIMD3<Float>) {
    let worldPosition = transformPoint(localHit.position, matrix: worldTransform)
    var worldNormal = transformNormal(localHit.normal, inverseMatrix: inverseMatrix)
    if simd_dot(worldNormal, worldDirection) > 0 {
        worldNormal *= -1
    }
    return (localHit.distance, worldPosition, worldNormal)
}

private func transformVector(_ vector: SIMD3<Float>, matrix: simd_float4x4) -> SIMD3<Float> {
    let transformed = matrix * SIMD4<Float>(vector.x, vector.y, vector.z, 0)
    return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
}

private func transformNormal(_ normal: SIMD3<Float>, inverseMatrix: simd_float4x4) -> SIMD3<Float> {
    let transformed = inverseMatrix.transpose * SIMD4<Float>(normal.x, normal.y, normal.z, 0)
    return simd_normalize(SIMD3<Float>(transformed.x, transformed.y, transformed.z))
}

private func smallestPositiveRayDistance(_ first: Float,
                                         _ second: Float,
                                         maxDistance: Float) -> Float? {
    if first >= 0 && first <= maxDistance {
        return first
    }
    if second >= 0 && second <= maxDistance {
        return second
    }
    return nil
}

private func normalizedAxis(_ axis: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(axis)
    guard length > 0.000_001 else { return fallback }
    return axis / length
}
