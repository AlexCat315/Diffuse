import Foundation
import simd
import EngineKernel

public struct RuntimeWorldSummary: Sendable {
    public var entityCount: Int
    public var componentStoreCount: Int
    public var resourceCount: Int
    public var revision: UInt64

    public init(
        entityCount: Int = 0,
        componentStoreCount: Int = 0,
        resourceCount: Int = 0,
        revision: UInt64 = 0
    ) {
        self.entityCount = entityCount
        self.componentStoreCount = componentStoreCount
        self.resourceCount = resourceCount
        self.revision = revision
    }
}

public struct LocalTransform: RuntimeComponent, Sendable, Equatable {
    public static let identity = LocalTransform()

    public var matrix: simd_float4x4

    public init(matrix: simd_float4x4 = matrix_identity_float4x4) {
        self.matrix = matrix
    }

    public init(translation: SIMD3<Float>) {
        self.matrix = translationMatrix(translation)
    }

    public var translation: SIMD3<Float> {
        SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }
}

public struct WorldTransform: RuntimeComponent, Sendable, Equatable {
    public static let identity = WorldTransform()

    public var matrix: simd_float4x4

    public init(matrix: simd_float4x4 = matrix_identity_float4x4) {
        self.matrix = matrix
    }

    public var translation: SIMD3<Float> {
        SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }
}

public struct Parent: RuntimeComponent, Sendable, Equatable {
    public var entity: EntityID

    public init(entity: EntityID) {
        self.entity = entity
    }
}

public struct Children: RuntimeComponent, Sendable, Equatable {
    public var entities: [EntityID]

    public init(entities: [EntityID] = []) {
        self.entities = entities
    }
}

public struct RuntimeWorld: @unchecked Sendable {
    private struct HierarchyReadSnapshot {
        var entities: [EntityID]
        var localMatrices: [EntityID: simd_float4x4]
        var parentByEntity: [EntityID: EntityID]
        var childrenByEntity: [EntityID: [EntityID]]
    }

    private struct EntitySlot {
        var generation: UInt32 = 0
        var isAlive = false
    }

    private protocol AnyComponentStoreBox: AnyObject {
        func removeValue(for entity: EntityID)
    }

    private final class ComponentStoreBox<Component: RuntimeComponent>: AnyComponentStoreBox {
        var values: [EntityID: Component] = [:]

        func removeValue(for entity: EntityID) {
            values.removeValue(forKey: entity)
        }
    }

    private struct ComponentStores {
        private var boxes: [ObjectIdentifier: AnyObject] = [:]

        var count: Int { boxes.count }

        mutating func set<Component: RuntimeComponent>(_ component: Component, for entity: EntityID) {
            let box = mutableBox(for: Component.self)
            box.values[entity] = component
        }

        func get<Component: RuntimeComponent>(_ type: Component.Type, for entity: EntityID) -> Component? {
            let key = ObjectIdentifier(type)
            guard let box = boxes[key] as? ComponentStoreBox<Component> else { return nil }
            return box.values[entity]
        }

        mutating func remove<Component: RuntimeComponent>(_ type: Component.Type, for entity: EntityID) -> Component? {
            let key = ObjectIdentifier(type)
            guard let box = boxes[key] as? ComponentStoreBox<Component> else { return nil }
            return box.values.removeValue(forKey: entity)
        }

        mutating func update<Component: RuntimeComponent>(
            _ type: Component.Type,
            for entity: EntityID,
            _ body: (inout Component) -> Void
        ) -> Bool {
            let key = ObjectIdentifier(type)
            guard let box = boxes[key] as? ComponentStoreBox<Component>,
                  var component = box.values[entity]
            else {
                return false
            }
            body(&component)
            box.values[entity] = component
            return true
        }

        mutating func removeAll(for entity: EntityID) {
            for value in boxes.values {
                (value as? AnyComponentStoreBox)?.removeValue(for: entity)
            }
        }

        private mutating func mutableBox<Component: RuntimeComponent>(
            for type: Component.Type
        ) -> ComponentStoreBox<Component> {
            let key = ObjectIdentifier(type)
            if let existing = boxes[key] as? ComponentStoreBox<Component> {
                return existing
            }
            let created = ComponentStoreBox<Component>()
            boxes[key] = created
            return created
        }
    }

