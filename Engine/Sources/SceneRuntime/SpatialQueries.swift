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
    let directionLength = simd_length(query.direction)
    guard directionLength > 0.000_001 else { return nil }
    let direction = query.direction / directionLength
    let maxDistance = max(query.maxDistance, 0)

    var resolvedHit: SceneRaycastHit?
    for entry in index.entries {
        guard query.includeTriggers || !entry.isTrigger else { continue }
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

        resolvedHit = SceneRaycastHit(
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

func performSpatialOverlap(_ query: SceneOverlapQuery,
                           using index: SpatialIndexResource) -> [SceneOverlapHit] {
    index.entries
        .filter { entry in
            (query.includeTriggers || !entry.isTrigger) && entry.bounds.intersects(query.bounds)
        }
        .sorted { $0.entity.rawValue < $1.entity.rawValue }
        .map { entry in
            SceneOverlapHit(entity: entry.entity, bounds: entry.bounds, isTrigger: entry.isTrigger)
        }
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

private func raycastBox(min: SIMD3<Float>,
                        max: SIMD3<Float>,
                        origin: SIMD3<Float>,
                        direction: SIMD3<Float>,
                        maxDistance: Float) -> (distance: Float, position: SIMD3<Float>, normal: SIMD3<Float>)? {
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
    let hitDistance = Swift.max(entryDistance, 0)
    let position = origin + direction * hitDistance
    return (hitDistance, position, entryNormal)
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