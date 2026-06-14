import SceneRuntime
import Testing
import SIMDCompat

@Suite("RenderExtraction")
struct RenderExtractionTests {
    @Test("renderExtract collects visible mesh instances and the active camera")
    func renderExtractCollectsVisibleMeshesAndActiveCamera() {
        var runtime = SceneRuntime()

        let camera = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 3, 8)), for: camera)
        _ = runtime.setComponent(
            CameraComponent(target: SIMD3<Float>(0, 1, 0), isActive: true),
            for: camera
        )

        let parent = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(1, 0, 0)), for: parent)
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 1, assetID: "hero.mesh"), for: parent)
        _ = runtime.setComponent(
            RenderMaterialComponent(baseColorFactor: SIMD4<Float>(0.8, 0.6, 0.4, 0.9),
                                    baseColorTextureIndex: 3,
                                    normalTextureIndex: 4,
                                    metallicFactor: 0.7,
                                    roughnessFactor: 0.25,
                                    emissiveFactor: SIMD3<Float>(0.1, 0.2, 0.3)),
            for: parent
        )

        let child = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 2, 0)), for: child)
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 0), for: child)
        _ = runtime.setComponent(
            AssetReferenceComponent(assetID: "child.asset",
                                    name: "Child Mesh",
                                    relativePath: "Meshes/child.glb",
                                    absolutePath: "/tmp/Meshes/child.glb",
                                    kind: "glb",
                                    meshIndex: 0),
            for: child
        )
        _ = runtime.setParent(parent, for: child)

        let hidden = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 4, 4)), for: hidden)
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 2, isVisible: false), for: hidden)

        let keyLight = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(2, 5, 1)), for: keyLight)
        _ = runtime.setComponent(
            LightComponent(type: .spot,
                           color: SIMD3<Float>(1, 0.8, 0.6),
                           intensity: 2.5,
                           range: 18,
                           spotInnerAngleDegrees: 12,
                           spotOuterAngleDegrees: 45),
            for: keyLight
        )

        _ = runtime.tick()

        guard let extracted = runtime.extractedRenderScene else {
            Issue.record("expected extracted render scene resource")
            return
        }

        #expect(extracted.activeCameraEntity == camera)
        #expect(extracted.scene.camera.eye == SIMD3<Float>(0, 3, 8))
        #expect(extracted.scene.camera.target == SIMD3<Float>(0, 1, 0))
        #expect(extracted.instanceEntities == [parent, child])
        #expect(extracted.scene.instances[0].entity == parent)
        #expect(extracted.scene.instances[0].mesh.assetID == "hero.mesh")
        #expect(extracted.scene.instances[1].mesh.assetID == "child.asset")
        #expect(extracted.scene.instances[0].material.baseColorFactor == SIMD4<Float>(0.8, 0.6, 0.4, 0.9))
        #expect(extracted.scene.instances[0].material.baseColorTextureIndex == 3)
        #expect(extracted.scene.instances[0].material.normalTextureIndex == 4)
        #expect(isClose(extracted.scene.instances[0].material.metallicFactor, 0.7))
        #expect(isClose(extracted.scene.instances[0].material.roughnessFactor, 0.25))
        #expect(extracted.scene.instances[0].material.emissiveFactor == SIMD3<Float>(0.1, 0.2, 0.3))
        #expect(translation(of: extracted.scene.instances[0].transform) == SIMD3<Float>(1, 0, 0))
        #expect(translation(of: extracted.scene.instances[1].transform) == SIMD3<Float>(1, 2, 0))
        #expect(extracted.lightEntities == [keyLight])
        #expect(extracted.scene.lights.count == 1)
        #expect(extracted.scene.lights[0].entity == keyLight)
        #expect(extracted.scene.lights[0].type == .spot)
        #expect(extracted.scene.lights[0].position == SIMD3<Float>(2, 5, 1))
        #expect(extracted.scene.lights[0].direction == SIMD3<Float>(0, 0, -1))
        #expect(extracted.scene.lights[0].color == SIMD3<Float>(1, 0.8, 0.6))
        #expect(isClose(extracted.scene.lights[0].intensity, 2.5))
        #expect(isClose(extracted.scene.lights[0].range, 18))
        #expect(isClose(extracted.scene.lights[0].spotInnerAngleRadians, 12 * .pi / 180))
        #expect(isClose(extracted.scene.lights[0].spotOuterAngleRadians, 45 * .pi / 180))
    }

    @Test("renderExtract propagates castShadows from LightComponent to RenderLight")
    func renderExtractPropagatesCastShadows() {
        var runtime = SceneRuntime()

        let light = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 5, 0)), for: light)
        _ = runtime.setComponent(
            LightComponent(type: .directional,
                           color: SIMD3<Float>(1, 1, 1),
                           intensity: 1,
                           range: 50,
                           castShadows: true),
            for: light
        )

        _ = runtime.tick()

        guard let extracted = runtime.extractedRenderScene else {
            Issue.record("expected extracted render scene resource")
            return
        }

        #expect(extracted.scene.lights.count == 1)
        #expect(extracted.scene.lights[0].castShadows == true)
    }

    @Test("renderExtract falls back to the default camera when the world has no camera entity")
    func renderExtractFallsBackToDefaultCamera() {
        var runtime = SceneRuntime()

        let mesh = runtime.createEntity()
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 0), for: mesh)

        _ = runtime.tick()

        guard let extracted = runtime.extractedRenderScene else {
            Issue.record("expected extracted render scene resource")
            return
        }

        #expect(extracted.activeCameraEntity == nil)
        #expect(extracted.scene.camera.eye == RenderCamera.fallbackPerspective.eye)
        #expect(extracted.instanceEntities == [mesh])
        #expect(extracted.lightEntities.isEmpty)
        #expect(extracted.scene.lights.isEmpty)
        #expect(extracted.scene.environment == .fallback)
        #expect(translation(of: extracted.scene.instances[0].transform) == .zero)
    }

    @Test("editor preview tick emits and extracts Sparks particles end-to-end")
    func bootstrapSceneEmitsAndExtractsParticles() {
        var runtime = SceneRuntime()
        runtime.bootstrapEditorPreviewScene()

        // Mimic the editor's per-frame tick (~60fps) — exercises the real
        // seed → advance (continuous emission) → extract chain.
        for _ in 0..<30 {
            _ = runtime.tick(deltaTime: 1.0 / 60.0)
        }

        guard let extracted = runtime.extractedRenderScene else {
            Issue.record("expected extracted render scene resource")
            return
        }

        #expect(!extracted.scene.particles.isEmpty)
        // The Sparks emitter sits at (0, 2.2, 0); particles spawn there and rise.
        if let nearest = extracted.scene.particles.last {
            #expect(nearest.position.y > 1.5)
        }
    }

    @Test("renderExtract flattens emitters into sorted world-space particles")
    func renderExtractCollectsParticles() {
        var runtime = SceneRuntime()

        let camera = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: camera)
        _ = runtime.setComponent(CameraComponent(isActive: true), for: camera)

        func makeEmitter(z: Float) -> EntityID {
            let entity = runtime.createEntity()
            _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 0, z)), for: entity)
            // No motion / no continuous emission: the manually emitted particle
            // stays at the emitter origin so the world transform is the only thing
            // moving it (deterministic with tick deltaTime == 0).
            var emitter = ParticleEmitter(
                isEmitting: false,
                emissionRate: 0,
                maxParticles: 16,
                lifetime: 100,
                spawnRadius: 0,
                startVelocity: .zero,
                velocityRandomness: .zero,
                gravity: .zero,
                startSize: 0.5
            )
            emitter.emit(1)
            _ = runtime.setComponent(emitter, for: entity)
            return entity
        }

        _ = makeEmitter(z: -5)
        _ = makeEmitter(z: -20)

        _ = runtime.tick()

        guard let extracted = runtime.extractedRenderScene else {
            Issue.record("expected extracted render scene resource")
            return
        }

        #expect(extracted.scene.particles.count == 2)
        // Particles are emitter-local at the origin, so each lands at its entity's
        // world position; back-to-front means the farther one (z = -20) comes first.
        #expect(isClose(extracted.scene.particles[0].position.z, -20))
        #expect(isClose(extracted.scene.particles[1].position.z, -5))
        #expect(isClose(extracted.scene.particles[0].size, 0.5))
    }
}

private func translation(of matrix: simd_float4x4) -> SIMD3<Float> {
    SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
}

private func isClose(_ lhs: Float, _ rhs: Float, tolerance: Float = 0.0001) -> Bool {
    abs(lhs - rhs) <= tolerance
}
