import AssetPipeline
import SceneRuntime
import SIMDCompat
import Testing

@Suite("DestructibleAssetBaker")
struct DestructibleAssetBakerTests {
    private func tetrahedron(
        fragmentID: UInt32,
        density: Float = 6
    ) -> PrefracturedFragmentInput {
        PrefracturedFragmentInput(
            fragmentID: fragmentID,
            positions: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(0, 0, 1),
            ],
            triangleIndices: [0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3],
            localTransform: LocalTransform(translation: SIMD3<Float>(Float(fragmentID), 0, 0)),
            density: density,
            geometryRevision: UInt64(fragmentID + 10)
        )
    }

    @Test("bakes stable convex IDs, volume masses, and a sorted connection graph")
    func bakeAndInstall() throws {
        let result = try DestructibleAssetBaker().bake(
            assetResourceID: "tower.fracture",
            revision: 4,
            fragments: [tetrahedron(fragmentID: 2), tetrahedron(fragmentID: 0)],
            connections: [
                DestructibleConnectionAsset(
                    connectionID: 9,
                    fragmentA: 0,
                    fragmentB: 2,
                    damageThreshold: 30
                ),
            ]
        )
        #expect(result.asset.revision == 4)
        #expect(result.asset.fragments.map(\.fragmentID) == [0, 2])
        #expect(result.asset.connections.map(\.connectionID) == [9])
        #expect(result.asset.fragments.map(\.colliderResourceID) == [
            "tower.fracture#convex:0",
            "tower.fracture#convex:2",
        ])
        #expect(result.asset.fragments.allSatisfy { abs($0.mass - 1) < 0.0001 })
        #expect(result.geometryByResourceID["tower.fracture#convex:0"]?.revision == 10)

        var runtime = SceneRuntime()
        result.install(into: &runtime)
        #expect(runtime.resource(DestructibleAssetResource.self)?
            .asset(for: "tower.fracture") == result.asset)
        #expect(runtime.resource(MeshColliderGeometryResource.self)?
            .geometry(for: "tower.fracture#convex:2")?.positions.count == 4)
    }

    @Test("rejects duplicate IDs, invalid graph endpoints, and zero-volume geometry")
    func validation() {
        let baker = DestructibleAssetBaker()
        #expect(throws: DestructibleAssetBakeError.duplicateFragmentID(0)) {
            try baker.bake(
                assetResourceID: "duplicate",
                fragments: [tetrahedron(fragmentID: 0), tetrahedron(fragmentID: 0)]
            )
        }
        #expect(throws: DestructibleAssetBakeError.invalidConnection(connectionID: 3)) {
            try baker.bake(
                assetResourceID: "bad.graph",
                fragments: [tetrahedron(fragmentID: 0)],
                connections: [
                    DestructibleConnectionAsset(connectionID: 3, fragmentA: 0, fragmentB: 8),
                ]
            )
        }
        let flat = PrefracturedFragmentInput(
            fragmentID: 5,
            positions: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(1, 1, 0),
            ],
            triangleIndices: [0, 1, 2, 1, 3, 2]
        )
        #expect(throws: DestructibleAssetBakeError.nonClosedGeometry(fragmentID: 5)) {
            try baker.bake(assetResourceID: "flat", fragments: [flat])
        }
        var openTetrahedron = tetrahedron(fragmentID: 6)
        openTetrahedron.triangleIndices = [0, 2, 1, 0, 1, 3, 1, 2, 3]
        #expect(throws: DestructibleAssetBakeError.nonClosedGeometry(fragmentID: 6)) {
            try baker.bake(assetResourceID: "open", fragments: [openTetrahedron])
        }
    }
}
