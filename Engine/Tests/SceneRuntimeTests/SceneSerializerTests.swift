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
        let body = RigidBody(
            motionType: .dynamic,
            mass: 80,
            linearVelocity: SIMD3<Float>(1, 2, 3),
            angularVelocity: SIMD3<Float>(4, 5, 6),
            accumulatedForce: SIMD3<Float>(7, 8, 9),
            accumulatedTorque: SIMD3<Float>(10, 11, 12),
            accumulatedLinearImpulse: SIMD3<Float>(13, 14, 15),
            accumulatedAngularImpulse: SIMD3<Float>(16, 17, 18),
            gravityScale: 2,
            linearDamping: 0.1,
            allowSleep: false,
            isSleeping: true,
            continuousCollisionDetection: true
        )
        _ = original.setComponent(body, for: entity)

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
        #expect(rb!.continuousCollisionDetection)
        #expect(rb == body)
    }

    // MARK: - Collider shapes

    @Test("round-trip: native character controller")
    func characterControllerRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        let controller = CharacterController(
            radius: 0.35,
            standingHalfHeight: 0.7,
            crouchingHalfHeight: 0.3,
            center: SIMD3<Float>(0.1, 0.2, 0.3),
            maxSlopeDegrees: 42,
            stepHeight: 0.25,
            skinWidth: 0.015,
            mass: 82,
            maxStrength: 640,
            gravityScale: 1.25,
            layerID: 3,
            layerMask: 0x00FF
        )
        _ = original.setComponent(controller, for: entity)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        let restoredEntity = try #require(restored.entities().first)
        #expect(restored.component(CharacterController.self, for: restoredEntity) == controller)
    }

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
            CameraComponent(target: SIMD3<Float>(0, 1, 0),
                            fovYRadians: 1.2,
                            aspectRatio: 1.777,
                            near: 0.05,
                            far: 500,
                            isActive: true),
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
        #expect(cam!.aspectRatio == 1.777)
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
            ParticleEmitter(settings: .init {
                $0.emission.looping = false
                $0.emission.duration = 4.5
                $0.emission.simulationSpeed = 1.5
                $0.emission.prewarmTime = 1.25
                $0.emission.prewarmStep = 0.05
                $0.emission.emissionRate = 33
                $0.emission.emissionRateCurve = .constant(1.5)
                $0.emission.distanceEmissionRate = 12
                $0.emission.distanceEmissionRateCurve = .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 0),
                                ParticleCurveKeyframe(time: 1, value: 2),
                            ])
                $0.emission.burstCount = 7
                $0.emission.burstInterval = 0.25
                $0.emission.maxParticles = 128
                $0.emission.maxSpawnedParticlesPerFrame = 48
                $0.emission.maxRenderedParticles = 64
                $0.appearance.lifetime = 1.5
                $0.subEmitters.legacyTrigger = .collision
                $0.subEmitters.legacyBurstCount = 3
                $0.subEmitters.legacyProbability = 0.75
                $0.subEmitters.legacyMaxDepth = 2
                $0.subEmitters.legacyInheritVelocity = 0.5
                $0.subEmitters.legacyLifetime = 0.35
                $0.subEmitters.legacyStartVelocity = SIMD3<Float>(1, 2, 3)
                $0.subEmitters.legacyVelocityRandomness = SIMD3<Float>(0.1, 0.2, 0.3)
                $0.subEmitters.legacyStartSize = 0.2
                $0.subEmitters.legacyEndSize = 0.05
                $0.subEmitters.legacyStartColor = SIMD4<Float>(1, 0.5, 0.25, 1)
                $0.subEmitters.legacyEndColor = SIMD4<Float>(1, 0.25, 0, 0)
                $0.subEmitters.rules = subEmitters
                $0.shape.spawnRadius = 0.25
                $0.shape.emissionShape = .cone
                $0.shape.boxHalfExtents = SIMD3<Float>(1, 2, 3)
                $0.shape.coneRadius = 0.75
                $0.shape.coneHeight = 2.5
                $0.velocity.startVelocity = SIMD3<Float>(0, 3, 0)
                $0.velocity.velocityInheritance = 0.4
                $0.forces.gravity = SIMD3<Float>(0, -2, 0)
                $0.forces.noiseStrength = 1.25
                $0.forces.noiseScale = 3.5
                $0.forces.noiseSpeed = 0.75
                $0.forces.forceMode = .vortex
                $0.forces.forceCenter = SIMD3<Float>(1, 2, 3)
                $0.forces.forceAxis = SIMD3<Float>(0, 1, 0)
                $0.forces.forceRadius = 12
                $0.forces.forceStrength = 4.5
                $0.forces.forceFalloff = 2
                $0.forces.vectorFieldMode = .curl
                $0.forces.vectorFieldDirection = SIMD3<Float>(0, 0, 1)
                $0.forces.vectorFieldStrength = 6.25
                $0.forces.vectorFieldScale = 2.5
                $0.forces.vectorFieldScrollSpeed = 0.4
                $0.collision.collisionMode = .worldPlane
                $0.gpuSimulation.simulationSpace = .world
                $0.gpuSimulation.simulationBackend = .gpuIfSupported
                $0.gpuSimulation.workgroupSize = 128
                $0.collision.collisionPlaneY = -1
                $0.collision.collisionRestitution = 0.7
                $0.collision.collisionDamping = 0.2
                $0.appearance.startSize = 0.5
                $0.appearance.endSize = 0.1
                $0.appearance.sizeRandomness = 0.35
                $0.appearance.startRotation = 0.25
                $0.appearance.rotationRandomness = 0.5
                $0.appearance.angularVelocity = 1.5
                $0.appearance.angularVelocityRandomness = 0.75
                $0.appearance.sizeCurve = .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 0),
                                ParticleCurveKeyframe(time: 0.5, value: 1),
                                ParticleCurveKeyframe(time: 1, value: 0.25),
                            ])
                $0.appearance.colorCurve = .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 1),
                                ParticleCurveKeyframe(time: 1, value: 0),
                            ])
                $0.appearance.blendMode = .additive
                $0.renderer.renderMode = .ribbon
                $0.renderer.sortMode = .youngestFirst
                $0.renderer.renderSortPriority = 12
                $0.trails.ribbonWidthScale = 1.75
                $0.trails.ribbonTailWidthScale = 0.25
                $0.trails.ribbonTailAlphaScale = 0.15
                $0.trails.ribbonMaxSegmentLength = 3.5
                $0.trails.ribbonJoinOverlapScale = 0.4
                $0.trails.ribbonSmoothingSegments = 4
                $0.trails.ribbonTextureTiling = 2.25
                $0.trails.ribbonTextureOffset = 0.5
                $0.renderer.renderAlignment = .velocity
                $0.renderer.velocityStretchScale = 0.25
                $0.renderer.velocityStretchMax = 6
                $0.renderer.maxRenderDistance = 80
                $0.renderer.renderDistanceFadeRange = 12
                $0.renderer.renderLODStartDistance = 20
                $0.renderer.renderLODEndDistance = 70
                $0.renderer.renderLODMinParticleScale = 0.35
                $0.renderer.renderBoundsMode = .automatic
                $0.renderer.renderBoundsRadius = 24
                $0.textureSheet.textureAssetID = "Assets/Textures/smoke.png"
                $0.textureSheet.texturePath = "/tmp/particle-smoke.png"
                $0.textureSheet.columns = 4
                $0.textureSheet.rows = 2
                $0.textureSheet.frameCount = 7
                $0.textureSheet.frameRate = 12
                $0.textureSheet.playbackMode = .loop
                $0.textureSheet.startFrame = 3
                $0.textureSheet.frameRandomness = 2
                $0.trails.trailLength = 0.75
                $0.trails.trailSegments = 5
                $0.trails.trailEndSizeScale = 0.25
                $0.trails.trailEndAlphaScale = 0.1
                $0.emission.seed = 12345
            }),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let serializedEntities = try #require(json["entities"] as? [[String: Any]])
        let serializedComponents = try #require(serializedEntities.first?["components"] as? [String: Any])
        let serializedEmitter = try #require(serializedComponents["particleEmitter"] as? [String: Any])
        let settings = try #require(serializedEmitter["settings"] as? [String: Any])
        let emission = try #require(settings["emission"] as? [String: Any])
        #expect(emission["maxSpawnedParticlesPerFrame"] as? Int == 48)
        #expect(serializedEmitter["maxSpawnedParticlesPerFrame"] == nil)
        let moduleStack = try #require(serializedEmitter["moduleStack"] as? [String: Any])
        let modules = try #require(moduleStack["modules"] as? [[String: Any]])
        #expect(moduleStack["version"] as? Int == ParticleModuleStack.currentVersion)
        #expect(modules.map { $0["id"] as? String } == [
            "emission",
            "shape",
            "velocity",
            "forces",
            "collision",
            "appearance",
            "textureSheet",
            "renderer",
            "trails",
            "subEmitters",
            "gpuSimulation",
        ])
        let emissionModule = try #require(modules.first { $0["id"] as? String == "emission" })
        let emissionSettings = try #require(emissionModule["settings"] as? [String: Any])
        #expect(emissionSettings["type"] as? String == "emission")
        let emissionPayload = try #require(emissionSettings["payload"] as? [String: Any])
        #expect(emissionPayload["maxSpawnedParticlesPerFrame"] as? Int == 48)
        let textureSheetModule = try #require(modules.first { $0["id"] as? String == "textureSheet" })
        let textureSheetSettings = try #require(textureSheetModule["settings"] as? [String: Any])
        #expect(textureSheetSettings["type"] as? String == "textureSheet")
        let textureSheetPayload = try #require(textureSheetSettings["payload"] as? [String: Any])
        #expect(textureSheetPayload["textureAssetID"] as? String == "Assets/Textures/smoke.png")
        #expect(textureSheetPayload["playbackMode"] as? String == "loop")
        #expect(textureSheetPayload["startFrame"] as? Int == 3)
        #expect(textureSheetPayload["frameRandomness"] as? Int == 2)

        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let e = restored.component(ParticleEmitter.self, for: restored.entities()[0])
        #expect(e != nil)
        #expect(e!.settings.emission.emissionRate == 33)
        #expect(e!.settings.emission.emissionRateCurve == .constant(1.5))
        #expect(e!.settings.emission.distanceEmissionRate == 12)
        #expect(e!.settings.emission.distanceEmissionRateCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 1, value: 2),
        ]))
        #expect(e!.settings.emission.looping == false)
        #expect(e!.settings.emission.duration == 4.5)
        #expect(e!.settings.emission.prewarmTime == 1.25)
        #expect(e!.settings.emission.prewarmStep == 0.05)
        #expect(e!.settings.emission.burstCount == 7)
        #expect(e!.settings.emission.burstInterval == 0.25)
        #expect(e!.settings.emission.maxParticles == 128)
        #expect(e!.settings.emission.maxSpawnedParticlesPerFrame == 48)
        #expect(e!.settings.emission.maxRenderedParticles == 64)
        #expect(e!.settings.appearance.lifetime == 1.5)
        #expect(e!.settings.subEmitters.legacyTrigger == .collision)
        #expect(e!.settings.subEmitters.legacyBurstCount == 3)
        #expect(e!.settings.subEmitters.legacyProbability == 0.75)
        #expect(e!.settings.subEmitters.legacyMaxDepth == 2)
        #expect(e!.settings.subEmitters.legacyInheritVelocity == 0.5)
        #expect(e!.settings.subEmitters.legacyLifetime == 0.35)
        #expect(e!.settings.subEmitters.legacyStartVelocity == SIMD3<Float>(1, 2, 3))
        #expect(e!.settings.subEmitters.legacyVelocityRandomness == SIMD3<Float>(0.1, 0.2, 0.3))
        #expect(e!.settings.subEmitters.legacyStartSize == 0.2)
        #expect(e!.settings.subEmitters.legacyEndSize == 0.05)
        #expect(e!.settings.subEmitters.legacyStartColor == SIMD4<Float>(1, 0.5, 0.25, 1))
        #expect(e!.settings.subEmitters.legacyEndColor == SIMD4<Float>(1, 0.25, 0, 0))
        #expect(e!.settings.subEmitters.rules == subEmitters)
        #expect(e!.settings.shape.spawnRadius == 0.25)
        #expect(e!.settings.shape.emissionShape == .cone)
        #expect(e!.settings.shape.boxHalfExtents == SIMD3<Float>(1, 2, 3))
        #expect(e!.settings.shape.coneRadius == 0.75)
        #expect(e!.settings.shape.coneHeight == 2.5)
        #expect(e!.settings.velocity.startVelocity == SIMD3<Float>(0, 3, 0))
        #expect(e!.settings.velocity.velocityInheritance == 0.4)
        #expect(e!.settings.forces.noiseStrength == 1.25)
        #expect(e!.settings.forces.noiseScale == 3.5)
        #expect(e!.settings.forces.noiseSpeed == 0.75)
        #expect(e!.settings.forces.forceMode == .vortex)
        #expect(e!.settings.forces.forceCenter == SIMD3<Float>(1, 2, 3))
        #expect(e!.settings.forces.forceAxis == SIMD3<Float>(0, 1, 0))
        #expect(e!.settings.forces.forceRadius == 12)
        #expect(e!.settings.forces.forceStrength == 4.5)
        #expect(e!.settings.forces.forceFalloff == 2)
        #expect(e!.settings.forces.vectorFieldMode == .curl)
        #expect(e!.settings.forces.vectorFieldDirection == SIMD3<Float>(0, 0, 1))
        #expect(e!.settings.forces.vectorFieldStrength == 6.25)
        #expect(e!.settings.forces.vectorFieldScale == 2.5)
        #expect(e!.settings.forces.vectorFieldScrollSpeed == 0.4)
        #expect(e!.settings.collision.collisionMode == .worldPlane)
        #expect(e!.settings.gpuSimulation.simulationSpace == .world)
        #expect(e!.settings.gpuSimulation.simulationBackend == .gpuIfSupported)
        #expect(e!.settings.gpuSimulation.workgroupSize == 128)
        #expect(e!.settings.collision.collisionPlaneY == -1)
        #expect(e!.settings.collision.collisionRestitution == 0.7)
        #expect(e!.settings.collision.collisionDamping == 0.2)
        #expect(e!.settings.appearance.sizeRandomness == 0.35)
        #expect(e!.settings.appearance.startRotation == 0.25)
        #expect(e!.settings.appearance.rotationRandomness == 0.5)
        #expect(e!.settings.appearance.angularVelocity == 1.5)
        #expect(e!.settings.appearance.angularVelocityRandomness == 0.75)
        #expect(e!.settings.appearance.sizeCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 0.5, value: 1),
            ParticleCurveKeyframe(time: 1, value: 0.25),
        ]))
        #expect(e!.settings.appearance.colorCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 1),
            ParticleCurveKeyframe(time: 1, value: 0),
        ]))
        #expect(e!.settings.appearance.blendMode == .additive)
        #expect(e!.settings.renderer.renderMode == .ribbon)
        #expect(e!.settings.renderer.sortMode == .youngestFirst)
        #expect(e!.settings.renderer.renderSortPriority == 12)
        #expect(e!.settings.trails.ribbonWidthScale == 1.75)
        #expect(e!.settings.trails.ribbonTailWidthScale == 0.25)
        #expect(e!.settings.trails.ribbonTailAlphaScale == 0.15)
        #expect(e!.settings.trails.ribbonMaxSegmentLength == 3.5)
        #expect(e!.settings.trails.ribbonJoinOverlapScale == 0.4)
        #expect(e!.settings.trails.ribbonSmoothingSegments == 4)
        #expect(e!.settings.trails.ribbonTextureTiling == 2.25)
        #expect(e!.settings.trails.ribbonTextureOffset == 0.5)
        #expect(e!.settings.renderer.renderAlignment == .velocity)
        #expect(e!.settings.renderer.velocityStretchScale == 0.25)
        #expect(e!.settings.renderer.velocityStretchMax == 6)
        #expect(e!.settings.renderer.maxRenderDistance == 80)
        #expect(e!.settings.renderer.renderDistanceFadeRange == 12)
        #expect(e!.settings.renderer.renderLODStartDistance == 20)
        #expect(e!.settings.renderer.renderLODEndDistance == 70)
        #expect(e!.settings.renderer.renderLODMinParticleScale == 0.35)
        #expect(e!.settings.renderer.renderBoundsMode == .automatic)
        #expect(e!.settings.renderer.renderBoundsRadius == 24)
        #expect(e!.settings.textureSheet.textureAssetID == "Assets/Textures/smoke.png")
        #expect(e!.settings.textureSheet.texturePath == "/tmp/particle-smoke.png")
        #expect(e!.settings.textureSheet.columns == 4)
        #expect(e!.settings.textureSheet.rows == 2)
        #expect(e!.settings.textureSheet.frameCount == 7)
        #expect(e!.settings.textureSheet.frameRate == 12)
        #expect(e!.settings.textureSheet.playbackMode == .loop)
        #expect(e!.settings.textureSheet.startFrame == 3)
        #expect(e!.settings.textureSheet.frameRandomness == 2)
        #expect(e!.settings.emission.simulationSpeed == 1.5)
        #expect(e!.settings.trails.trailLength == 0.75)
        #expect(e!.settings.trails.trailSegments == 5)
        #expect(e!.settings.trails.trailEndSizeScale == 0.25)
        #expect(e!.settings.trails.trailEndAlphaScale == 0.1)
        #expect(e!.settings.emission.seed == 12345)
        // Deterministic config restored: same seed + same advance ⇒ same particles.
        var a = e!; var b = original.component(ParticleEmitter.self, for: original.entities()[0])!
        a.emit(5); b.emit(5)
        a.advance(deltaTime: 0.1); b.advance(deltaTime: 0.1)
        #expect(a.particles == b.particles)
    }

    @Test("deserialize: particle emitter module stack overrides legacy fields")
    func particleEmitterModuleStackOverridesLegacyFields() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setComponent(
            ParticleEmitter(settings: .init {
                $0.emission.emissionRate = 1
                $0.emission.maxParticles = 4
                $0.textureSheet.columns = 1
                $0.textureSheet.rows = 1
                $0.textureSheet.playbackMode = .automatic
            }),
            for: entity
        )

        let overridingEmitter = ParticleEmitter(settings: .init {
            $0.emission.emissionRate = 42
            $0.emission.maxParticles = 256
            $0.gpuSimulation.workgroupSize = 128
            $0.collision.collisionRestitution = 0.8
            $0.textureSheet.columns = 4
            $0.textureSheet.rows = 2
            $0.textureSheet.frameCount = 7
            $0.textureSheet.playbackMode = .singleFrame
            $0.textureSheet.startFrame = 3
            $0.textureSheet.frameRandomness = 2
        })
        let moduleStackData = try JSONEncoder().encode(overridingEmitter.moduleStack)
        let moduleStackObject = try JSONSerialization.jsonObject(with: moduleStackData)

        let data = try SceneSerializer.serialize(original)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entities = try #require(json["entities"] as? [[String: Any]])
        var components = try #require(entities[0]["components"] as? [String: Any])
        var emitter = try #require(components["particleEmitter"] as? [String: Any])
        emitter["moduleStack"] = moduleStackObject
        components["particleEmitter"] = emitter
        entities[0]["components"] = components
        json["entities"] = entities

        let editedData = try JSONSerialization.data(withJSONObject: json)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(editedData, into: &restored)

        let restoredEmitter = try #require(restored.component(ParticleEmitter.self, for: restored.entities()[0]))
        #expect(restoredEmitter.settings.emission.emissionRate == 42)
        #expect(restoredEmitter.settings.emission.maxParticles == 256)
        #expect(restoredEmitter.settings.collision.collisionRestitution == 0.8)
        #expect(restoredEmitter.settings.textureSheet.columns == 4)
        #expect(restoredEmitter.settings.textureSheet.rows == 2)
        #expect(restoredEmitter.settings.textureSheet.frameCount == 7)
        #expect(restoredEmitter.settings.textureSheet.playbackMode == .singleFrame)
        #expect(restoredEmitter.settings.textureSheet.startFrame == 3)
        #expect(restoredEmitter.settings.textureSheet.frameRandomness == 2)
        #expect(restoredEmitter.settings.gpuSimulation.workgroupSize == 128)
    }

    @Test("round-trip: disabled particle modules preserve authored settings")
    func disabledParticleModuleAuthoringRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()

        var emitter = ParticleEmitter(settings: .init {
            $0.textureSheet.columns = 1
            $0.textureSheet.rows = 1
            $0.textureSheet.frameCount = 1
            $0.textureSheet.playbackMode = .automatic
        })
        var stack = emitter.moduleStack
        let textureSheetIndex = try #require(stack.modules.firstIndex { $0.id == "textureSheet" })
        stack.modules[textureSheetIndex].isEnabled = false
        stack.modules[textureSheetIndex].isExpanded = true
        if case var .textureSheet(settings) = stack.modules[textureSheetIndex].settings {
            settings.textureAssetID = "Assets/Textures/fire-sheet.png"
            settings.texturePath = "/tmp/fire-sheet.png"
            settings.columns = 8
            settings.rows = 4
            settings.frameCount = 24
            settings.frameRate = 30
            settings.playbackMode = .loop
            settings.startFrame = 5
            settings.frameRandomness = 3
            stack.modules[textureSheetIndex].settings = .textureSheet(settings)
        } else {
            Issue.record("expected texture sheet module settings")
        }
        emitter.apply(stack)
        _ = original.setComponent(emitter, for: entity)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        var restoredEmitter = try #require(restored.component(ParticleEmitter.self, for: restored.entities()[0]))
        #expect(restoredEmitter.settings.textureSheet.columns == 1)
        #expect(restoredEmitter.settings.textureSheet.rows == 1)
        #expect(restoredEmitter.settings.textureSheet.frameCount == 1)
        #expect(restoredEmitter.settings.textureSheet.playbackMode == .automatic)

        var restoredStack = restoredEmitter.moduleStack
        let restoredTextureSheetIndex = try #require(restoredStack.modules.firstIndex { $0.id == "textureSheet" })
        let restoredTextureSheet = restoredStack.modules[restoredTextureSheetIndex]
        #expect(!restoredTextureSheet.isEnabled)
        #expect(restoredTextureSheet.isExpanded)
        if case let .textureSheet(settings) = restoredTextureSheet.settings {
            #expect(settings.textureAssetID == "Assets/Textures/fire-sheet.png")
            #expect(settings.texturePath == "/tmp/fire-sheet.png")
            #expect(settings.columns == 8)
            #expect(settings.rows == 4)
            #expect(settings.frameCount == 24)
            #expect(settings.frameRate == 30)
            #expect(settings.playbackMode == .loop)
            #expect(settings.startFrame == 5)
            #expect(settings.frameRandomness == 3)
        } else {
            Issue.record("expected texture sheet module settings")
        }

        restoredStack.modules[restoredTextureSheetIndex].isEnabled = true
        restoredEmitter.apply(restoredStack)
        #expect(restoredEmitter.settings.textureSheet.textureAssetID == "Assets/Textures/fire-sheet.png")
        #expect(restoredEmitter.settings.textureSheet.texturePath == "/tmp/fire-sheet.png")
        #expect(restoredEmitter.settings.textureSheet.columns == 8)
        #expect(restoredEmitter.settings.textureSheet.rows == 4)
        #expect(restoredEmitter.settings.textureSheet.frameCount == 24)
        #expect(restoredEmitter.settings.textureSheet.frameRate == 30)
        #expect(restoredEmitter.settings.textureSheet.playbackMode == .loop)
        #expect(restoredEmitter.settings.textureSheet.startFrame == 5)
        #expect(restoredEmitter.settings.textureSheet.frameRandomness == 3)
    }

    @Test("round-trip: duplicated particle modules remain diagnosable and repairable")
    func duplicatedParticleModuleStackRepairRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()

        var emitter = ParticleEmitter()
        var malformedStack = emitter.moduleStack
        let rendererModule = try #require(malformedStack.modules.first { $0.id == "renderer" })
        malformedStack.modules.insert(rendererModule, at: 0)
        emitter.authoredModuleStack = malformedStack
        _ = original.setComponent(emitter, for: entity)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        var restoredEmitter = try #require(restored.component(ParticleEmitter.self, for: restored.entities()[0]))
        #expect(restoredEmitter.moduleValidationIssues.contains {
            $0.moduleID == "renderer" && $0.code == "duplicateModule"
        })

        var repairedStack = restoredEmitter.moduleStack
        repairedStack.repairValidationIssues()
        restoredEmitter.apply(repairedStack)

        #expect(!restoredEmitter.moduleValidationIssues.contains {
            $0.code == "duplicateModule"
        })
        #expect(restoredEmitter.moduleStack.modules.filter { $0.id == "renderer" }.count == 1)
        #expect(restoredEmitter.moduleStack.modules.map(\.id).contains("trails"))
    }

    @Test("round-trip: particle module validation and repair survive serialization")
    func particleModuleValidationAndRepairRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        _ = original.setComponent(
            ParticleEmitter(settings: .init {
                $0.emission.emissionRate = 1
                $0.emission.maxParticles = 0
                $0.appearance.lifetime = 0
                $0.gpuSimulation.simulationBackend = .gpuRequired
                $0.gpuSimulation.workgroupSize = ParticleGPUSimulationPlan.maximumWorkgroupSize + 1
                $0.renderer.renderLODStartDistance = 20
                $0.renderer.renderLODEndDistance = 10
                $0.textureSheet.columns = 2
                $0.textureSheet.rows = 2
                $0.textureSheet.frameCount = 8
            }),
            for: entity
        )

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        var restoredEmitter = try #require(restored.component(ParticleEmitter.self, for: restored.entities()[0]))
        let restoredCodes = Set(restoredEmitter.moduleValidationIssues.map(\.code))
        #expect(restoredCodes.contains("noParticleCapacity"))
        #expect(restoredCodes.contains("invalidLifetime"))
        #expect(restoredCodes.contains("frameCountExceedsCells"))
        #expect(restoredCodes.contains("invalidLODRange"))
        #expect(restoredCodes.contains("gpuWorkgroupClamped"))
        #expect(restoredCodes.contains("gpuRequiredButUnsupported"))

        var repairedStack = restoredEmitter.moduleStack
        repairedStack.repairValidationIssues()
        restoredEmitter.apply(repairedStack)

        let repairedCodes = Set(restoredEmitter.moduleValidationIssues.map(\.code))
        #expect(!repairedCodes.contains("noParticleCapacity"))
        #expect(!repairedCodes.contains("invalidLifetime"))
        #expect(!repairedCodes.contains("frameCountExceedsCells"))
        #expect(!repairedCodes.contains("invalidLODRange"))
        #expect(!repairedCodes.contains("gpuWorkgroupClamped"))
        #expect(!repairedCodes.contains("gpuRequiredButUnsupported"))
        #expect(ParticleGPUSimulationPlan(emitter: restoredEmitter).status == .supported)
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

    @Test("round-trip: typed six-DOF joint preserves independent configuration")
    func typedJointRoundTrip() throws {
        var original = SceneRuntime()
        let bodyA = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "A"), for: bodyA)
        let bodyB = original.createEntity()
        _ = original.setComponent(SceneNameComponent(value: "B"), for: bodyB)
        let configuration = SixDOFJointConfiguration(
            axisA: SIMD3<Float>(1, 0, 0),
            axisB: SIMD3<Float>(0, 0, 1),
            linearMinimum: SIMD3<Float>(-1, -2, -3),
            linearMaximum: SIMD3<Float>(1, 2, 3),
            angularMinimum: SIMD3<Float>(-0.1, -0.2, -0.3),
            angularMaximum: SIMD3<Float>(0.1, 0.2, 0.3),
            linearMotor: PhysicsJointMotor(mode: .velocity, targetVelocity: 4, maxForce: 50),
            angularMotor: PhysicsJointMotor(mode: .position, targetPosition: 0.25, maxForce: 60),
            spring: PhysicsJointSpring(frequency: 3, damping: 0.7)
        )
        let joint = PhysicsJoint(
            configuration: .sixDOF(configuration),
            entityA: bodyA,
            entityB: bodyB,
            breakForce: 100,
            breakTorque: 200
        )
        _ = original.setComponent(joint, for: bodyA)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        let restoredA = try #require(restored.findEntity(named: "A"))
        let restoredJoint = try #require(restored.component(PhysicsJoint.self, for: restoredA))
        #expect(restoredJoint.configuration == .sixDOF(configuration))
        #expect(restoredJoint.breakForce == 100)
        #expect(restoredJoint.breakTorque == 200)
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
