import Foundation
import SIMDCompat

public struct PhysicsQueryFilter: Sendable, Equatable {
    /// Legacy single-entity exclusion. New code can use `ignoredEntities` for
    /// self hierarchies and other multi-body exclusions.
    public var excludeEntity: EntityID?
    public var ignoredEntities: Set<EntityID>
    public var includeTriggers: Bool
    public var layerID: UInt16?
    public var layerMask: UInt16

    public init(
        excludeEntity: EntityID? = nil,
        ignoredEntities: Set<EntityID> = [],
        includeTriggers: Bool = false,
        layerID: UInt16? = nil,
        layerMask: UInt16 = .max
    ) {
        self.excludeEntity = excludeEntity
        self.ignoredEntities = ignoredEntities
        self.includeTriggers = includeTriggers
        self.layerID = layerID
        self.layerMask = layerMask
    }

    public var excludedEntities: Set<EntityID> {
        guard let excludeEntity else { return ignoredEntities }
        return ignoredEntities.union([excludeEntity])
    }
}

public struct PhysicsRaycastQuery: Sendable, Equatable {
    public var origin: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var maxDistance: Float

    public init(origin: SIMD3<Float>,
                direction: SIMD3<Float>,
                maxDistance: Float = .greatestFiniteMagnitude) {
        self.origin = origin
        self.direction = direction
        self.maxDistance = maxDistance
    }
}

public struct PhysicsRaycastHit: Sendable, Equatable {
    public var entity: EntityID
    public var subShapeID: UInt32
    public var distance: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID,
                subShapeID: UInt32 = 0,
                distance: Float,
                position: SIMD3<Float>,
                normal: SIMD3<Float>,
                bounds: SpatialAABB,
                isTrigger: Bool) {
        self.entity = entity
        self.subShapeID = subShapeID
        self.distance = distance
        self.position = position
        self.normal = normal
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}

public struct PhysicsOverlapAABBQuery: Sendable, Equatable {
    public var bounds: SpatialAABB
    /// Stop collecting hits after this many results. Default (.max) collects all.
    /// When set, sort order is not guaranteed.
    public var maxResults: Int

    public init(bounds: SpatialAABB, maxResults: Int = .max) {
        self.bounds = bounds
        self.maxResults = max(maxResults, 0)
    }
}

public struct PhysicsOverlapHit: Sendable, Equatable {
    public var entity: EntityID
    public var subShapeID: UInt32
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID, subShapeID: UInt32 = 0, bounds: SpatialAABB, isTrigger: Bool) {
        self.entity = entity
        self.subShapeID = subShapeID
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}

public enum PhysicsQueryShape: Sendable, Equatable {
    case box(halfExtents: SIMD3<Float>)
    case sphere(radius: Float)
    case capsule(radius: Float, halfHeight: Float)
}

public struct PhysicsOverlapShapeQuery: Sendable, Equatable {
    public var shape: PhysicsQueryShape
    public var position: SIMD3<Float>
    /// Quaternion stored as (x, y, z, w). Capsules are aligned to local Y before rotation.
    public var rotation: SIMD4<Float>
    /// Stop collecting hits after this many results. Default (.max) collects all.
    public var maxResults: Int

    public init(
        shape: PhysicsQueryShape,
        position: SIMD3<Float>,
        rotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        maxResults: Int = .max
    ) {
        self.shape = shape
        self.position = position
        self.rotation = rotation
        self.maxResults = max(maxResults, 0)
    }
}

public struct PhysicsSweepAABBQuery: Sendable, Equatable {
    public var bounds: SpatialAABB
    public var translation: SIMD3<Float>

    public init(bounds: SpatialAABB, translation: SIMD3<Float>) {
        self.bounds = bounds
        self.translation = translation
    }
}

public struct PhysicsSweepShapeQuery: Sendable, Equatable {
    public var shape: PhysicsQueryShape
    public var position: SIMD3<Float>
    /// Quaternion stored as (x, y, z, w). Capsules are aligned to local Y before rotation.
    public var rotation: SIMD4<Float>
    public var translation: SIMD3<Float>

    public init(
        shape: PhysicsQueryShape,
        position: SIMD3<Float>,
        rotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        translation: SIMD3<Float>
    ) {
        self.shape = shape
        self.position = position
        self.rotation = rotation
        self.translation = translation
    }
}

public struct PhysicsSweepHit: Sendable, Equatable {
    public var entity: EntityID
    public var subShapeID: UInt32
    public var fraction: Float
    public var distance: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID,
                subShapeID: UInt32 = 0,
                fraction: Float,
                distance: Float,
                position: SIMD3<Float>,
                normal: SIMD3<Float>,
                bounds: SpatialAABB,
                isTrigger: Bool) {
        self.entity = entity
        self.subShapeID = subShapeID
        self.fraction = fraction
        self.distance = distance
        self.position = position
        self.normal = normal
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}

public enum PhysicsQueryResultMode: Sendable, Equatable {
    case nearest
    case all
}

public struct PhysicsQueryOptions: Sendable, Equatable {
    public var filter: PhysicsQueryFilter
    public var resultMode: PhysicsQueryResultMode
    public var maxHits: Int

    public init(
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        resultMode: PhysicsQueryResultMode = .nearest,
        maxHits: Int = .max
    ) {
        self.filter = filter
        self.resultMode = resultMode
        self.maxHits = max(0, maxHits)
    }
}

public struct PhysicsHit: Sendable, Equatable {
    public var entity: EntityID
    public var subShapeID: UInt32
    public var distance: Float
    public var fraction: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(
        entity: EntityID,
        subShapeID: UInt32 = 0,
        distance: Float = 0,
        fraction: Float = 0,
        position: SIMD3<Float> = .zero,
        normal: SIMD3<Float> = .zero,
        bounds: SpatialAABB,
        isTrigger: Bool
    ) {
        self.entity = entity
        self.subShapeID = subShapeID
        self.distance = distance
        self.fraction = fraction
        self.position = position
        self.normal = normal
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}