    private final class ResourceBox<Resource: Sendable> {
        var value: Resource

        init(_ value: Resource) {
            self.value = value
        }
    }

    private struct ResourceStorage {
        private var boxes: [ObjectIdentifier: AnyObject] = [:]

        var count: Int { boxes.count }

        mutating func set<Resource: Sendable>(_ resource: Resource) {
            let key = ObjectIdentifier(Resource.self)
            if let box = boxes[key] as? ResourceBox<Resource> {
                box.value = resource
                return
            }
            boxes[key] = ResourceBox(resource)
        }

        func get<Resource: Sendable>(_ type: Resource.Type) -> Resource? {
            let key = ObjectIdentifier(type)
            guard let box = boxes[key] as? ResourceBox<Resource> else { return nil }
            return box.value
        }

        mutating func update<Resource: Sendable>(
            _ type: Resource.Type,
            _ body: (inout Resource) -> Void
        ) -> Bool {
            let key = ObjectIdentifier(type)
            guard let box = boxes[key] as? ResourceBox<Resource> else { return false }
            body(&box.value)
            return true
        }

        mutating func remove<Resource: Sendable>(_ type: Resource.Type) -> Resource? {
            let key = ObjectIdentifier(type)
            guard let box = boxes[key] as? ResourceBox<Resource> else { return nil }
            boxes.removeValue(forKey: key)
            return box.value
        }
    }

    private var slots: [EntitySlot] = []
    private var freeIndices: [Int] = []
    private var components = ComponentStores()
    private var resources = ResourceStorage()
    private var rootEntities: [EntityID] = []
    private var dirtyHierarchyEntities: Set<EntityID> = []

    public private(set) var entityCount = 0
    public private(set) var revision: UInt64 = 0

    public init() {}

    public var snapshot: SceneRuntimeSnapshot {
        SceneRuntimeSnapshot(entityCount: entityCount, revision: revision)
    }

    public var summary: RuntimeWorldSummary {
        RuntimeWorldSummary(
            entityCount: entityCount,
            componentStoreCount: components.count,
            resourceCount: resources.count,
            revision: revision
        )
    }

    public func entities() -> [EntityID] {
        var result: [EntityID] = []
        result.reserveCapacity(entityCount)
        for (index, slot) in slots.enumerated() where slot.isAlive {
            result.append(EntityID(index: UInt32(index), generation: slot.generation))
        }
        return result
    }

    public func roots() -> [EntityID] {
        normalizedRoots()
    }

    @discardableResult
    public mutating func createEntity() -> EntityID {
        let id: EntityID
        if let reusedIndex = freeIndices.popLast() {
            slots[reusedIndex].isAlive = true
            let slot = slots[reusedIndex]
            id = EntityID(index: UInt32(reusedIndex), generation: slot.generation)
        } else {
            let index = slots.count
            let slot = EntitySlot(generation: 0, isAlive: true)
            slots.append(slot)
            id = EntityID(index: UInt32(index), generation: slot.generation)
        }
        entityCount += 1
        rootEntities.append(id)
        revision &+= 1
        return id
    }

    @discardableResult
    public mutating func destroyEntity(_ entity: EntityID) -> Bool {
        guard contains(entity) else { return false }

        let previousParent = parent(of: entity)
        let previousChildren = children(of: entity)
        let previousRootIndex = rootEntities.firstIndex(of: entity)
        if let previousParent {
            detachChild(entity, from: previousParent)
            markHierarchyDirty(previousParent)
        } else {
            detachRoot(entity)
        }
        var rootInsertIndex = previousRootIndex
        for child in previousChildren {
            clearParent(for: child)
            if let insertIndex = rootInsertIndex {
                attachRoot(child, at: insertIndex)
                rootInsertIndex = insertIndex + 1
            } else {
                attachRoot(child)
            }
            markHierarchyDirty(child)
        }

        let index = Int(entity.index)
        slots[index].isAlive = false
        slots[index].generation &+= 1
        freeIndices.append(index)
        entityCount -= 1
        components.removeAll(for: entity)
        dirtyHierarchyEntities.remove(entity)
        revision &+= 1
        return true
    }

