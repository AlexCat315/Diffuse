import SceneRuntime
import SIMDCompat
import Testing

@Suite("SoftBody")
struct SoftBodyTests {
    private func makeRuntime(gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0)) -> SceneRuntime {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .jolt,
            gravity: gravity,
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            allowSleep: false,
            capacity: PhysicsCapacitySettings(workerThreadCount: 1)
        ))
        return runtime
    }

    @Test("Jolt cloth streams deformed vertices while fixed vertices stay pinned")
    func clothSimulationAndVertexStreaming() throws {
        var runtime = makeRuntime()
        let clothEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, 5, 0)), for: clothEntity
        )
        _ = runtime.setComponent(
            Cloth(
                gridSizeX: 4,
                gridSizeZ: 4,
                spacing: 0.5,
                fixedVertexIndices: [0, 3],
                bendType: .distance
            ),
            for: clothEntity
        )
        _ = runtime.setComponent(
            SoftBody(linearDamping: 0.02, allowSleep: false), for: clothEntity
        )

        for frame in 0..<30 {
            let report = runtime.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            )
            #expect(report.physicsError == nil)
        }

        let state = try #require(runtime.softBodyStateFrame.states[clothEntity])
        #expect(state.positions.count == 16)
        #expect(state.triangleIndices.count == 54)
        #expect(runtime.softBodyStateFrame.vertexCount == 16)
        #expect(abs(state.positions[0].y - 5) < 0.01)
        #expect(abs(state.positions[3].y - 5) < 0.01)
        #expect(state.positions[10].y < 4.8)
    }

    @Test("cloth vertex stream reaches RenderScene and survives a frame without a physics step")
    func clothRenderExtractionAndNoStepPersistence() throws {
        var runtime = makeRuntime()
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(2, 5, -1)), for: entity
        )
        _ = runtime.setComponent(
            Cloth(
                gridSizeX: 4,
                gridSizeZ: 3,
                spacing: 0.4,
                fixedVertexIndices: Array(0..<12)
            ),
            for: entity
        )
        _ = runtime.setComponent(
            SoftBody(linearDamping: 0.02, allowSleep: false), for: entity
        )
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)

        #expect(runtime.tick(deltaTime: 1.0 / 60.0).physicsError == nil)
        let first = try #require(runtime.renderScene.deformableMeshes.first)
        let instance = try #require(
            runtime.renderScene.instances.first { $0.entity == entity }
        )
        #expect(first.entity == entity)
        #expect(first.vertexCount == 12)
        #expect(first.triangleCount == 12)
        #expect(first.textureCoordinates.first == SIMD2<Float>(0, 0))
        #expect(first.textureCoordinates.last == SIMD2<Float>(1, 1))
        #expect(first.normals.allSatisfy {
            abs(simd_length($0) - 1) < 0.001
        })
        #expect(instance.transform == matrix_identity_float4x4)

        let firstPositions = first.positions
        let firstRevision = first.revision
        #expect(runtime.tick(deltaTime: 0).physicsError == nil)
        let preserved = try #require(runtime.renderScene.deformableMeshes.first)
        #expect(preserved.positions == firstPositions)
        #expect(preserved.revision == firstRevision)
        #expect(runtime.softBodyStateFrame.states[entity]?.positions == firstPositions)

        #expect(runtime.tick(deltaTime: 1.0 / 60.0).physicsError == nil)
        let unchangedPinnedMesh = try #require(runtime.renderScene.deformableMeshes.first)
        #expect(unchangedPinnedMesh.positions == firstPositions)
        #expect(unchangedPinnedMesh.revision == firstRevision)
    }

    @Test("removing cloth topology removes its native soft body and streamed state")
    func incrementalRemoval() {
        var runtime = makeRuntime(gravity: .zero)
        let entity = runtime.createEntity()
        _ = runtime.setComponent(Cloth(gridSizeX: 3, gridSizeZ: 3), for: entity)
        _ = runtime.setComponent(
            SoftBody(vertexRadius: 0.03, allowSleep: false, selfCollision: true),
            for: entity
        )

        var report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError == nil)
        #expect(runtime.softBodyStateFrame.states[entity]?.positions.count == 9)

        _ = runtime.removeComponent(Cloth.self, from: entity)
        report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError == nil)
        #expect(runtime.softBodyStateFrame.states[entity] == nil)
        #expect(runtime.softBodyStateFrame.vertexCount == 0)
    }

    @Test("free cloth collides with static scene geometry")
    func clothCollidesWithStaticGround() throws {
        var runtime = makeRuntime()
        let ground = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, -0.25, 0)), for: ground
        )
        _ = runtime.setComponent(
            Collider(shape: .box(
                halfExtents: SIMD3<Float>(4, 0.25, 4), center: .zero
            )),
            for: ground
        )

        let clothEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, 2, 0)), for: clothEntity
        )
        _ = runtime.setComponent(
            Cloth(gridSizeX: 6, gridSizeZ: 6, spacing: 0.25), for: clothEntity
        )
        _ = runtime.setComponent(
            SoftBody(vertexRadius: 0.03, allowSleep: false), for: clothEntity
        )

        for frame in 0..<120 {
            #expect(runtime.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
        }
        let state = try #require(runtime.softBodyStateFrame.states[clothEntity])
        let minimumY = try #require(state.positions.map(\.y).min())
        let maximumY = try #require(state.positions.map(\.y).max())
        #expect(minimumY > -0.08)
        #expect(maximumY < 0.3)
    }

    @Test("pinned cloth collides with a dynamic rigid body")
    func clothCollidesWithDynamicBody() throws {
        var runtime = makeRuntime()
        let clothEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, 2, 0)), for: clothEntity
        )
        let size = 9
        let fixedBoundary = (0..<(size * size)).filter { index in
            let x = index % size
            let z = index / size
            return x == 0 || z == 0 || x == size - 1 || z == size - 1
        }
        _ = runtime.setComponent(
            Cloth(
                gridSizeX: size,
                gridSizeZ: size,
                spacing: 0.25,
                fixedVertexIndices: fixedBoundary,
                compliance: 0,
                shearCompliance: 0,
                bendCompliance: 0,
                bendType: .dihedral
            ),
            for: clothEntity
        )
        _ = runtime.setComponent(
            SoftBody(vertexMass: 0.25, vertexRadius: 0.025, allowSleep: false),
            for: clothEntity
        )

        let sphere = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, 3.25, 0)), for: sphere
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.25, center: .zero)), for: sphere
        )
        _ = runtime.setComponent(
            RigidBody(motionType: .dynamic, mass: 0.5, allowSleep: false), for: sphere
        )

        for frame in 0..<120 {
            #expect(runtime.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
        }
        let sphereY = try #require(runtime.worldTransform(for: sphere)?.translation.y)
        let clothState = try #require(runtime.softBodyStateFrame.states[clothEntity])
        #expect(sphereY > 1.0)
        #expect(clothState.positions.count == size * size)
    }

    @Test("native character can use pinned cloth as support")
    func clothSupportsCharacter() {
        var runtime = makeRuntime()
        let clothEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, 2, 0)), for: clothEntity
        )
        _ = runtime.setComponent(
            Cloth(
                gridSizeX: 9,
                gridSizeZ: 9,
                spacing: 0.3,
                fixedVertexIndices: Array(0..<81),
                compliance: 0,
                shearCompliance: 0,
                bendCompliance: 0
            ),
            for: clothEntity
        )
        _ = runtime.setComponent(
            SoftBody(vertexRadius: 0.03, allowSleep: false), for: clothEntity
        )

        let character = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, 4, 0)), for: character
        )
        _ = runtime.setComponent(CharacterController(), for: character)

        for frame in 0..<120 {
            runtime.submitCharacterCommand(CharacterCommand(), for: character)
            #expect(runtime.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
        }
        let state = runtime.characterStateFrame.states[character]
        #expect(state?.isGrounded == true)
        #expect(abs((state?.position.y ?? 0) - 2) < 0.15)
    }

    @Test("independent cloth simulations produce identical checkpoint hashes")
    func deterministicStateHashes() {
        func makeClothRuntime() -> SceneRuntime {
            var runtime = makeRuntime()
            let entity = runtime.createEntity()
            _ = runtime.setLocalTransform(
                LocalTransform(translation: SIMD3<Float>(0, 4, 0)), for: entity
            )
            _ = runtime.setComponent(
                Cloth.fixedTopEdge(gridSizeX: 8, gridSizeZ: 8, spacing: 0.2),
                for: entity
            )
            _ = runtime.setComponent(
                SoftBody(linearDamping: 0.05, allowSleep: false), for: entity
            )
            return runtime
        }

        var first = makeClothRuntime()
        var second = makeClothRuntime()
        for frame in 0..<90 {
            #expect(first.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
            #expect(second.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
            #expect(first.physicsStateHashFrame == second.physicsStateHashFrame)
        }
        #expect(first.physicsStateHashFrame.hash != 0)
    }

    @Test("self collision separates disconnected folded surfaces deterministically")
    func selfCollisionSeparatesFoldedSurfaces() throws {
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(-0.5, 0, -0.5),
            SIMD3<Float>(0.5, 0, -0.5),
            SIMD3<Float>(0, 0, 0.5),
            SIMD3<Float>(-0.5, 0.01, -0.5),
            SIMD3<Float>(0.5, 0.01, -0.5),
            SIMD3<Float>(0, 0.01, 0.5),
        ]
        let triangles: [UInt32] = [0, 2, 1, 3, 5, 4]

        func configuredRuntime() -> (SceneRuntime, EntityID) {
            var runtime = makeRuntime(gravity: .zero)
            runtime.setResource(MeshColliderGeometryResource(geometryByResourceID: [
                "self-collision.fold": MeshColliderGeometry(
                    positions: positions,
                    triangleIndices: triangles,
                    revision: 1
                ),
            ]))
            let entity = runtime.createEntity()
            _ = runtime.setComponent(
                SoftBodyMesh(
                    resourceID: "self-collision.fold",
                    compliance: 0,
                    shearCompliance: 0,
                    bendCompliance: 0,
                    bendType: .none
                ),
                for: entity
            )
            _ = runtime.setComponent(
                SoftBody(
                    linearDamping: 0,
                    gravityScale: 0,
                    vertexRadius: 0.05,
                    solverIterations: 4,
                    maxLinearVelocity: 20,
                    allowSleep: false,
                    selfCollision: true
                ),
                for: entity
            )
            return (runtime, entity)
        }

        var (first, firstEntity) = configuredRuntime()
        var (second, secondEntity) = configuredRuntime()
        for frame in 0..<12 {
            #expect(first.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
            #expect(second.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
        }

        let firstState = try #require(first.softBodyStateFrame.states[firstEntity])
        let secondState = try #require(second.softBodyStateFrame.states[secondEntity])
        #expect(firstState.positions == secondState.positions)
        let lowerY = firstState.positions[0..<3].reduce(Float.zero) { $0 + $1.y } / 3
        let upperY = firstState.positions[3..<6].reduce(Float.zero) { $0 + $1.y } / 3
        #expect(abs(upperY - lowerY) >= 0.045)
    }

    @Test("self collision with zero vertex radius returns an explicit native error")
    func selfCollisionRejectsZeroRadius() {
        var runtime = makeRuntime(gravity: .zero)
        let entity = runtime.createEntity()
        _ = runtime.setComponent(Cloth(gridSizeX: 3, gridSizeZ: 3), for: entity)
        _ = runtime.setComponent(
            SoftBody(vertexRadius: 0, selfCollision: true), for: entity
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError?.code == .invalidArgument)
        #expect(runtime.softBodyStateFrame.states[entity] == nil)
    }

    @Test("arbitrary triangle surface simulates, scales, and streams through RenderScene")
    func arbitraryTriangleSurface() throws {
        var runtime = makeRuntime()
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(-0.75, 0, -0.5),
            SIMD3<Float>(0.75, 0, -0.5),
            SIMD3<Float>(0, 0, 0.75),
            SIMD3<Float>(0, 1, 0),
        ]
        let indices: [UInt32] = [
            0, 2, 1,
            0, 1, 3,
            1, 2, 3,
            2, 0, 3,
        ]
        let textureCoordinates: [SIMD2<Float>] = [
            SIMD2<Float>(0, 0), SIMD2<Float>(1, 0),
            SIMD2<Float>(0.5, 1), SIMD2<Float>(0.5, 0.5),
        ]
        runtime.setResource(MeshColliderGeometryResource(geometryByResourceID: [
            "soft.tetra": MeshColliderGeometry(
                positions: positions,
                triangleIndices: indices,
                textureCoordinates: textureCoordinates,
                revision: 7
            ),
        ]))

        let entity = runtime.createEntity()
        var transform = simd_float4x4(diagonal: SIMD4<Float>(1.5, 2, 0.75, 1))
        transform.columns.3 = SIMD4<Float>(0, 4, 0, 1)
        _ = runtime.setLocalTransform(LocalTransform(matrix: transform), for: entity)
        _ = runtime.setComponent(
            SoftBodyMesh(
                resourceID: "soft.tetra",
                fixedVertexIndices: [3],
                bendType: .distance
            ),
            for: entity
        )
        _ = runtime.setComponent(
            SoftBody(linearDamping: 0.02, allowSleep: false), for: entity
        )
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)

        for frame in 0..<30 {
            #expect(runtime.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
        }

        let state = try #require(runtime.softBodyStateFrame.states[entity])
        #expect(state.positions.count == 4)
        #expect(state.triangleIndices == indices)
        #expect(abs(state.positions[3].y - 6) < 0.02)
        #expect(state.positions[0].y < 3.999)
        let rendered = try #require(runtime.renderScene.deformableMeshes.first)
        #expect(rendered.entity == entity)
        #expect(rendered.textureCoordinates == textureCoordinates)
        #expect(rendered.triangleIndices == indices)
    }

    @Test("tetrahedral volume constraints preserve volume and stream the surface")
    func tetrahedralVolume() throws {
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(-1, 0, -1),
            SIMD3<Float>(1, 0, -1),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 1, 0),
        ]
        let triangles: [UInt32] = [
            0, 2, 1,
            0, 1, 3,
            1, 2, 3,
            2, 0, 3,
        ]

        func signedSixVolume(_ vertices: [SIMD3<Float>]) -> Float {
            let a = vertices[0] - vertices[3]
            let b = vertices[1] - vertices[3]
            let c = vertices[2] - vertices[3]
            let bCrossC = SIMD3<Float>(
                b.y * c.z - b.z * c.y,
                b.z * c.x - b.x * c.z,
                b.x * c.y - b.y * c.x
            )
            return a.x * bCrossC.x + a.y * bCrossC.y + a.z * bCrossC.z
        }

        func simulate(tetrahedronIndices: [UInt32]) throws -> SoftBodyMeshState {
            var runtime = makeRuntime()
            runtime.setResource(MeshColliderGeometryResource(geometryByResourceID: [
                "deformable.tetra": MeshColliderGeometry(
                    positions: positions,
                    triangleIndices: triangles,
                    tetrahedronIndices: tetrahedronIndices,
                    revision: 11
                ),
            ]))
            let entity = runtime.createEntity()
            _ = runtime.setLocalTransform(
                LocalTransform(translation: SIMD3<Float>(0, 4, 0)), for: entity
            )
            _ = runtime.setComponent(
                SoftBodyMesh(
                    resourceID: "deformable.tetra",
                    fixedVertexIndices: [0, 1, 2],
                    compliance: 0.05,
                    shearCompliance: 0.05,
                    bendCompliance: 0.05,
                    volumeCompliance: 0,
                    bendType: .none
                ),
                for: entity
            )
            _ = runtime.setComponent(
                SoftBody(
                    linearDamping: 0,
                    solverIterations: 12,
                    allowSleep: false
                ),
                for: entity
            )
            _ = runtime.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)
            for frame in 0..<60 {
                #expect(runtime.tick(
                    deltaTime: 1.0 / 60.0,
                    frameIndex: UInt64(frame)
                ).physicsError == nil)
            }
            let state = try #require(runtime.softBodyStateFrame.states[entity])
            #expect(runtime.renderScene.deformableMeshes.first?.triangleIndices == triangles)
            return state
        }

        let volumeState = try simulate(tetrahedronIndices: [0, 1, 2, 3])
        let surfaceState = try simulate(tetrahedronIndices: [])
        let restSixVolume = abs(signedSixVolume(positions))
        let constrainedSixVolume = abs(signedSixVolume(volumeState.positions))
        let surfaceSixVolume = abs(signedSixVolume(surfaceState.positions))
        let constrainedError = abs(constrainedSixVolume - restSixVolume)
        let surfaceError = abs(surfaceSixVolume - restSixVolume)
        #expect(
            constrainedError < restSixVolume * 0.05,
            "rest 6V=\(restSixVolume), constrained 6V=\(constrainedSixVolume)"
        )
        #expect(
            surfaceError > constrainedError + restSixVolume * 0.25,
            "surface 6V=\(surfaceSixVolume), constrained 6V=\(constrainedSixVolume)"
        )
        #expect(try simulate(tetrahedronIndices: [0, 1, 2, 3]) == volumeState)
    }

    @Test("tetrahedral assets connect an interior vertex to the rendered surface")
    func tetrahedralInteriorEdges() throws {
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(-1, 0, -1),
            SIMD3<Float>(1, 0, -1),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0.25, -0.25),
        ]
        let triangles: [UInt32] = [
            0, 2, 1,
            0, 1, 3,
            1, 2, 3,
            2, 0, 3,
        ]
        let tetrahedra: [UInt32] = [
            0, 1, 2, 4,
            0, 3, 1, 4,
            1, 3, 2, 4,
            2, 3, 0, 4,
        ]
        var runtime = makeRuntime()
        runtime.setResource(MeshColliderGeometryResource(geometryByResourceID: [
            "deformable.interior": MeshColliderGeometry(
                positions: positions,
                triangleIndices: triangles,
                tetrahedronIndices: tetrahedra
            ),
        ]))
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, 4, 0)), for: entity
        )
        _ = runtime.setComponent(
            SoftBodyMesh(
                resourceID: "deformable.interior",
                fixedVertexIndices: [0, 1, 2, 3],
                compliance: 0,
                shearCompliance: 0,
                bendCompliance: 0,
                volumeCompliance: 0
            ),
            for: entity
        )
        _ = runtime.setComponent(
            SoftBody(solverIterations: 12, allowSleep: false), for: entity
        )

        for frame in 0..<60 {
            #expect(runtime.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
        }
        let state = try #require(runtime.softBodyStateFrame.states[entity])
        #expect(state.positions.count == 5)
        #expect(state.triangleIndices == triangles)
        #expect(abs(state.positions[4].y - 4.25) < 0.05)
    }

    @Test("missing arbitrary soft-body geometry returns an explicit native error")
    func missingArbitrarySurfaceGeometry() {
        var runtime = makeRuntime()
        let entity = runtime.createEntity()
        _ = runtime.setComponent(SoftBody(), for: entity)
        _ = runtime.setComponent(
            SoftBodyMesh(resourceID: "missing.soft.asset"), for: entity
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError?.code == .invalidArgument)
        #expect(runtime.softBodyStateFrame.states[entity] == nil)
    }

    @Test("malformed arbitrary surface topology returns an explicit native error")
    func malformedArbitrarySurfaceTopology() {
        let malformedGeometries = [
            MeshColliderGeometry(
                positions: [.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
                triangleIndices: [0, 1, 3]
            ),
            MeshColliderGeometry(
                positions: [.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
                triangleIndices: [0, 1, 1]
            ),
            MeshColliderGeometry(
                positions: [.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(2, 0, 0)],
                triangleIndices: [0, 1, 2]
            ),
            MeshColliderGeometry(
                positions: [.zero, SIMD3<Float>(1, 0, 0), SIMD3<Float>(.nan, 1, 0)],
                triangleIndices: [0, 1, 2]
            ),
        ]

        for (index, geometry) in malformedGeometries.enumerated() {
            var runtime = makeRuntime()
            let resourceID = "malformed.\(index)"
            runtime.setResource(MeshColliderGeometryResource(geometryByResourceID: [
                resourceID: geometry,
            ]))
            let entity = runtime.createEntity()
            _ = runtime.setComponent(SoftBody(), for: entity)
            _ = runtime.setComponent(SoftBodyMesh(resourceID: resourceID), for: entity)

            let report = runtime.tick(deltaTime: 1.0 / 60.0)
            #expect(report.physicsError?.code == .invalidArgument)
            #expect(runtime.softBodyStateFrame.states[entity] == nil)
        }
    }

    @Test("malformed tetrahedra return an explicit native error")
    func malformedTetrahedralTopology() {
        let positions: [SIMD3<Float>] = [
            .zero,
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
        ]
        let triangles: [UInt32] = [0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3]
        let malformedTetrahedra: [[UInt32]] = [
            [0, 1, 2],
            [0, 1, 2, 4],
            [0, 1, 2, 2],
        ]

        for (index, tetrahedra) in malformedTetrahedra.enumerated() {
            var runtime = makeRuntime()
            let resourceID = "malformed.tetra.\(index)"
            runtime.setResource(MeshColliderGeometryResource(geometryByResourceID: [
                resourceID: MeshColliderGeometry(
                    positions: positions,
                    triangleIndices: triangles,
                    tetrahedronIndices: tetrahedra
                ),
            ]))
            let entity = runtime.createEntity()
            _ = runtime.setComponent(SoftBody(), for: entity)
            _ = runtime.setComponent(SoftBodyMesh(resourceID: resourceID), for: entity)

            let report = runtime.tick(deltaTime: 1.0 / 60.0)
            #expect(report.physicsError?.code == .invalidArgument)
            #expect(runtime.softBodyStateFrame.states[entity] == nil)
        }

        var zeroVolumeRuntime = makeRuntime()
        zeroVolumeRuntime.setResource(MeshColliderGeometryResource(geometryByResourceID: [
            "zero.volume": MeshColliderGeometry(
                positions: [
                    .zero,
                    SIMD3<Float>(1, 0, 0),
                    SIMD3<Float>(0, 1, 0),
                    SIMD3<Float>(1, 1, 0),
                ],
                triangleIndices: [0, 1, 2, 1, 3, 2],
                tetrahedronIndices: [0, 1, 2, 3]
            ),
        ]))
        let entity = zeroVolumeRuntime.createEntity()
        _ = zeroVolumeRuntime.setComponent(SoftBody(), for: entity)
        _ = zeroVolumeRuntime.setComponent(
            SoftBodyMesh(resourceID: "zero.volume"), for: entity
        )
        #expect(zeroVolumeRuntime.tick(
            deltaTime: 1.0 / 60.0
        ).physicsError?.code == .invalidArgument)
    }

    @Test("cloth and surface topology conflict returns an explicit native error")
    func conflictingTopology() {
        var runtime = makeRuntime()
        let entity = runtime.createEntity()
        _ = runtime.setComponent(SoftBody(), for: entity)
        _ = runtime.setComponent(Cloth(gridSizeX: 3, gridSizeZ: 3), for: entity)
        _ = runtime.setComponent(SoftBodyMesh(resourceID: "soft.asset"), for: entity)

        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError?.code == .invalidArgument)
        #expect(runtime.softBodyStateFrame.states[entity] == nil)
    }

    @Test("soft-body and cloth configuration survives Scene v2 round-trip")
    func sceneRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        let softBody = SoftBody(
            vertexMass: 0.75,
            pressure: 2,
            linearDamping: 0.3,
            friction: 0.6,
            restitution: 0.1,
            gravityScale: 0.8,
            vertexRadius: 0.04,
            solverIterations: 9,
            maxLinearVelocity: 80,
            layerID: 3,
            layerMask: 0x00FF,
            allowSleep: false,
            facesDoubleSided: false,
            selfCollision: true,
            isEnabled: true
        )
        let cloth = Cloth(
            gridSizeX: 5,
            gridSizeZ: 7,
            spacing: 0.15,
            fixedVertexIndices: [0, 2, 4],
            compliance: 0.002,
            shearCompliance: 0.003,
            bendCompliance: 0.004,
            bendType: .dihedral
        )
        _ = original.setComponent(softBody, for: entity)
        _ = original.setComponent(cloth, for: entity)
        let meshEntity = original.createEntity()
        let softBodyMesh = SoftBodyMesh(
            resourceID: "asset:deformable.tetra",
            fixedVertexIndices: [1, 4, 7],
            compliance: 0.005,
            shearCompliance: 0.006,
            bendCompliance: 0.007,
            volumeCompliance: 0.008,
            bendType: .distance
        )
        _ = original.setComponent(softBody, for: meshEntity)
        _ = original.setComponent(softBodyMesh, for: meshEntity)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        let restoredEntities = restored.entities().sorted { $0.rawValue < $1.rawValue }
        let restoredEntity = try #require(restoredEntities.first)
        #expect(restored.component(SoftBody.self, for: restoredEntity) == softBody)
        #expect(restored.component(Cloth.self, for: restoredEntity) == cloth)
        let restoredMeshEntity = try #require(restoredEntities.last)
        #expect(restored.component(SoftBody.self, for: restoredMeshEntity) == softBody)
        #expect(restored.component(SoftBodyMesh.self, for: restoredMeshEntity) == softBodyMesh)
    }
}
