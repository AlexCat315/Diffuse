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

    public func intersects(_ other: SpatialAABB) -> Bool {
        min.x <= other.max.x && max.x >= other.min.x &&
        min.y <= other.max.y && max.y >= other.min.y &&
        min.z <= other.max.z && max.z >= other.min.z
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

public struct SpatialIndexResource: Sendable, Equatable {
    public var entries: [SpatialIndexEntry]
    public var sourceRevision: UInt64

    public init(entries: [SpatialIndexEntry] = [], sourceRevision: UInt64 = 0) {
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
    let entries: [SpatialIndexEntry] = world.entities().compactMap { entity in
        guard let collider = world.component(Collider.self, for: entity),
              let worldTransform = world.worldTransform(for: entity),
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

    return SpatialIndexResource(entries: entries, sourceRevision: world.revision)
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
                           using index: SpatialIndexResource) -> [SceneOverlapHit] {
    performPhysicsOverlapAABB(
        PhysicsOverlapAABBQuery(bounds: query.bounds),
        filter: PhysicsQueryFilter(includeTriggers: query.includeTriggers),
        using: index
    ).map(makeSceneOverlapHit)
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
                           using index: SpatialIndexResource) -> PhysicsRaycastHit? {
    let directionLength = simd_length(query.direction)
    guard directionLength > 0.000_001 else { return nil }
    let direction = query.direction / directionLength
    let maxDistance = max(query.maxDistance, 0)

    var resolvedHit: PhysicsRaycastHit?
    for entry in index.entries {
        guard matchesPhysicsQueryFilter(entry, filter: filter) else { continue }
        guard raycastBox(min: entry.bounds.min,
                         max: entry.bounds.max,
                         origin: query.origin,
                         direction: direction,
                         maxDistance: maxDistance) != nil,
              let result = preciseRaycast(shape: entry.shape,
                                          worldTransform: entry.worldTransform,
                                          origin: query.origin,
                                          direction: direction,
                                          maxDistance: maxDistance) else {
            continue
        }

        if let existing = resolvedHit, existing.distance <= result.distance {
            continue
        }

        resolvedHit = PhysicsRaycastHit(
            entity: entry.entity,
            distance: result.distance,
            position: result.position,
            normal: result.normal,
            bounds: entry.bounds,
            isTrigger: entry.isTrigger
        )
    }

    return resolvedHit
}

func performPhysicsOverlapAABB(_ query: PhysicsOverlapAABBQuery,
                               filter: PhysicsQueryFilter,
                               using index: SpatialIndexResource) -> [PhysicsOverlapHit] {
    index.entries
        .filter { entry in
            guard matchesPhysicsQueryFilter(entry, filter: filter) else { return false }
            guard entry.bounds.intersects(query.bounds) else { return false }
            return preciseOverlap(shape: entry.shape,
                                  worldTransform: entry.worldTransform,
                                  queryBounds: query.bounds)
        }
        .sorted { $0.entity.rawValue < $1.entity.rawValue }
        .map { entry in
            PhysicsOverlapHit(entity: entry.entity, bounds: entry.bounds, isTrigger: entry.isTrigger)
        }
}

func performPhysicsSweepAABB(_ query: PhysicsSweepAABBQuery,
                             filter: PhysicsQueryFilter,
                             using index: SpatialIndexResource) -> PhysicsSweepHit? {
    guard query.bounds.isValid else { return nil }

    let travelDistance = simd_length(query.translation)
    guard travelDistance > 0.000_001 else { return nil }

    let direction = query.translation / travelDistance
    let queryCenter = query.bounds.center
    let queryHalfExtents = query.bounds.halfExtents

    var resolvedHit: PhysicsSweepHit?
    for entry in index.entries {
        guard matchesPhysicsQueryFilter(entry, filter: filter) else { continue }

        let expandedBounds = expandedAABB(entry.bounds, by: queryHalfExtents)
        guard let interval = raycastBoxInterval(min: expandedBounds.min,
                                               max: expandedBounds.max,
                                               origin: queryCenter,
                                               direction: direction,
                                               maxDistance: travelDistance),
              let hit = preciseSweep(shape: entry.shape,
                                     worldTransform: entry.worldTransform,
                                     queryBounds: query.bounds,
                                     direction: direction,
                                     maxDistance: travelDistance,
                                     broadPhaseInterval: interval) else {
            continue
        }

        if let existing = resolvedHit, existing.distance <= hit.distance {
            continue
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