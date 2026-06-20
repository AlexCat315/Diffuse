import SceneRuntime
import ScriptRuntime
import Testing
import Foundation
import SIMDCompat

@Suite("SceneSerializer")
struct SceneSerializerTests {

    // MARK: - Empty scene

    @Test("round-trip: empty scene")
    func emptySceneRoundTrip() throws {
        let original = SceneRuntime()
        let data = try SceneSerializer.serialize(original)
        #expect(!data.isEmpty)

        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        #expect(restored.snapshot.entityCount == 0)
    }

    // MARK: - Single entity with transform

    @Test("round-trip: entity with name and transform")
    func entityWithNameAndTransform() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "TestEntity"), for: entity)
        _ = original.setLocalTransform(
            LocalTransform(matrix: translationMatrix(SIMD3<Float>(3, 5, 7))),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        #expect(restored.snapshot.entityCount == 1)
        let entities = restored.entities()
        #expect(entities.count == 1)
        let name = restored.component(SceneNameComponent.self, for: entities[0])
        #expect(name?.value == "TestEntity")
        let t = restored.localTransform(for: entities[0])
        #expect(t != nil)
        #expect(abs(t!.translation.x - 3) < 0.01)
        #expect(abs(t!.translation.y - 5) < 0.01)
        #expect(abs(t!.translation.z - 7) < 0.01)
    }

    // MARK: - Hierarchy

    @Test("round-trip: parent-child hierarchy")
    func parentChildHierarchy() throws {
        var original = SceneRuntime()
        let parent = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "Parent"), for: parent)
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: parent)

        let child = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "Child"), for: child)
        _ = original.setLocalTransform(LocalTransform(translation: SIMD3<Float>(1, 0, 0)), for: child)
        _ = original.setParent(parent, for: child)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        _ = restored.tick()

        let entities = restored.entities()
        #expect(entities.count == 2)

        let restoredParent = restored.findEntity(named: "Parent")
        #expect(restoredParent != nil)
        let restoredChild = restored.findEntity(named: "Child")
        #expect(restoredChild != nil)

        let childParent = restored.parent(of: restoredChild!)
        #expect(childParent == restoredParent)
    }

    // MARK: - RigidBody

    @Test("round-trip: rigidbody preserves properties")
    func rigidBodyRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            RigidBody(motionType: .dynamic, mass: 80, gravityScale: 2, linearDamping: 0.1, allowSleep: false),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        #expect(entities.count == 1)
        let rb = restored.component(RigidBody.self, for: entities[0])
        #expect(rb != nil)
        #expect(rb!.motionType == .dynamic)
        #expect(rb!.mass == 80)
        #expect(rb!.gravityScale == 2)
        #expect(rb!.linearDamping == 0.1)
        #expect(rb!.allowSleep == false)
    }

    // MARK: - Collider shapes

    @Test("round-trip: box collider")
    func boxColliderRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(1, 2, 3), center: SIMD3<Float>(0, 0.5, 0)),
                     isTrigger: true, layerID: 3, layerMask: 0x00FF),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let col = restored.component(Collider.self, for: entities[0])
        #expect(col != nil)
        #expect(col!.isTrigger == true)
        #expect(col!.layerID == 3)
        #expect(col!.layerMask == 0x00FF)

        if case let .box(he, center) = col!.shape {
            #expect(he == SIMD3<Float>(1, 2, 3))
            #expect(center == SIMD3<Float>(0, 0.5, 0))
        } else {
            #expect(Bool(false), "expected box shape")
        }
    }

    @Test("round-trip: sphere collider")
    func sphereColliderRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            Collider(shape: .sphere(radius: 2.5, center: SIMD3<Float>(0, 1, 0))),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let col = restored.component(Collider.self, for: entities[0])
        #expect(col != nil)
        if case let .sphere(r, c) = col!.shape {
            #expect(r == 2.5)
            #expect(c == SIMD3<Float>(0, 1, 0))
        } else {
            #expect(Bool(false), "expected sphere shape")
        }
    }

    // MARK: - Camera

    @Test("round-trip: camera component")
    func cameraRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            CameraComponent(target: SIMD3<Float>(0, 1, 0), fovYRadians: 1.2, near: 0.05, far: 500, isActive: true),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let cam = restored.component(CameraComponent.self, for: entities[0])
        #expect(cam != nil)
        #expect(cam!.isActive)
        #expect(cam!.fovYRadians == 1.2)
        #expect(cam!.near == 0.05)
        #expect(cam!.far == 500)
    }

    // MARK: - Light

    @Test("round-trip: light component")
    func lightRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            LightComponent(type: .spot, color: SIMD3<Float>(1, 0.5, 0.2), intensity: 5, range: 25,
                          spotInnerAngleDegrees: 15, spotOuterAngleDegrees: 40, castShadows: true),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let light = restored.component(LightComponent.self, for: entities[0])
        #expect(light != nil)
        #expect(light!.type == .spot)
        #expect(light!.intensity == 5)
        #expect(light!.range == 25)
        #expect(light!.castShadows)
    }

    // MARK: - Audio

    @Test("round-trip: audio source and listener")
    func audioRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        _ = original.setComponent(
            AudioSource(clipName: "footstep", volume: 0.8, pitch: 1.2, loop: true, spatialBlend: 0.5),
            for: entity
        )
        _ = original.setComponent(AudioListener(masterVolume: 0.9), for: entity)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let src = restored.component(AudioSource.self, for: entities[0])
        #expect(src != nil)
        #expect(src!.clipName == "footstep")
        #expect(src!.volume == 0.8)
        #expect(src!.loop)

        let listener = restored.component(AudioListener.self, for: entities[0])
        #expect(listener != nil)
        #expect(listener!.masterVolume == 0.9)
    }

    // MARK: - Animation

    @Test("round-trip: animation graph player")
    func animationGraphPlayerRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        let graph = AnimationGraph(
            blendSpaces1D: [
                AnimationBlendSpace1D(
                    name: "locomotion",
                    parameter: "speed",
                    samples: [
                        AnimationBlendSample1D(clipName: "idle", threshold: 0),
                        AnimationBlendSample1D(clipName: "run", threshold: 1),
                    ]
                ),
            ],
            stateMachine: AnimationStateMachine(
                initialState: "Idle",
                states: [
                    AnimationState(name: "Idle", motion: .clip("idle")),
                    AnimationState(name: "Run", motion: .blendSpace1D("locomotion"), speed: 1.25),
                ],
                transitions: [
                    AnimationTransition(from: "Idle",
                                        to: "Run",
                                        parameter: "speed",
                                        comparison: .greaterThan,
                                        threshold: 0.5,
                                        duration: 0.2),
                ]
            )
        )
        _ = original.setComponent(
            AnimationGraphPlayer(graph: graph,
                                 parameters: ["speed": 0.75],
                                 activeState: "Run",
                                 previousState: "Idle",
                                 activeTime: 0.4,
                                 previousTime: 1.2,
                                 transitionElapsed: 0.1,
                                 transitionDuration: 0.2,
                                 speed: 1.5,
                                 isPlaying: false),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let entities = restored.entities()
        let player = restored.component(AnimationGraphPlayer.self, for: entities[0])
        #expect(player != nil)
        #expect(player?.graph.blendSpaces1D.first?.samples.count == 2)
        #expect(player?.graph.stateMachine.transitions.first?.comparison == .greaterThan)
        #expect(player?.graph.stateMachine.states.last?.motion == .blendSpace1D("locomotion"))
        #expect(player?.parameters["speed"] == 0.75)
        #expect(player?.activeState == "Run")
        #expect(player?.previousState == "Idle")
        #expect(player?.isPlaying == false)
    }

    // MARK: - Multi-entity

    @Test("round-trip: full scene with multiple entity types")
    func fullSceneRoundTrip() throws {
        var original = SceneRuntime()

        // Ground
        let ground = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "Ground"), for: ground)
        _ = original.setComponent(SceneKindComponent(value: "Static Mesh"), for: ground)
        _ = original.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, -0.5, 0)), for: ground)
        _ = original.setComponent(RenderMeshComponent(meshIndex: 0), for: ground)
        _ = original.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(10, 0.5, 10), center: .zero)),
            for: ground
        )
        _ = original.setComponent(RigidBody(motionType: .static), for: ground)

        // Player
        let player = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "Player"), for: player)
        _ = original.setComponent(SceneKindComponent(value: "Character"), for: player)
        _ = original.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 1, 0)), for: player)
        _ = original.setComponent(
            Collider(shape: .capsule(radius: 0.5, halfHeight: 1, center: SIMD3<Float>(0, 1, 0))),
            for: player
        )
        _ = original.setComponent(RigidBody(motionType: .dynamic, mass: 80), for: player)

        // Camera
        let camera = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "MainCamera"), for: camera)
        _ = original.setComponent(SceneKindComponent(value: "Camera"), for: camera)
        _ = original.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 5, 10)), for: camera)
        _ = original.setComponent(CameraComponent(isActive: true), for: camera)
        _ = original.setComponent(AudioListener(), for: camera)

        // Hierarchy
        _ = original.setParent(ground, for: player)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        #expect(restored.snapshot.entityCount == 3)

        // Verify all entities exist with correct components
        let ground2 = restored.findEntity(named: "Ground")
        #expect(ground2 != nil)
        #expect(restored.component(RigidBody.self, for: ground2!)?.motionType == .static)
        #expect(restored.component(RenderMeshComponent.self, for: ground2!)?.meshIndex == 0)

        let player2 = restored.findEntity(named: "Player")
        #expect(player2 != nil)
        #expect(restored.component(RigidBody.self, for: player2!)?.mass == 80)
        #expect(restored.component(Collider.self, for: player2!) != nil)

        let camera2 = restored.findEntity(named: "MainCamera")
        #expect(camera2 != nil)
        #expect(restored.component(CameraComponent.self, for: camera2!)?.isActive == true)
        #expect(restored.component(AudioListener.self, for: camera2!) != nil)

        // Verify hierarchy
        _ = restored.tick()
        #expect(restored.parent(of: player2!) == ground2)
    }

    // MARK: - Render material

    @Test("round-trip: render material (PBR factors + texture indices)")
    func renderMaterialRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setComponent(
            RenderMaterialComponent(baseColorFactor: SIMD4<Float>(0.2, 0.4, 0.6, 1),
                                    baseColorTextureIndex: 7,
                                    normalTextureIndex: 9,
                                    metallicFactor: 0.8,
                                    roughnessFactor: 0.3,
                                    emissiveFactor: SIMD3<Float>(1, 0, 0)),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let m = restored.component(RenderMaterialComponent.self, for: restored.entities()[0])
        #expect(m != nil)
        #expect(m!.baseColorFactor == SIMD4<Float>(0.2, 0.4, 0.6, 1))
        #expect(m!.baseColorTextureIndex == 7)
        #expect(m!.normalTextureIndex == 9)
        #expect(m!.metallicFactor == 0.8)
        #expect(m!.roughnessFactor == 0.3)
        #expect(m!.emissiveFactor == SIMD3<Float>(1, 0, 0))
    }

    // MARK: - Asset reference

    @Test("round-trip: asset reference")
    func assetReferenceRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setComponent(
            AssetReferenceComponent(assetID: "a1", name: "Barrel", relativePath: "models/barrel.glb",
                                    absolutePath: "/proj/models/barrel.glb", kind: "mesh", meshIndex: 4),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let a = restored.component(AssetReferenceComponent.self, for: restored.entities()[0])
        #expect(a == AssetReferenceComponent(assetID: "a1", name: "Barrel", relativePath: "models/barrel.glb",
                                             absolutePath: "/proj/models/barrel.glb", kind: "mesh", meshIndex: 4))
    }

    // MARK: - Particle emitter config

    @Test("round-trip: particle emitter configuration")
    func particleEmitterRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        let subEmitters = [
            ParticleSubEmitter(trigger: .death,
                               burstCount: 2,
                               probability: 0.5,
                               maxDepth: 1,
                               inheritVelocity: 0.2,
                               lifetime: 0.4,
                               startVelocity: SIMD3<Float>(2, 0, 0),
                               velocityRandomness: SIMD3<Float>(0.1, 0, 0),
                               startSize: 0.3,
                               endSize: 0.1,
                               startColor: SIMD4<Float>(1, 0, 0, 1),
                               endColor: SIMD4<Float>(1, 0, 0, 0)),
            ParticleSubEmitter(trigger: .collision,
                               burstCount: 1,
                               probability: 1,
                               maxDepth: 2,
                               inheritVelocity: 0.4,
                               lifetime: 0.8,
                               startVelocity: SIMD3<Float>(0, 2, 0),
                               velocityRandomness: SIMD3<Float>(0, 0.2, 0),
                               startSize: 0.5,
                               endSize: 0.2,
                               startColor: SIMD4<Float>(0, 0, 1, 1),
                               endColor: SIMD4<Float>(0, 0, 1, 0)),
        ]
        _ = original.setComponent(
            ParticleEmitter(looping: false, duration: 4.5,
                            prewarmTime: 1.25,
                            prewarmStep: 0.05,
                            emissionRate: 33,
                            emissionRateCurve: .constant(1.5),
                            distanceEmissionRate: 12,
                            distanceEmissionRateCurve: .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 0),
                                ParticleCurveKeyframe(time: 1, value: 2),
                            ]),
                            burstCount: 7, burstInterval: 0.25,
                            maxParticles: 128, lifetime: 1.5,
                            subEmitterTrigger: .collision,
                            subEmitterBurstCount: 3,
                            subEmitterProbability: 0.75,
                            subEmitterMaxDepth: 2,
                            subEmitterInheritVelocity: 0.5,
                            subEmitterLifetime: 0.35,
                            subEmitterStartVelocity: SIMD3<Float>(1, 2, 3),
                            subEmitterVelocityRandomness: SIMD3<Float>(0.1, 0.2, 0.3),
                            subEmitterStartSize: 0.2,
                            subEmitterEndSize: 0.05,
                            subEmitterStartColor: SIMD4<Float>(1, 0.5, 0.25, 1),
                            subEmitterEndColor: SIMD4<Float>(1, 0.25, 0, 0),
                            subEmitters: subEmitters,
                            spawnRadius: 0.25, emissionShape: .cone,
                            boxHalfExtents: SIMD3<Float>(1, 2, 3),
                            coneRadius: 0.75, coneHeight: 2.5,
                            startVelocity: SIMD3<Float>(0, 3, 0),
                            velocityInheritance: 0.4,
                            gravity: SIMD3<Float>(0, -2, 0),
                            noiseStrength: 1.25, noiseScale: 3.5, noiseSpeed: 0.75,
                            forceMode: .vortex,
                            forceCenter: SIMD3<Float>(1, 2, 3),
                            forceAxis: SIMD3<Float>(0, 1, 0),
                            forceRadius: 12,
                            forceStrength: 4.5,
                            forceFalloff: 2,
                            collisionMode: .worldPlane, simulationSpace: .world,
                            collisionPlaneY: -1,
                            collisionRestitution: 0.7, collisionDamping: 0.2,
                            startSize: 0.5, endSize: 0.1,
                            sizeRandomness: 0.35,
                            startRotation: 0.25,
                            rotationRandomness: 0.5,
                            angularVelocity: 1.5,
                            angularVelocityRandomness: 0.75,
                            sizeCurve: .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 0),
                                ParticleCurveKeyframe(time: 0.5, value: 1),
                                ParticleCurveKeyframe(time: 1, value: 0.25),
                            ]),
                            colorCurve: .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 1),
                                ParticleCurveKeyframe(time: 1, value: 0),
                            ]),
                            blendMode: .additive,
                            renderAlignment: .velocity,
                            velocityStretchScale: 0.25,
                            velocityStretchMax: 6,
                            maxRenderDistance: 80,
                            renderDistanceFadeRange: 12,
                            textureAssetID: "Assets/Textures/smoke.png",
                            texturePath: "/tmp/particle-smoke.png",
                            textureSheetColumns: 4,
                            textureSheetRows: 2,
                            textureSheetFrameCount: 7,
                            textureSheetFrameRate: 12,
                            trailLength: 0.75,
                            trailSegments: 5,
                            trailEndSizeScale: 0.25,
                            trailEndAlphaScale: 0.1,
                            seed: 12345),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let e = restored.component(ParticleEmitter.self, for: restored.entities()[0])
        #expect(e != nil)
        #expect(e!.emissionRate == 33)
        #expect(e!.emissionRateCurve == .constant(1.5))
        #expect(e!.distanceEmissionRate == 12)
        #expect(e!.distanceEmissionRateCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 1, value: 2),
        ]))
        #expect(e!.looping == false)
        #expect(e!.duration == 4.5)
        #expect(e!.prewarmTime == 1.25)
        #expect(e!.prewarmStep == 0.05)
        #expect(e!.burstCount == 7)
        #expect(e!.burstInterval == 0.25)
        #expect(e!.maxParticles == 128)
        #expect(e!.lifetime == 1.5)
        #expect(e!.subEmitterTrigger == .collision)
        #expect(e!.subEmitterBurstCount == 3)
        #expect(e!.subEmitterProbability == 0.75)
        #expect(e!.subEmitterMaxDepth == 2)
        #expect(e!.subEmitterInheritVelocity == 0.5)
        #expect(e!.subEmitterLifetime == 0.35)
        #expect(e!.subEmitterStartVelocity == SIMD3<Float>(1, 2, 3))
        #expect(e!.subEmitterVelocityRandomness == SIMD3<Float>(0.1, 0.2, 0.3))
        #expect(e!.subEmitterStartSize == 0.2)
        #expect(e!.subEmitterEndSize == 0.05)
        #expect(e!.subEmitterStartColor == SIMD4<Float>(1, 0.5, 0.25, 1))
        #expect(e!.subEmitterEndColor == SIMD4<Float>(1, 0.25, 0, 0))
        #expect(e!.subEmitters == subEmitters)
        #expect(e!.spawnRadius == 0.25)
        #expect(e!.emissionShape == .cone)
        #expect(e!.boxHalfExtents == SIMD3<Float>(1, 2, 3))
        #expect(e!.coneRadius == 0.75)
        #expect(e!.coneHeight == 2.5)
        #expect(e!.startVelocity == SIMD3<Float>(0, 3, 0))
        #expect(e!.velocityInheritance == 0.4)
        #expect(e!.noiseStrength == 1.25)
        #expect(e!.noiseScale == 3.5)
        #expect(e!.noiseSpeed == 0.75)
        #expect(e!.forceMode == .vortex)
        #expect(e!.forceCenter == SIMD3<Float>(1, 2, 3))
        #expect(e!.forceAxis == SIMD3<Float>(0, 1, 0))
        #expect(e!.forceRadius == 12)
        #expect(e!.forceStrength == 4.5)
        #expect(e!.forceFalloff == 2)
        #expect(e!.collisionMode == .worldPlane)
        #expect(e!.simulationSpace == .world)
        #expect(e!.collisionPlaneY == -1)
        #expect(e!.collisionRestitution == 0.7)
        #expect(e!.collisionDamping == 0.2)
        #expect(e!.sizeRandomness == 0.35)
        #expect(e!.startRotation == 0.25)
        #expect(e!.rotationRandomness == 0.5)
        #expect(e!.angularVelocity == 1.5)
        #expect(e!.angularVelocityRandomness == 0.75)
        #expect(e!.sizeCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 0.5, value: 1),
            ParticleCurveKeyframe(time: 1, value: 0.25),
        ]))
        #expect(e!.colorCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 1),
            ParticleCurveKeyframe(time: 1, value: 0),
        ]))
        #expect(e!.blendMode == .additive)
        #expect(e!.renderAlignment == .velocity)
        #expect(e!.velocityStretchScale == 0.25)
        #expect(e!.velocityStretchMax == 6)
        #expect(e!.maxRenderDistance == 80)
        #expect(e!.renderDistanceFadeRange == 12)
        #expect(e!.textureAssetID == "Assets/Textures/smoke.png")
        #expect(e!.texturePath == "/tmp/particle-smoke.png")
        #expect(e!.textureSheetColumns == 4)
        #expect(e!.textureSheetRows == 2)
        #expect(e!.textureSheetFrameCount == 7)
        #expect(e!.textureSheetFrameRate == 12)
        #expect(e!.trailLength == 0.75)
        #expect(e!.trailSegments == 5)
        #expect(e!.trailEndSizeScale == 0.25)
        #expect(e!.trailEndAlphaScale == 0.1)
        #expect(e!.seed == 12345)
        // Deterministic config restored: same seed + same advance ⇒ same particles.
        var a = e!; var b = original.component(ParticleEmitter.self, for: original.entities()[0])!
        a.emit(5); b.emit(5)
        a.advance(deltaTime: 0.1); b.advance(deltaTime: 0.1)
        #expect(a.particles == b.particles)
    }

    // MARK: - Constraint

    @Test("round-trip: constraint reconnects to remapped entities")
    func constraintRoundTrip() throws {
        var original = SceneRuntime()
        let bodyA = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "A"), for: bodyA)
        let bodyB = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "B"), for: bodyB)
        _ = original.setComponent(
            Constraint(constraintType: .hinge, entityA: bodyA, entityB: bodyB,
                       pivotA: SIMD3<Float>(1, 0, 0), pivotB: SIMD3<Float>(-1, 0, 0),
                       axisA: SIMD3<Float>(0, 0, 1), axisB: SIMD3<Float>(0, 0, 1),
                       minLimit: -1.2, maxLimit: 1.2),
            for: bodyA
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let a2 = restored.findEntity(named: "A")
        let b2 = restored.findEntity(named: "B")
        #expect(a2 != nil && b2 != nil)
        let c = restored.component(Constraint.self, for: a2!)
        #expect(c != nil)
        #expect(c!.constraintType == .hinge)
        #expect(c!.entityA == a2!)   // remapped to the restored entities, not the originals
        #expect(c!.entityB == b2!)
        #expect(c!.pivotA == SIMD3<Float>(1, 0, 0))
        #expect(c!.minLimit == -1.2)
        #expect(c!.maxLimit == 1.2)
    }

    @Test("prefab capture drops a constraint whose endpoint is outside the subtree")
    func prefabDropsDanglingConstraint() throws {
        var scene = SceneRuntime()
        let root = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Root"), for: root)
        let external = scene.createEntity() // not part of the captured subtree
        _ = scene.setComponent(
            Constraint(constraintType: .distance, entityA: root, entityB: external),
            for: root
        )

        let prefab = try #require(try Prefab.capture(from: scene, root: root))
        var target = SceneRuntime()
        let newRoot = try #require(try prefab.instantiate(into: &target))
        // The constraint referenced an entity outside the subtree, so it must not survive.
        #expect(target.component(Constraint.self, for: newRoot) == nil)
    }
}

private func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(1, 0, 0, t.x),
        SIMD4<Float>(0, 1, 0, t.y),
        SIMD4<Float>(0, 0, 1, t.z),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}
