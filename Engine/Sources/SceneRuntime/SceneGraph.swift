import SIMDCompat

// MARK: - Scene Graph Traversal

extension RuntimeWorld {

    // MARK: Subtree queries

    /// All descendants of `entity` (depth-first, pre-order).
    public func descendants(of entity: EntityID) -> [EntityID] {
        guard contains(entity) else { return [] }
        var result: [EntityID] = []
        var stack = children(of: entity)
        while !stack.isEmpty {
            let child = stack.removeLast()
            guard contains(child) else { continue }
            result.append(child)
            stack.append(contentsOf: children(of: child).reversed())
        }
        return result
    }

    /// All ancestors from `entity` up to the root (parent, grandparent, 鈥?.
    public func ancestors(of entity: EntityID) -> [EntityID] {
        guard contains(entity) else { return [] }
        var result: [EntityID] = []
        var current = parent(of: entity)
        while let p = current {
            result.append(p)
            current = parent(of: p)
        }
        return result
    }

    /// Depth of `entity` in the hierarchy (root = 0).
    public func depth(of entity: EntityID) -> Int {
        ancestors(of: entity).count
    }

    /// The root ancestor of `entity`.
    public func rootAncestor(of entity: EntityID) -> EntityID? {
        ancestors(of: entity).last
    }

    // MARK: Subtree iteration

    /// Depth-first pre-order traversal of the subtree rooted at `entity`,
    /// including `entity` itself.
    public func traverseDepthFirst(from entity: EntityID) -> [EntityID] {
        guard contains(entity) else { return [] }
        var result: [EntityID] = []
        var stack: [EntityID] = [entity]
        while let current = stack.popLast() {
            result.append(current)
            let kids = children(of: current)
            stack.append(contentsOf: kids.reversed())
        }
        return result
    }

    /// Breadth-first traversal of the subtree rooted at `entity`,
    /// including `entity` itself.
    public func traverseBreadthFirst(from entity: EntityID) -> [EntityID] {
        guard contains(entity) else { return [] }
        var result: [EntityID] = []
        var queue: [EntityID] = [entity]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            result.append(current)
            queue.append(contentsOf: children(of: current))
        }
        return result
    }

    // MARK: Global traversal

    /// All entities in the world, traversed depth-first from each root.
    /// Equivalent to iterating the entire scene graph in insertion order.
    public func allEntitiesDepthFirst() -> [EntityID] {
        roots().flatMap { traverseDepthFirst(from: $0) }
    }

    /// All entities in the world, traversed breadth-first from each root.
    public func allEntitiesBreadthFirst() -> [EntityID] {
        roots().flatMap { traverseBreadthFirst(from: $0) }
    }

    // MARK: Leaf queries

    /// Returns true when `entity` has no children.
    public func isLeaf(_ entity: EntityID) -> Bool {
        children(of: entity).isEmpty
    }

    /// All leaf entities in the subtree rooted at `entity`.
    public func leaves(of entity: EntityID) -> [EntityID] {
        traverseDepthFirst(from: entity).filter { isLeaf($0) }
    }

    // MARK: Subtree transforms

    /// Collects the `WorldTransform` for every entity in the subtree rooted
    /// at `entity`, keyed by entity ID. Requires `propagateTransforms()` to
    /// have run first so world matrices are up-to-date.
    public func worldTransforms(in subtree: EntityID) -> [EntityID: WorldTransform] {
        let ids = traverseDepthFirst(from: subtree)
        var result: [EntityID: WorldTransform] = [:]
        result.reserveCapacity(ids.count)
        for id in ids {
            if let wt = worldTransform(for: id) {
                result[id] = wt
            }
        }
        return result
    }

    /// Computes the local transform that, when applied to `entity`'s children,
    /// yields the given `world` matrix. Returns `nil` if `entity` has no
    /// world transform or no parent.
    public func localTransform(forWorld world: simd_float4x4,
                               entity: EntityID) -> simd_float4x4? {
        guard let parent = parent(of: entity),
              let parentWorld = worldTransform(for: parent)
        else { return world }
        return simd_inverse(parentWorld.matrix) * world
    }
}
