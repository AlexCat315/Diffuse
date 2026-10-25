#if canImport(Natsel)
import SIMDCompat
internal import Natsel

extension NatselPhysicsBackend {
    func createShapes(_ descriptor: PhysicsBodyDescriptor, body: Natsel.BodyID) throws -> [Natsel.ShapeID] {
        guard let collider = descriptor.collider else { return [] }
        guard !collider.shapes.isEmpty else { throw failure(.invalidShape, "A collider needs at least one shape") }
        let bodyScale = scale(descriptor.worldTransform.matrix)
        var result: [Natsel.ShapeID] = []
        for instance in collider.shapes {
            let q = simd_quatf(vector: simd_normalize(instance.localRotation))
            func point(_ value: SIMD3<Float>) -> Natsel.Vec3 {
                nv(bodyScale * (instance.localPosition + q.act(instance.localScale * (value + instance.shape.center))))
            }
            var def = Natsel.ShapeDef()
            def.density = collider.material.density
            def.baseMaterial.friction = collider.material.friction
            def.baseMaterial.restitution = collider.material.restitution
            def.filter = shapeFilter(collider)
            def.isSensor = collider.isTrigger
            def.enableSensorEvents = true
            def.enableContactEvents = true
            def.enableHitEvents = true
            let id: Natsel.ShapeID
            switch instance.shape {
            case .box(let half, _):
                let vertices = [-1, 1].flatMap { x in [-1, 1].flatMap { y in [-1, 1].map { z in
                    point(half * SIMD3(Float(x), Float(y), Float(z)))
                } } }
                guard let hull = Natsel.createHull(vertices, maxVertexCount: 128) else { throw failure(.invalidShape, "Invalid box collider") }
                id = world.createHullShape(body, def, hull)
            case .sphere(let radius, _):
                let s = simd_abs(bodyScale * instance.localScale)
                id = world.createSphereShape(body, def, Natsel.Sphere(center: point(.zero), radius: max(0.0001, radius * max(s.x, max(s.y, s.z)))))
            case .capsule(let radius, let halfHeight, _):
                let s = simd_abs(bodyScale * instance.localScale)
                id = world.createCapsuleShape(body, def, Natsel.Capsule(center1: point(SIMD3(0, -halfHeight, 0)),
                    center2: point(SIMD3(0, halfHeight, 0)), radius: max(0.0001, radius * max(s.x, s.z))))
            case .cylinder(let radius, let halfHeight, _):
                var vertices: [Natsel.Vec3] = []
                for i in 0..<32 {
                    let angle = Float(i) * 2 * .pi / 32
                    let cs = Natsel.computeCosSin(angle)
                    for y in [-halfHeight, halfHeight] { vertices.append(point(SIMD3(radius * cs.cosine, y, radius * cs.sine))) }
                }
                guard let hull = Natsel.createHull(vertices, maxVertexCount: 128) else { throw failure(.invalidShape, "Invalid cylinder collider") }
                id = world.createHullShape(body, def, hull)
            case .convex:
                guard let geometry = descriptor.meshGeometry,
                    let hull = Natsel.createHull(geometry.positions.map(point), maxVertexCount: 128) else {
                    throw failure(.invalidShape, "Convex collider requires valid geometry")
                }
                id = world.createHullShape(body, def, hull)
            case .mesh, .heightField:
                guard let geometry = descriptor.meshGeometry,
                    let mesh = Natsel.TriangleMesh(vertices: geometry.positions.map(point),
                        indices: geometry.triangleIndices.map { Int32(clamping: $0) }) else {
                    throw failure(.invalidShape, "Triangle collider requires valid geometry")
                }
                def.materials = [def.baseMaterial]
                id = world.createMeshShape(body, def, mesh)
            }
            guard !id.isNull else { throw failure(.invalidShape, "Could not create Natsel collider") }
            result.append(id)
        }
        return result
    }

    func shapeFilter(_ collider: Collider) -> Natsel.Filter {
        Natsel.Filter(categoryBits: UInt64(1) << min(collider.layerID, 15), maskBits: UInt64(collider.layerMask))
    }

    func bounds(_ id: Natsel.ShapeID) -> SpatialAABB {
        let box = world.shapeWorldAABB(id)
        return SpatialAABB(min: sv(box.lowerBound), max: sv(box.upperBound))
    }

    func accepts(_ shape: Natsel.ShapeID, _ filter: PhysicsQueryFilter) -> Bool {
        guard let owner = shapeOwner(shape), !filter.excludedEntities.contains(owner.entity) else { return false }
        let layerID: UInt16
        let layerMask: UInt16
        if let collider = bodies[owner.entity]?.descriptor.collider {
            guard filter.includeTriggers || !collider.isTrigger else { return false }
            layerID = collider.layerID; layerMask = collider.layerMask
        } else if let controller = characters[owner.entity]?.descriptor.controller {
            layerID = controller.layerID; layerMask = controller.layerMask
        } else if let soft = softBodies[owner.entity]?.descriptor.softBody {
            layerID = soft.layerID; layerMask = soft.layerMask
        } else { return false }
        guard (filter.layerMask & (UInt16(1) << min(layerID, 15))) != 0 else { return false }
        if let layer = filter.layerID { return (layerMask & (UInt16(1) << min(layer, 15))) != 0 }
        return true
    }

    func shapeOwner(_ shape: Natsel.ShapeID) -> ShapeOwner? {
        if let owner = owners[shape] { return owner }
        let body = world.shapeBody(shape)
        return characters.first { $0.value.character.innerBodyId == body }.map { ShapeOwner(entity: $0.key, child: 0) }
    }

    /// Executes inside the vertex buffer's lifetime. Points are relative to the supplied origin.
    func withQueryProxy<R>(_ shape: PhysicsQueryShape, rotation: SIMD4<Float>, _ body: (Natsel.ShapeProxy) -> R) -> R {
        let q = nq(rotation)
        var points: [Natsel.Vec3]
        var radius: Float = 0
        switch shape {
        case .sphere(let r): points = [.zero]; radius = max(0, r)
        case .capsule(let r, let h): points = [Natsel.Vec3(0, -h, 0), Natsel.Vec3(0, h, 0)]; radius = max(0, r)
        case .box(let half):
            points = [-1, 1].flatMap { x in [-1, 1].flatMap { y in [-1, 1].map { z in
                nv(half * SIMD3(Float(x), Float(y), Float(z)))
            } } }
        }
        for i in points.indices { points[i] = Natsel.rotateVector(q, points[i]) }
        return points.withUnsafeBufferPointer { vertices in
            body(Natsel.ShapeProxy(points: vertices.baseAddress, count: Int32(vertices.count), radius: radius))
        }
    }

    func withFixtureProxy<R>(_ shape: Natsel.ShapeID, pose: Natsel.WorldTransform,
                             _ body: (Natsel.ShapeProxy) -> R) -> R? {
        var points: [Natsel.Vec3] = []
        var radius: Float = 0
        if let sphere = world.shapeSphere(shape) { points = [sphere.center]; radius = sphere.radius }
        else if let capsule = world.shapeCapsule(shape) { points = [capsule.center1, capsule.center2]; radius = capsule.radius }
        else if let hull = world.shapeHull(shape) {
            points = hull.vertexPositions()
        } else { return nil }
        for i in points.indices { points[i] = Natsel.rotateVector(pose.q, points[i]) }
        return points.withUnsafeBufferPointer { vertices in
            body(Natsel.ShapeProxy(points: vertices.baseAddress, count: Int32(vertices.count), radius: radius))
        }
    }
}

#endif
