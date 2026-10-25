#if canImport(Natsel)
import SIMDCompat
internal import Natsel

extension NatselPhysicsBackend {
    /// Physical categories use bits 0...15. Characters query deformable surfaces through a
    /// second copy of those layers in bits 16...31, preserving bilateral layer filtering
    /// without admitting these derived surfaces to the physical solver.
    static let softQueryLayerShift = 16
    struct SoftQuerySurface { var body: Natsel.BodyID; var shape: Natsel.ShapeID }

    func ensureSoftQuerySurfaces() {
        guard softQuerySurfacesDirty else { return }
        for surface in softQuerySurfaces.values {
            owners.removeValue(forKey: surface.shape)
            world.destroyBody(surface.body)
        }
        softQuerySurfaces.removeAll(keepingCapacity: true)
        for entity in softBodies.keys.sorted(by: entityOrder) {
            let record = softBodies[entity]!
            let indices = record.descriptor.topology.triangleIndices.map { Int32(clamping: $0) }
            _ = world.withSoftBodyLocalVertexPositions(record.id) { origin, vertices in
                guard let mesh = Natsel.TriangleMesh(vertices: Array(vertices), indices: indices) else { return }
                var bodyDef = Natsel.BodyDef()
                bodyDef.position = origin
                let body = world.createBody(bodyDef)
                var shapeDef = Natsel.ShapeDef()
                let config = record.descriptor.softBody
                shapeDef.filter = Natsel.Filter(categoryBits: UInt64(1) << min(config.layerID, 15),
                    maskBits: UInt64(config.layerMask) << Self.softQueryLayerShift)
                shapeDef.materials = [.defaultMaterial]
                let shape = world.createMeshShape(body, shapeDef, mesh)
                guard !shape.isNull else { world.destroyBody(body); return }
                owners[shape] = ShapeOwner(entity: entity, child: 0)
                softQuerySurfaces[entity] = SoftQuerySurface(body: body, shape: shape)
            }
        }
        softQuerySurfacesDirty = false
    }
}
#endif
