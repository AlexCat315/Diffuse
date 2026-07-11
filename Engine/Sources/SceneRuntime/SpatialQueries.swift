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

public final class SpatialQueryScratch: @unchecked Sendable {
    public init() {}
}

public struct SpatialIndexResource: Sendable, Equatable {
    public var entries: [SpatialIndexEntry]
    public var sourceRevision: UInt64

    public init(entries: [SpatialIndexEntry] = [],
                sourceRevision: UInt64 = 0) {
        self.entries = entries
        self.sourceRevision = sourceRevision
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

    return (
        SpatialIndexResource(entries: result.0, sourceRevision: world.revision),
        result.1
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
    case let .cylinder(radius, halfHeight, center):
        return transformedBounds(
            corners: boxCorners(
                center: center,
                halfExtents: SIMD3<Float>(radius, halfHeight, radius)
            ),
            matrix: worldTransform.matrix
        )
    case let .heightField(_, center),
         let .mesh(_, center),
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
    case let .heightField(resourceID, _),
         let .mesh(resourceID, _),
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
    case let .heightField(resourceID, center),
         let .mesh(resourceID, center),
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
