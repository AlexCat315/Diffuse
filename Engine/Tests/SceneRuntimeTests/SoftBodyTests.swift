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
        _ = runtime.setComponent(SoftBody(allowSleep: false), for: entity)

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

    @Test("unsupported self collision returns an explicit native argument error")
    func selfCollisionIsRejected() {
        var runtime = makeRuntime()
        let entity = runtime.createEntity()
        _ = runtime.setComponent(Cloth(gridSizeX: 3, gridSizeZ: 3), for: entity)
        _ = runtime.setComponent(SoftBody(selfCollision: true), for: entity)

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

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        let restoredEntity = try #require(restored.entities().first)
        #expect(restored.component(SoftBody.self, for: restoredEntity) == softBody)
        #expect(restored.component(Cloth.self, for: restoredEntity) == cloth)
    }
}