    public func contains(_ entity: EntityID) -> Bool {
        let index = Int(entity.index)
        guard slots.indices.contains(index) else { return false }
        let slot = slots[index]
        return slot.isAlive && slot.generation == entity.generation
    }

    @discardableResult
    public mutating func setComponent<Component: RuntimeComponent>(
        _ component: Component,
        for entity: EntityID
    ) -> Bool {
        guard contains(entity) else { return false }
        components.set(component, for: entity)
        revision &+= 1
        return true
    }

    public func component<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID
    ) -> Component? {
        guard contains(entity) else { return nil }
        return components.get(type, for: entity)
    }

    public func hasComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID
    ) -> Bool {
        component(type, for: entity) != nil
    }

    @discardableResult
    public mutating func updateComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID,
        _ body: (inout Component) -> Void
    ) -> Bool {
        guard contains(entity) else { return false }
        let updated = components.update(type, for: entity, body)
        if updated {
            revision &+= 1
        }
        return updated
    }

    @discardableResult
    public mutating func removeComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        from entity: EntityID
    ) -> Component? {
        guard contains(entity) else { return nil }
        let removed = components.remove(type, for: entity)
        if removed != nil {
            revision &+= 1
        }
        return removed
    }

    public mutating func setResource<Resource: Sendable>(_ resource: Resource) {
        resources.set(resource)
        revision &+= 1
    }

    public func resource<Resource: Sendable>(_ type: Resource.Type) -> Resource? {
        resources.get(type)
    }

    @discardableResult
    public mutating func updateResource<Resource: Sendable>(
        _ type: Resource.Type,
        _ body: (inout Resource) -> Void
    ) -> Bool {
        let updated = resources.update(type, body)
        if updated {
            revision &+= 1
        }
        return updated
    }

    @discardableResult
    public mutating func removeResource<Resource: Sendable>(_ type: Resource.Type) -> Resource? {
        let removed = resources.remove(type)
        if removed != nil {
            revision &+= 1
        }
        return removed
    }

    public mutating func advanceRevision() {
        revision &+= 1
    }

    mutating func setDerivedComponent<Component: RuntimeComponent>(
        _ component: Component,
        for entity: EntityID
    ) {
        guard contains(entity) else { return }
        components.set(component, for: entity)
    }

    mutating func setDerivedResource<Resource: Sendable>(_ resource: Resource) {
        resources.set(resource)
    }

    @discardableResult
    public mutating func setLocalTransform(
        _ transform: LocalTransform,
        for entity: EntityID
    ) -> Bool {
        guard contains(entity) else { return false }
        components.set(transform, for: entity)
        markHierarchyDirty(entity)
        revision &+= 1
        return true
    }

    public func localTransform(for entity: EntityID) -> LocalTransform? {
        guard contains(entity) else { return nil }
        return components.get(LocalTransform.self, for: entity) ?? .identity
    }

    public func worldTransform(for entity: EntityID) -> WorldTransform? {
        guard contains(entity) else { return nil }
        return components.get(WorldTransform.self, for: entity) ?? .identity
    }

    public func parent(of entity: EntityID) -> EntityID? {
        guard contains(entity) else { return nil }
        return components.get(Parent.self, for: entity)?.entity
    }

    public func children(of entity: EntityID) -> [EntityID] {
        guard contains(entity) else { return [] }
        return components.get(Children.self, for: entity)?.entities.filter(contains) ?? []
    }

    @discardableResult
    public mutating func setParent(_ parent: EntityID?, for child: EntityID) -> Bool {
        guard contains(child) else { return false }
        if let parent {
            guard contains(parent), parent != child, !isDescendant(parent, of: child) else {
                return false
            }
        }

        let previousParent = self.parent(of: child)
        if previousParent == parent {
            return true
        }

        if let previousParent {
            detachChild(child, from: previousParent)
            markHierarchyDirty(previousParent)
        } else {
            // child was a root; detach it so it doesn't appear twice after reparenting.
            detachRoot(child)
        }

        if let parent {
            attachChild(child, to: parent)
            components.set(Parent(entity: parent), for: child)
            markHierarchyDirty(parent)
        } else {
            clearParent(for: child)
            // child becomes a root again; append to the ordered root list.
            attachRoot(child)
        }

        markHierarchyDirty(child)
        revision &+= 1
        return true
    }

    @discardableResult
    public mutating func moveEntity(_ entity: EntityID,
                                    to parent: EntityID?,
                                    at index: Int) -> Bool {
        guard contains(entity) else { return false }
        if let parent {
            guard contains(parent), parent != entity, !isDescendant(parent, of: entity) else {
                return false
            }
        }

        let previousParent = self.parent(of: entity)
        if previousParent == parent {
            if let parent {
                return reorderChild(entity, in: parent, to: index)
            }
            return reorderRoot(entity, to: index)
        }

        if let previousParent {
            detachChild(entity, from: previousParent)
            markHierarchyDirty(previousParent)
        } else {
            detachRoot(entity)
        }

        if let parent {
            insertChild(entity, into: parent, at: index)
            components.set(Parent(entity: parent), for: entity)
            markHierarchyDirty(parent)
        } else {
            clearParent(for: entity)
            attachRoot(entity, at: index)
        }

        markHierarchyDirty(entity)
        revision &+= 1
        return true
    }

    public func hierarchyNeedsPropagation() -> Bool {
        !dirtyHierarchyEntities.isEmpty
    }

    public mutating func propagateTransforms() {
        _ = propagateTransforms(using: .shared)
    }

    @discardableResult
    public mutating func propagateTransforms(using jobSystem: JobSystem) -> JobDispatchReport {
        guard hierarchyNeedsPropagation() else {
            return JobDispatchReport(jobCount: 0, workerCount: jobSystem.workerCount, executedInParallel: false)
        }

        let snapshot = hierarchyReadSnapshot()
        let entitySet = Set(snapshot.entities)
        var worldMatrices: [EntityID: simd_float4x4] = [:]
        worldMatrices.reserveCapacity(snapshot.entities.count)
        var visited = Set<EntityID>()
        var totalJobCount = 0
        var executedInParallel = false

        var roots: [EntityID] = []
        roots.reserveCapacity(snapshot.entities.count)
        for entity in snapshot.entities {
            if let parent = snapshot.parentByEntity[entity], entitySet.contains(parent) {
                continue
            }
            roots.append(entity)
        }

        var frontier = roots
        while !frontier.isEmpty {
            let currentFrontier = frontier
            let parentWorldMatrices = worldMatrices
            let computed = jobSystem.parallelCompactMap(items: currentFrontier, minimumChunkSize: 1) {
                entity -> simd_float4x4? in
                let localMatrix = snapshot.localMatrices[entity] ?? matrix_identity_float4x4
                let parentMatrix: simd_float4x4
                if let parent = snapshot.parentByEntity[entity], let cachedParent = parentWorldMatrices[parent] {
                    parentMatrix = cachedParent
                } else {
                    parentMatrix = matrix_identity_float4x4
                }
                return parentMatrix * localMatrix
            }

            totalJobCount += computed.1.jobCount
            executedInParallel = executedInParallel || computed.1.executedInParallel

            var nextFrontier: [EntityID] = []
            for (index, entity) in currentFrontier.enumerated() {
                let worldMatrix = computed.0[index]
                worldMatrices[entity] = worldMatrix
                components.set(WorldTransform(matrix: worldMatrix), for: entity)
                visited.insert(entity)
                if let children = snapshot.childrenByEntity[entity] {
                    for child in children where !visited.contains(child) {
                        nextFrontier.append(child)
                    }
                }
            }
            frontier = nextFrontier
        }

        for entity in snapshot.entities where !visited.contains(entity) {
            propagateTransforms(
                from: entity,
                parentWorldMatrix: matrix_identity_float4x4,
                visited: &visited,
                localMatrices: snapshot.localMatrices,
                childrenByEntity: snapshot.childrenByEntity
            )
        }

        dirtyHierarchyEntities.removeAll(keepingCapacity: true)
        revision &+= 1

        return JobDispatchReport(
            jobCount: totalJobCount,
            workerCount: jobSystem.workerCount,
            executedInParallel: executedInParallel
        )
    }

    private mutating func attachChild(_ child: EntityID, to parent: EntityID) {
        var current = components.get(Children.self, for: parent)?.entities ?? []
        if !current.contains(child) {
            current.append(child)
            components.set(Children(entities: current), for: parent)
        }
    }

    private mutating func insertChild(_ child: EntityID, into parent: EntityID, at index: Int) {
        var current = components.get(Children.self, for: parent)?.entities.filter(contains) ?? []
        current.removeAll { $0 == child }
        let insertIndex = max(0, min(index, current.count))
        current.insert(child, at: insertIndex)
        components.set(Children(entities: current), for: parent)
    }

    private mutating func detachChild(_ child: EntityID, from parent: EntityID) {
        var current = components.get(Children.self, for: parent)?.entities ?? []
        current.removeAll { $0 == child || !contains($0) }
        if current.isEmpty {
            _ = components.remove(Children.self, for: parent)
        } else {
            components.set(Children(entities: current), for: parent)
        }
    }

    private mutating func clearParent(for child: EntityID) {
        _ = components.remove(Parent.self, for: child)
    }

    @discardableResult
    private mutating func reorderChild(_ child: EntityID, in parent: EntityID, to index: Int) -> Bool {
        var current = components.get(Children.self, for: parent)?.entities.filter(contains) ?? []
        guard let existingIndex = current.firstIndex(of: child) else { return false }
        let clampedIndex = max(0, min(index, current.count - 1))
        var destinationIndex = clampedIndex
        if existingIndex < clampedIndex {
            destinationIndex -= 1
        }
        guard existingIndex != destinationIndex else { return true }
        current.remove(at: existingIndex)
        current.insert(child, at: min(destinationIndex, current.count))
        components.set(Children(entities: current), for: parent)
        markHierarchyDirty(parent)
        markHierarchyDirty(child)
        revision &+= 1
        return true
    }

    @discardableResult
    private mutating func reorderRoot(_ entity: EntityID, to index: Int) -> Bool {
        var currentRoots = normalizedRoots()
        guard let existingIndex = currentRoots.firstIndex(of: entity) else { return false }
        let clampedIndex = max(0, min(index, currentRoots.count - 1))
        var destinationIndex = clampedIndex
        if existingIndex < clampedIndex {
            destinationIndex -= 1
        }
        guard existingIndex != destinationIndex else { return true }
        currentRoots.remove(at: existingIndex)
        currentRoots.insert(entity, at: min(destinationIndex, currentRoots.count))
        rootEntities = currentRoots
        markHierarchyDirty(entity)
        revision &+= 1
        return true
    }

    private mutating func attachRoot(_ entity: EntityID, at index: Int? = nil) {
        var currentRoots = normalizedRoots()
        currentRoots.removeAll { $0 == entity }
        if let index {
            let insertIndex = max(0, min(index, currentRoots.count))
            currentRoots.insert(entity, at: insertIndex)
        } else {
            currentRoots.append(entity)
        }
        rootEntities = currentRoots
    }

    private mutating func detachRoot(_ entity: EntityID) {
        let currentRoots = normalizedRoots().filter { $0 != entity }
        rootEntities = currentRoots
    }

    private func normalizedRoots() -> [EntityID] {
        var seen: Set<EntityID> = []
        var normalized: [EntityID] = []
        normalized.reserveCapacity(rootEntities.count)
        for entity in rootEntities where contains(entity) {
            guard parent(of: entity) == nil else { continue }
            guard !seen.contains(entity) else { continue }
            seen.insert(entity)
            normalized.append(entity)
        }
        return normalized
    }

    private mutating func markHierarchyDirty(_ entity: EntityID) {
        guard contains(entity) else { return }
        dirtyHierarchyEntities.insert(entity)
    }

    private func isDescendant(_ entity: EntityID, of ancestor: EntityID) -> Bool {
        var current = parent(of: entity)
        while let currentEntity = current {
            if currentEntity == ancestor {
                return true
            }
            current = parent(of: currentEntity)
        }
        return false
    }

    private mutating func propagateTransforms(
        from entity: EntityID,
        parentWorldMatrix: simd_float4x4,
        visited: inout Set<EntityID>
    ) {
        guard contains(entity), !visited.contains(entity) else { return }
        visited.insert(entity)

        let localMatrix = components.get(LocalTransform.self, for: entity)?.matrix ?? matrix_identity_float4x4
        let worldMatrix = parentWorldMatrix * localMatrix
        components.set(WorldTransform(matrix: worldMatrix), for: entity)

        for child in children(of: entity) {
            propagateTransforms(from: child, parentWorldMatrix: worldMatrix, visited: &visited)
        }
    }

    private mutating func propagateTransforms(
        from entity: EntityID,
        parentWorldMatrix: simd_float4x4,
        visited: inout Set<EntityID>,
        localMatrices: [EntityID: simd_float4x4],
        childrenByEntity: [EntityID: [EntityID]]
    ) {
        guard contains(entity), !visited.contains(entity) else { return }
        visited.insert(entity)

        let localMatrix = localMatrices[entity] ?? matrix_identity_float4x4
        let worldMatrix = parentWorldMatrix * localMatrix
        components.set(WorldTransform(matrix: worldMatrix), for: entity)

        for child in childrenByEntity[entity] ?? [] {
            propagateTransforms(
                from: child,
                parentWorldMatrix: worldMatrix,
                visited: &visited,
                localMatrices: localMatrices,
                childrenByEntity: childrenByEntity
            )
        }
    }

    private func hierarchyReadSnapshot() -> HierarchyReadSnapshot {
        let entities = entities()
        let entitySet = Set(entities)

        var localMatrices: [EntityID: simd_float4x4] = [:]
        localMatrices.reserveCapacity(entities.count)
        var parentByEntity: [EntityID: EntityID] = [:]
        parentByEntity.reserveCapacity(entities.count)
        var childrenByEntity: [EntityID: [EntityID]] = [:]
        childrenByEntity.reserveCapacity(entities.count)

        for entity in entities {
            localMatrices[entity] = components.get(LocalTransform.self, for: entity)?.matrix ?? matrix_identity_float4x4
            if let parent = components.get(Parent.self, for: entity)?.entity,
               entitySet.contains(parent) {
                parentByEntity[entity] = parent
            }
            if let children = components.get(Children.self, for: entity)?.entities {
                childrenByEntity[entity] = children.filter { entitySet.contains($0) }
            }
        }

        return HierarchyReadSnapshot(
            entities: entities,
            localMatrices: localMatrices,
            parentByEntity: parentByEntity,
            childrenByEntity: childrenByEntity
        )
    }

    mutating func applyPhysicsWriteback(_ writeback: PhysicsBodyWriteback) -> Bool {
        guard contains(writeback.entity) else { return false }

        if let worldTransform = writeback.worldTransform {
            let localMatrix: simd_float4x4
            if let parent = parent(of: writeback.entity),
               let parentWorldTransform = self.worldTransform(for: parent) {
                localMatrix = simd_inverse(parentWorldTransform.matrix) * worldTransform.matrix
            } else {
                localMatrix = worldTransform.matrix
            }
            components.set(LocalTransform(matrix: localMatrix), for: writeback.entity)
            components.set(worldTransform, for: writeback.entity)
            markHierarchyDirty(writeback.entity)
        }

        if var body = component(RigidBody.self, for: writeback.entity) {
            if let linearVelocity = writeback.linearVelocity {
                body.linearVelocity = linearVelocity
            }
            if let angularVelocity = writeback.angularVelocity {
                body.angularVelocity = angularVelocity
            }
            if let isSleeping = writeback.isSleeping {
                body.isSleeping = isSleeping
            }
            components.set(body, for: writeback.entity)
        }

        return true
    }
}

private func translationMatrix(_ translation: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(1, 0, 0, translation.x),
        SIMD4<Float>(0, 1, 0, translation.y),
        SIMD4<Float>(0, 0, 1, translation.z),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}
