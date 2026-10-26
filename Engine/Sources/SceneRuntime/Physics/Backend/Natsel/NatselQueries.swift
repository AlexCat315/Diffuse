import SIMDCompat
internal import Natsel

extension NatselPhysicsBackend {
    public func raycast(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter) -> PhysicsRaycastHit? {
        raycastAll(query, filter: filter, maxHits: 1).first
    }

    public func raycastAll(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsRaycastHit] {
        let length = simd_length(query.direction)
        guard maxHits > 0, length.isFinite, length > 0, query.maxDistance > 0 else { return [] }
        ensureSoftQuerySurfaces()
        let distance = min(query.maxDistance, Float.greatestFiniteMagnitude / 4)
        let translation = query.direction * (distance / length)
        var hits: [PhysicsRaycastHit] = []
        _ = world.castRay(Natsel.Pos(nv(query.origin)), nv(translation)) { id, point, normal, fraction, _, _, _ in
            guard self.accepts(id, filter), let owner = self.shapeOwner(id) else { return 1 }
            hits.append(PhysicsRaycastHit(entity: owner.entity, subShapeID: owner.child, distance: fraction * distance,
                position: self.sv(point), normal: self.sv(normal), bounds: self.bounds(id),
                isTrigger: self.bodies[owner.entity]?.descriptor.collider?.isTrigger ?? false))
            return 1
        }
        hits.sort { $0.distance == $1.distance ? ($0.entity == $1.entity ? $0.subShapeID < $1.subShapeID : entityOrder($0.entity, $1.entity)) : $0.distance < $1.distance }
        return Array(hits.prefix(maxHits))
    }

    public func overlapAABB(_ query: PhysicsOverlapAABBQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit] {
        overlapShape(PhysicsOverlapShapeQuery(shape: .box(halfExtents: (query.bounds.max - query.bounds.min) * 0.5),
            position: (query.bounds.min + query.bounds.max) * 0.5, maxResults: query.maxResults), filter: filter)
    }

    public func overlapShape(_ query: PhysicsOverlapShapeQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit] {
        guard query.maxResults > 0 else { return [] }
        ensureSoftQuerySurfaces()
        return withQueryProxy(query.shape, rotation: query.rotation) { proxy in
            var hits: [PhysicsOverlapHit] = []
            _ = world.overlapShape(Natsel.Pos(nv(query.position)), proxy) { id in
                if self.accepts(id, filter), let owner = self.shapeOwner(id) {
                    hits.append(PhysicsOverlapHit(entity: owner.entity, subShapeID: owner.child, bounds: self.bounds(id),
                        isTrigger: self.bodies[owner.entity]?.descriptor.collider?.isTrigger ?? false))
                }
                return true
            }
            hits.sort { $0.entity == $1.entity ? $0.subShapeID < $1.subShapeID : entityOrder($0.entity, $1.entity) }
            return Array(hits.prefix(query.maxResults))
        }
    }

