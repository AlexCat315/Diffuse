import SceneRuntime
import SIMDCompat
import Testing

@Suite("Empty authored collider")
struct EmptyMeshColliderTests {
    @Test("skipping an empty mesh preserves the authored child IDs of remaining compound shapes")
    func compoundChildIdentity() {
        var scene = SceneRuntime()
        scene.setPhysicsSettings(PhysicsSettingsResource(simulationMode: .play,backendKind: .natsel,gravity: .zero))
        let entity = scene.createEntity()
        scene.setResource(MeshColliderGeometryResource(geometryByResourceID: ["edit": .init(positions: [],triangleIndices: [])]))
        _ = scene.setComponent(Collider(shapes: [.init(shape: .mesh(resourceID: "edit",center: .zero)),
            .init(shape: .sphere(radius: 0.5,center: .zero),localPosition: SIMD3(2,0,0))]),for: entity)
        #expect(scene.tick(deltaTime: 0).physics.error == nil)
        let hit = scene.physicsRaycast(PhysicsRaycastQuery(origin: SIMD3<Float>(2,0,3),direction: SIMD3<Float>(0,0,-1),maxDistance: 6))
        #expect(hit?.entity == entity && hit?.subShapeID == 1)
    }

    @Test("mesh colliders can become empty and recover without stale shapes or backend errors",arguments: [
        ColliderShape.mesh(resourceID: "edit",center: .zero),.convex(resourceID: "edit",center: .zero),.heightField(resourceID: "edit",center: .zero)
    ])
    func emptyAndRestore(shape: ColliderShape) {
        var scene = SceneRuntime()
        scene.setPhysicsSettings(PhysicsSettingsResource(simulationMode: .play,backendKind: .natsel,gravity: .zero))
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: shape),for: entity)
        if case .convex = shape { _ = scene.setComponent(RigidBody(gravityScale: 0,allowSleep: false),for: entity) }
        let points: [SIMD3<Float>] = [SIMD3(-1,-1,-1),SIMD3(1,-1,-1),SIMD3(1,1,-1),SIMD3(-1,1,-1),
            SIMD3(-1,-1,1),SIMD3(1,-1,1),SIMD3(1,1,1),SIMD3(-1,1,1)]
        let faces = [[0,3,2,1],[4,5,6,7],[0,1,5,4],[3,7,6,2],[0,4,7,3],[1,2,6,5]]
        let geometry = MeshColliderGeometry(positions: points,triangleIndices: faces.flatMap { face in [0,1,2,0,2,3].map { UInt32(face[$0]) } })
        let ray = PhysicsRaycastQuery(origin: SIMD3<Float>(0,0,3),direction: SIMD3<Float>(0,0,-1),maxDistance: 6)
        for empty in [false,true,false] {
            scene.setResource(MeshColliderGeometryResource(geometryByResourceID: ["edit": empty ? .init(positions: [],triangleIndices: []) : geometry]))
            let report = scene.tick(deltaTime: 1.0/60.0)
            #expect(report.physics.error == nil)
            #expect(scene.contains(entity))
            #expect((scene.physicsRaycast(ray)?.entity == entity) == !empty)
        }
    }
}