    public func sweepAABB(_ query: PhysicsSweepAABBQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit? {
        sweepShape(PhysicsSweepShapeQuery(shape: .box(halfExtents: (query.bounds.max - query.bounds.min) * 0.5),
            position: (query.bounds.min + query.bounds.max) * 0.5, translation: query.translation), filter: filter)
    }

    public func sweepShape(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit? {
        sweepShapeAll(query, filter: filter, maxHits: 1).first
    }

    public func sweepShapeAll(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsSweepHit] {
        guard maxHits > 0 else { return [] }
        ensureSoftQuerySurfaces()
        let distance = simd_length(query.translation)
        guard distance.isFinite else { return [] }
        if distance == 0 {
            return overlapShape(PhysicsOverlapShapeQuery(shape: query.shape, position: query.position,
                rotation: query.rotation, maxResults: maxHits), filter: filter).map {
                PhysicsSweepHit(entity: $0.entity, subShapeID: $0.subShapeID, fraction: 0, distance: 0,
                    position: query.position, normal: .zero, bounds: $0.bounds, isTrigger: $0.isTrigger)
            }
        }
        return withQueryProxy(query.shape, rotation: query.rotation) { proxy in
            var input = Natsel.ShapeCastInput()
            input.proxy = proxy
            input.translation = nv(query.translation)
            input.canEncroach = true
            var hits: [PhysicsSweepHit] = []
            _ = world.shapeCast(Natsel.Pos(nv(query.position)), input) { id, point, normal, fraction, _, _, _ in
                guard self.accepts(id, filter), let owner = self.shapeOwner(id) else { return 1 }
                // Native casts retain a solver separation. Project the moving proxy's support
                // point onto the returned contact plane to report geometric travel, as Guava's
                // query API requires. Its position is the query origin at impact.
                let n = self.sv(normal)
                let approach = simd_dot(n, query.translation)
                var geometricFraction = fraction
                if approach < -Float.ulpOfOne, proxy.count > 0, let points = proxy.points {
                    var support = Float.greatestFiniteMagnitude
                    for index in 0..<Int(proxy.count) { support = min(support, simd_dot(n, self.sv(points[index]))) }
                    let gap = simd_dot(n, query.position + query.translation * fraction - self.sv(point)) + support - proxy.radius
                    geometricFraction = max(0, fraction - gap / approach)
                    guard geometricFraction <= 1 + 4 * Float.ulpOfOne else { return 1 }
                    geometricFraction = min(1, geometricFraction)
                }
                hits.append(PhysicsSweepHit(entity: owner.entity, subShapeID: owner.child, fraction: geometricFraction,
                    distance: distance * geometricFraction, position: query.position + query.translation * geometricFraction,
                    normal: n, bounds: self.bounds(id),
                    isTrigger: self.bodies[owner.entity]?.descriptor.collider?.isTrigger ?? false))
                return 1
            }
            hits.sort { $0.fraction == $1.fraction ? ($0.entity == $1.entity ? $0.subShapeID < $1.subShapeID : entityOrder($0.entity, $1.entity)) : $0.fraction < $1.fraction }
            return Array(hits.prefix(maxHits))
        }
    }

    public func detectTriggerFrame(maxEventCount: Int) -> TriggerFrameResource {
        guard maxEventCount > 0 else { return TriggerFrameResource() }
        var current: Set<Pair> = []
        let triggerEntities = bodies.compactMap { $0.value.descriptor.collider?.isTrigger == true ? $0.key : nil }.sorted(by: entityOrder)
        for entity in triggerEntities {
            let trigger = bodies[entity]!
            guard let collider = trigger.descriptor.collider, collider.isTrigger else { continue }
            let box = world.bodyWorldAABB(trigger.id)
            let candidates = overlapAABB(PhysicsOverlapAABBQuery(bounds: SpatialAABB(min: sv(box.lowerBound), max: sv(box.upperBound))),
                filter: PhysicsQueryFilter(excludeEntity: entity, includeTriggers: true, layerID: collider.layerID, layerMask: collider.layerMask))
            for otherEntity in Set(candidates.map(\.entity)).sorted(by: entityOrder) {
                let otherID: Natsel.BodyID
                let otherShapes: [Natsel.ShapeID]
                if let other = bodies[otherEntity] { otherID = other.id; otherShapes = other.shapes }
                else if let other = characters[otherEntity] { otherID = other.character.innerBodyId; otherShapes = [] }
                else if let surface = softQuerySurfaces[otherEntity] { otherID = surface.body; otherShapes = [surface.shape] }
                else { continue }
                let pose = world.bodyTransform(trigger.id)
                let otherPose = world.bodyTransform(otherID)
                var overlap = false
                for shape in trigger.shapes {
                    overlap = withFixtureProxy(shape, pose: pose) { proxy in
                        world.bodyOverlapShape(otherID, pose.p, proxy, .defaultFilter, otherPose)
                    } ?? false
                    if overlap { break }
                }
                // Mesh fixtures cannot be query proxies; try the convex side in reverse.
                for shape in otherShapes where !overlap {
                    overlap = withFixtureProxy(shape, pose: otherPose) { proxy in
                        world.bodyOverlapShape(trigger.id, otherPose.p, proxy, .defaultFilter, pose)
                    } ?? false
                }
                if overlap { current.insert(Pair(a: entity, b: otherEntity)) }
            }
        }
        let enters = current.subtracting(triggerPairs).sorted().prefix(maxEventCount).map {
            TriggerEvent(triggerEntity: $0.a, otherEntity: $0.b, kind: .enter)
        }
        let exits = triggerPairs.subtracting(current).sorted().prefix(maxEventCount).map {
            TriggerEvent(triggerEntity: $0.a, otherEntity: $0.b, kind: .exit)
        }
        let active = current.sorted().prefix(maxEventCount).map { TriggerEvent(triggerEntity: $0.a, otherEntity: $0.b, kind: .active) }
        triggerPairs = current
        return TriggerFrameResource(enters: enters, exits: exits, active: active)
    }
}
