import AssetPipeline
@testable import EditorCore
import Foundation
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat
import Testing

@Suite("EditorSceneAdapter", .serialized)
struct EditorSceneAdapterTests {
    @Test("Preview scene manifest captures hierarchy roots")
    func previewManifestCapturesHierarchyRoots() {
        let scene = EditorSceneAdapter()

        let manifest = scene.manifest(selectedEntityID: scene.defaultSelectionID)

        #expect(manifest.schemaVersion == EditorSceneManifest.currentSchemaVersion)
        #expect(manifest.revision == scene.revision)
        #expect(manifest.entityCount == scene.entityCount)
        #expect(manifest.selectedEntityID == scene.defaultSelectionID)
        #expect(!manifest.roots.isEmpty)
        #expect(manifest.roots.contains { $0.name == "Main Camera" })
        #expect(manifest.roots.contains { $0.components.value(for: "camera")?.objectValue != nil })
    }

    @Test("Preview scene reports active particles so the viewport keeps driving frames")
    func previewSceneHasActiveParticles() {
        let scene = EditorSceneAdapter()
        // The preview scene seeds an always-emitting "Sparks" emitter; under the
        // event-driven frame policy this is what keeps the viewport rendering so
        // particles animate instead of freezing.
        #expect(scene.hasActiveParticles())
    }

    @Test("Viewport framing centers and fits a complete multi-selection")
    func viewportFramingFitsMultiSelection() throws {
        let adapter = EditorSceneAdapter()
        adapter.setEditorViewportCameraEnabled(true)
        let left = adapter.scene.createEntity()
        let right = adapter.scene.createEntity()
        _ = adapter.scene.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(-2, 0, 0)), for: left
        )
        _ = adapter.scene.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(3, 4, 1)), for: right
        )
        adapter.scene.propagateTransforms()
        adapter.tickScene()

        let selectedIDs: Set<UInt64> = [left.rawValue, right.rawValue]
        let expectedMin = SIMD3<Float>(-2.25, -0.25, -0.25)
        let expectedMax = SIMD3<Float>(3.25, 4.25, 1.25)
        let expectedCenter = (expectedMin + expectedMax) * 0.5

        adapter.frameEntities(selectedIDs, viewportAspectRatio: 16.0 / 9.0)

        let camera = adapter.currentRenderCamera()
        #expect(simd_distance(camera.target, expectedCenter) < 1e-4)
    }

    @Test("Viewport framing preserves a parented game camera and frames through the editor camera")
    func viewportFramingHandlesParentedCamera() throws {
        let adapter = EditorSceneAdapter()
        adapter.setEditorViewportCameraEnabled(true)
        let nodes = flatten(adapter.roots)
        let cameraNode = try #require(nodes.first { $0.name == "Main Camera" })
        let selectedEntity = adapter.scene.createEntity()
        _ = adapter.scene.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(11, -2, 3)), for: selectedEntity
        )
        let parent = adapter.scene.createEntity()
        _ = adapter.scene.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(7, -3, 2)), for: parent
        )
        var runtimeScene = adapter.scene
        let didParentCamera = runtimeScene.setParent(parent, for: entityID(cameraNode.id))
        adapter.scene = runtimeScene
        #expect(didParentCamera)
        adapter.scene.propagateTransforms()
        adapter.tickScene()

        let cameraBefore = adapter.currentRenderCamera()
        let expectedMin = SIMD3<Float>(10.75, -2.25, 2.75)
        let expectedMax = SIMD3<Float>(11.25, -1.75, 3.25)
        let expected = EditorViewportFraming.pose(camera: cameraBefore,
                                                  boundsMin: expectedMin,
                                                  boundsMax: expectedMax)
        let manifestBefore = adapter.manifest()

        adapter.frameEntity(selectedEntity.rawValue)

        let camera = adapter.currentRenderCamera()
        #expect(simd_distance(camera.target, expected.target) < 1e-4)
        #expect(simd_distance(camera.eye, expected.eye) < 1e-4)
        #expect(adapter.manifest() == manifestBefore)
    }

    @Test("Non-looping particles stop driving preview frames after they expire")
    func nonLoopingParticlesStopDrivingPreviewFramesAfterExpiry() {
        let adapter = EditorSceneAdapter()
        adapter.scene = SceneRuntime()
        let entity = adapter.scene.createEntity()
        _ = adapter.scene.setComponent(
            ParticleEmitter(settings: .init {
                $0.emission.looping = false
                $0.emission.duration = 0.1
                $0.emission.emissionRate = 10
                $0.emission.maxParticles = 8
                $0.appearance.lifetime = 0.1
                $0.velocity.startVelocity = .zero
                $0.forces.gravity = .zero
            }),
            for: entity
        )

        #expect(adapter.hasActiveParticles())
        adapter.tickScene(deltaTime: 0.1)
        #expect(adapter.hasActiveParticles())
        adapter.tickScene(deltaTime: 0.2)
        #expect(!adapter.hasActiveParticles())
    }

    @Test("Editor scene adapter exposes particle frame stats after ticking")
    func editorSceneAdapterExposesParticleFrameStats() {
        let adapter = EditorSceneAdapter()
        let entity = adapter.scene.createEntity()
        _ = adapter.scene.setComponent(
            ParticleEmitter(settings: .init {
                $0.emission.emissionRate = 10
                $0.emission.maxParticles = 100
                $0.appearance.lifetime = 100
                $0.forces.gravity = .zero
            }),
            for: entity
        )

        adapter.tickScene(deltaTime: 1)

        let stats = adapter.currentParticleFrameStats()
        #expect(stats.emitterCount >= 1)
        #expect(stats.continuousSpawnedCount >= 10)
        #expect(stats.spawnedParticleCount >= 10)
        #expect(stats.liveParticleCount >= 10)
        #expect(stats.maxParticleCount >= 100)
    }

    @Test("Editor scene adapter exposes supported particle GPU simulation plan")
    func editorSceneAdapterExposesSelectedParticleGPUPlan() throws {
        let adapter = EditorSceneAdapter()
        let entity = adapter.scene.createEntity()
        var emitter = ParticleEmitter(settings: .init {
            $0.emission.emissionRate = 10
            $0.emission.maxParticles = 128
            $0.appearance.lifetime = 1
            $0.forces.gravity = .zero
        })
        emitter.settings.emission.distanceEmissionRate = 4
        emitter.settings.gpuSimulation.simulationBackend = .gpuRequired
        emitter.settings.gpuSimulation.workgroupSize = 32
        _ = adapter.scene.setComponent(emitter, for: entity)

        let plan = try #require(adapter.currentParticleGPUSimulationPlan(for: entity.rawValue))

        #expect(plan.status == .supported)
        #expect(plan.dispatchWorkgroups == 4)
        #expect(plan.workgroupSize == 32)
        #expect(plan.unsupportedReasons.isEmpty)
        #expect(adapter.currentParticleGPUSimulationPlan(for: nil) == nil)

        let issues = adapter.currentParticleModuleValidationIssues(for: entity.rawValue)
        #expect(!issues.contains {
            $0.moduleID == "gpuSimulation" && $0.code == "gpuRequiredButUnsupported"
        })
        #expect(adapter.currentParticleModuleValidationIssues(for: nil).isEmpty)
    }

    @Test("Editor scene adapter exposes particle module topology diagnostics")
    func editorSceneAdapterExposesParticleModuleTopologyDiagnostics() throws {
        let adapter = EditorSceneAdapter()
        let entity = adapter.scene.createEntity()
        var emitter = ParticleEmitter()
        var stack = emitter.moduleStack
        let renderer = try #require(stack.modules.first { $0.id == "renderer" })
        stack.modules.append(renderer)
        emitter.authoredModuleStack = stack
        _ = adapter.scene.setComponent(emitter, for: entity)

        let issues = adapter.currentParticleModuleValidationIssues(for: entity.rawValue)
        #expect(issues.contains {
            $0.moduleID == "renderer" && $0.code == "duplicateModule"
        })
    }

    @Test("Scene manifest restores preview hierarchy and runtime components")
    func sceneManifestRestoresPreviewHierarchyAndComponents() {
        let source = EditorSceneAdapter()
        let manifest = source.manifest(selectedEntityID: source.defaultSelectionID)
        let restored = EditorSceneAdapter()

        let result = restored.load(manifest: manifest)

        #expect(result.entityCount == manifest.entityCount)
        #expect(result.selectedEntityID != nil)
        #expect(restored.roots.map(\.name) == source.roots.map(\.name))

        let nodes = flatten(restored.roots)
        let hero = nodes.first { $0.name == "Hero" }
        let camera = nodes.first { $0.name == "Main Camera" }
        let light = nodes.first { $0.name == "Key Light" }
        let constraint = nodes.first { $0.name == "Hero Follow" }

        #expect(hero != nil)
        #expect(camera != nil)
        #expect(light != nil)
        #expect(constraint != nil)

        if let heroID = hero.map(\.id).map(entityID) {
            #expect(restored.scene.component(RenderMeshComponent.self, for: heroID)?.meshIndex == 1)
            #expect(restored.scene.component(RigidBody.self, for: heroID)?.motionType == .dynamic)
            #expect(restored.scene.component(Collider.self, for: heroID) != nil)
        }
        if let cameraID = camera.map(\.id).map(entityID) {
            #expect(restored.scene.component(CameraComponent.self, for: cameraID)?.isActive == true)
            #expect(restored.scene.component(CameraComponent.self, for: cameraID)?.aspectRatio == 1)
        }
        if let lightID = light.map(\.id).map(entityID) {
            #expect(restored.scene.component(LightComponent.self, for: lightID)?.intensity == 3.0)
        }
        if let constraintID = constraint.map(\.id).map(entityID) {
            #expect(restored.scene.component(Constraint.self, for: constraintID)?.constraintType == .distance)
        }
    }

    @Test("Scene manifest preserves Jolt CCD and pending impulses")
    func sceneManifestPreservesCompleteJoltRigidBodyState() throws {
        let source = EditorSceneAdapter()
        source.scene = SceneRuntime()
        let entity = source.scene.createEntity()
        _ = source.scene.setComponent(SceneNameComponent(value: "Jolt Body"), for: entity)
        _ = source.scene.setComponent(
            RigidBody(
                linearVelocity: SIMD3<Float>(1, 2, 3),
                angularVelocity: SIMD3<Float>(4, 5, 6),
                accumulatedForce: SIMD3<Float>(7, 8, 9),
                accumulatedTorque: SIMD3<Float>(10, 11, 12),
                accumulatedLinearImpulse: SIMD3<Float>(13, 14, 15),
                accumulatedAngularImpulse: SIMD3<Float>(16, 17, 18),
                continuousCollisionDetection: true
            ),
            for: entity
        )

        let manifest = source.manifest(selectedEntityID: entity.rawValue)
        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: encoded)
        let restored = EditorSceneAdapter()
        _ = restored.load(manifest: decoded)

        let restoredNode = try #require(flatten(restored.roots).first { $0.name == "Jolt Body" })
        let body = try #require(
            restored.scene.component(RigidBody.self, for: entityID(restoredNode.id))
        )
        #expect(body.linearVelocity == SIMD3<Float>(1, 2, 3))
        #expect(body.angularVelocity == SIMD3<Float>(4, 5, 6))
        #expect(body.accumulatedForce == SIMD3<Float>(7, 8, 9))
        #expect(body.accumulatedTorque == SIMD3<Float>(10, 11, 12))
        #expect(body.accumulatedLinearImpulse == SIMD3<Float>(13, 14, 15))
        #expect(body.accumulatedAngularImpulse == SIMD3<Float>(16, 17, 18))
        #expect(body.continuousCollisionDetection)
    }

    @Test("Scene manifest preserves collision steps and restores Jolt backend")
    func sceneManifestPreservesCompleteJoltSettings() throws {
        let source = EditorSceneAdapter()
        source.scene.setResource(
            PhysicsSettingsResource(
                simulationMode: .bake,
                backendKind: .none,
                gravity: SIMD3<Float>(1, -15, 2),
                fixedTimeStepSeconds: 1.0 / 120.0,
                maxSubstepsPerFrame: 8,
                allowSleep: false,
                collisionSteps: 4,
                capacity: PhysicsCapacitySettings(
                    maxBodies: 20_000,
                    bodyMutexCount: 128,
                    maxBodyPairs: 40_000,
                    maxContactConstraints: 12_000,
                    tempAllocatorBytes: 32 * 1_024 * 1_024,
                    workerThreadCount: 3
                )
            )
        )

        let encoded = try JSONEncoder().encode(source.manifest())
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: encoded)
        let restored = EditorSceneAdapter()
        _ = restored.load(manifest: decoded)

        let settings = try #require(restored.scene.resource(PhysicsSettingsResource.self))
        #expect(settings.backendKind == .jolt)
        #expect(settings.simulationMode == .bake)
        #expect(settings.gravity == SIMD3<Float>(1, -15, 2))
        #expect(abs(settings.fixedTimeStepSeconds - (1.0 / 120.0)) < 0.000_001)
        #expect(settings.maxSubstepsPerFrame == 8)
        #expect(settings.collisionSteps == 4)
        #expect(!settings.allowSleep)
        #expect(settings.capacity == PhysicsCapacitySettings(
            maxBodies: 20_000,
            bodyMutexCount: 128,
            maxBodyPairs: 40_000,
            maxContactConstraints: 12_000,
            tempAllocatorBytes: 32 * 1_024 * 1_024,
            workerThreadCount: 3
        ))
    }

    @Test("Scene manifest round-trips particle scalability settings")
    func sceneManifestRoundTripsParticleScalabilitySettings() throws {
        let source = EditorSceneAdapter()
        source.scene.setResource(ParticleScalabilityResource(emissionScale: 0.4,
                                                            burstScale: 0.5,
                                                            distanceEmissionScale: 0.6,
                                                            maxLiveParticleScale: 0.7))
        source.scene.setResource(ParticleScalabilityPolicyResource(isEnabled: true,
                                                                   targetLiveParticles: 128,
                                                                   targetSpawnedParticlesPerFrame: 32,
                                                                   minimumScale: 0.35,
                                                                   pressureStep: 0.25,
                                                                   recoveryStep: 0.1))

        let manifest = source.manifest(selectedEntityID: source.defaultSelectionID)
        #expect(manifest.particleScalability?.emissionScale == 0.4)
        #expect(manifest.particleScalability?.burstScale == 0.5)
        #expect(manifest.particleScalability?.distanceEmissionScale == 0.6)
        #expect(manifest.particleScalability?.maxLiveParticleScale == 0.7)
        #expect(manifest.particleScalabilityPolicy?.isEnabled == true)
        #expect(manifest.particleScalabilityPolicy?.targetLiveParticles == 128)
        #expect(manifest.particleScalabilityPolicy?.targetSpawnedParticlesPerFrame == 32)
        #expect(manifest.particleScalabilityPolicy?.minimumScale == 0.35)
        #expect(manifest.particleScalabilityPolicy?.pressureStep == 0.25)
        #expect(manifest.particleScalabilityPolicy?.recoveryStep == 0.1)

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let restored = EditorSceneAdapter()
        _ = restored.load(manifest: decoded)
        let settings = try #require(restored.scene.resource(ParticleScalabilityResource.self))
        #expect(settings.emissionScale == 0.4)
        #expect(settings.burstScale == 0.5)
        #expect(settings.distanceEmissionScale == 0.6)
        #expect(settings.maxLiveParticleScale == 0.7)
        let policy = try #require(restored.scene.resource(ParticleScalabilityPolicyResource.self))
        #expect(policy.isEnabled)
        #expect(policy.targetLiveParticles == 128)
        #expect(policy.targetSpawnedParticlesPerFrame == 32)
        #expect(policy.minimumScale == 0.35)
        #expect(policy.pressureStep == 0.25)
        #expect(policy.recoveryStep == 0.1)
    }

    @Test("Scene manifest round-trips camera aspect ratio")
    func sceneManifestRoundTripsCameraAspectRatio() throws {
        let source = EditorSceneAdapter()
        guard let cameraNode = flatten(source.roots).first(where: { $0.name == "Main Camera" }) else {
            Issue.record("Expected preview scene camera")
            return
        }
        let cameraID = entityID(cameraNode.id)
        guard source.scene.updateComponent(CameraComponent.self, for: cameraID, { camera in
            camera.aspectRatio = 1.777
        }) else {
            Issue.record("Expected camera component")
            return
        }

        let manifest = source.manifest(selectedEntityID: cameraNode.id)
        let cameraDoc = findNode(in: manifest.roots, id: cameraNode.id)?.components.value(for: "camera")?.objectValue
        #expect((cameraDoc?["aspectRatio"] as? NSNumber)?.floatValue == 1.777)

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let restored = EditorSceneAdapter()
        _ = restored.load(manifest: decoded)
        let restoredID = try #require(flatten(restored.roots).first { $0.name == "Main Camera" }?.id)
        #expect(restored.scene.component(CameraComponent.self, for: entityID(restoredID))?.aspectRatio == 1.777)
    }

    @Test("Scene manifest round-trips a complete wheel vehicle")
    func sceneManifestRoundTripsVehicle() throws {
        let source = EditorSceneAdapter()
        source.scene = SceneRuntime()
        let entity = source.scene.createEntity()
        _ = source.scene.setComponent(SceneNameComponent(value: "Test Vehicle"), for: entity)
        let vehicle = Vehicle(
            wheels: [
                VehicleWheelConfiguration(
                    position: SIMD3<Float>(0.8, -0.3, 1.2),
                    suspensionFrequency: 2.25,
                    radius: 0.42,
                    maxSteerAngle: 0.6
                ),
                VehicleWheelConfiguration(
                    position: SIMD3<Float>(-0.8, -0.3, 1.2),
                    suspensionFrequency: 2.25,
                    radius: 0.42,
                    maxSteerAngle: 0.6
                ),
            ],
            differentials: [VehicleDifferentialConfiguration(leftWheel: 0, rightWheel: 1)],
            antiRollBars: [VehicleAntiRollBarConfiguration(leftWheel: 0, rightWheel: 1, stiffness: 1_800)],
            engine: VehicleEngineConfiguration(maxTorque: 640, minRPM: 850, maxRPM: 7_200),
            transmission: VehicleTransmissionConfiguration(
                mode: .manual,
                gearRatios: [3.2, 2.1, 1.4],
                reverseGearRatios: [-3.0],
                clutchStrength: 14
            ),
            maxPitchRollAngle: 1.2,
            isEnabled: false
        )
        _ = source.scene.setComponent(vehicle, for: entity)

        let data = try JSONEncoder().encode(source.manifest(selectedEntityID: entity.rawValue))
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let restored = EditorSceneAdapter()
        _ = restored.load(manifest: decoded)
        let restoredRaw = try #require(flatten(restored.roots).first { $0.name == "Test Vehicle" }?.id)

        #expect(restored.scene.component(Vehicle.self, for: entityID(restoredRaw)) == vehicle)
        #expect(restored.inspectorSections(for: restoredRaw).contains { $0.id == "vehicle" })
    }

    @Test("Scene manifest preserves tracked and motorcycle controller settings")
    func sceneManifestRoundTripsVehicleControllers() throws {
        for (name, vehicle) in [
            ("Tracked Vehicle", Vehicle.tracked()),
            ("Motorcycle", Vehicle.motorcycle()),
        ] {
            let source = EditorSceneAdapter()
            source.scene = SceneRuntime()
            let entity = source.scene.createEntity()
            _ = source.scene.setComponent(SceneNameComponent(value: name), for: entity)
            _ = source.scene.setComponent(vehicle, for: entity)

            let data = try JSONEncoder().encode(source.manifest())
            let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
            let restored = EditorSceneAdapter()
            _ = restored.load(manifest: manifest)
            let restoredRaw = try #require(flatten(restored.roots).first { $0.name == name }?.id)
            #expect(restored.scene.component(Vehicle.self, for: entityID(restoredRaw)) == vehicle)
        }
    }

    @Test("Scene manifest round-trips destructible configuration")
    func sceneManifestRoundTripsDestructible() throws {
        let source = EditorSceneAdapter()
        source.scene = SceneRuntime()
        let entity = source.scene.createEntity()
        _ = source.scene.setComponent(SceneNameComponent(value: "Breakable Tower"), for: entity)
        let destructible = Destructible(
            assetResourceID: "tower.prefractured",
            damageThreshold: 90,
            impulseThreshold: 18,
            fragmentBudget: 144,
            maximumFragmentLifetimeSeconds: 22,
            sleepingRecycleDelaySeconds: 3.5,
            separationImpulse: 0.4,
            isEnabled: false
        )
        _ = source.scene.setComponent(destructible, for: entity)

        let data = try JSONEncoder().encode(source.manifest())
        let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let restored = EditorSceneAdapter()
        let result = restored.load(manifest: manifest)
        #expect(result.succeeded)
        let restoredRaw = try #require(
            flatten(restored.roots).first { $0.name == "Breakable Tower" }?.id
        )
        #expect(restored.scene.component(Destructible.self, for: entityID(restoredRaw)) == destructible)
        #expect(restored.inspectorSections(for: restoredRaw).contains { $0.id == "destructible" })
    }

    @Test("Scene manifest round-trips soft-body and cloth configuration")
    func sceneManifestRoundTripsSoftBodyAndCloth() throws {
        let source = EditorSceneAdapter()
        source.scene = SceneRuntime()
        let entity = source.scene.createEntity()
        _ = source.scene.setComponent(SceneNameComponent(value: "Cloth Banner"), for: entity)
        let softBody = SoftBody(
            vertexMass: 0.6,
            pressure: 1.25,
            linearDamping: 0.3,
            friction: 0.7,
            restitution: 0.15,
            gravityScale: 0.8,
            vertexRadius: 0.04,
            solverIterations: 12,
            maxLinearVelocity: 75,
            layerID: 4,
            layerMask: 0x00FF,
            allowSleep: false,
            facesDoubleSided: false,
            selfCollision: true,
            isEnabled: true
        )
        let cloth = Cloth(
            gridSizeX: 9,
            gridSizeZ: 7,
            spacing: 0.18,
            fixedVertexIndices: [0, 4, 8],
            compliance: 0.002,
            shearCompliance: 0.003,
            bendCompliance: 0.004,
            bendType: .dihedral
        )
        _ = source.scene.setComponent(softBody, for: entity)
        _ = source.scene.setComponent(cloth, for: entity)
        let meshEntity = source.scene.createEntity()
        _ = source.scene.setComponent(
            SceneNameComponent(value: "Soft Tetra"), for: meshEntity
        )
        let softBodyMesh = SoftBodyMesh(
            resourceID: "asset:soft-tetra",
            fixedVertexIndices: [1, 3],
            compliance: 0.005,
            shearCompliance: 0.006,
            bendCompliance: 0.007,
            volumeCompliance: 0.008,
            bendType: .distance
        )
        _ = source.scene.setComponent(softBody, for: meshEntity)
        _ = source.scene.setComponent(softBodyMesh, for: meshEntity)

        let data = try JSONEncoder().encode(source.manifest())
        let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let restored = EditorSceneAdapter()
        _ = restored.load(manifest: manifest)
        let restoredRaw = try #require(
            flatten(restored.roots).first { $0.name == "Cloth Banner" }?.id
        )
        let restoredEntity = entityID(restoredRaw)
        #expect(restored.scene.component(SoftBody.self, for: restoredEntity) == softBody)
        #expect(restored.scene.component(Cloth.self, for: restoredEntity) == cloth)
        #expect(restored.inspectorSections(for: restoredRaw).contains { $0.id == "soft-body" })
        #expect(restored.inspectorSections(for: restoredRaw).contains { $0.id == "cloth" })
        let restoredMeshRaw = try #require(
            flatten(restored.roots).first { $0.name == "Soft Tetra" }?.id
        )
        let restoredMeshEntity = entityID(restoredMeshRaw)
        #expect(restored.scene.component(SoftBody.self, for: restoredMeshEntity) == softBody)
        #expect(restored.scene.component(SoftBodyMesh.self, for: restoredMeshEntity) == softBodyMesh)
        #expect(restored.inspectorSections(for: restoredMeshRaw).contains {
            $0.id == "soft-body-mesh"
        })
    }

    @Test("soft-body viewport overlay exposes stable volume edges and fixed anchors")
    func softBodyConstraintOverlay() throws {
        let adapter = EditorSceneAdapter()
        adapter.scene = SceneRuntime()
        adapter.scene.setResource(MeshColliderGeometryResource(geometryByResourceID: [
            "soft.tetra": MeshColliderGeometry(
                positions: [
                    .zero,
                    SIMD3<Float>(1, 0, 0),
                    SIMD3<Float>(0, 1, 0),
                    SIMD3<Float>(0, 0, 1),
                ],
                triangleIndices: [0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3],
                tetrahedronIndices: [0, 1, 2, 3]
            ),
        ]))
        let entity = adapter.scene.createEntity()
        _ = adapter.scene.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(2, 3, 4)), for: entity
        )
        _ = adapter.scene.setComponent(SoftBody(), for: entity)
        _ = adapter.scene.setComponent(
            SoftBodyMesh(resourceID: "soft.tetra", fixedVertexIndices: [3]),
            for: entity
        )

        let overlay = try #require(
            adapter.viewportSoftBodyConstraints(entityID: entity.rawValue)
        )
        #expect(!overlay.usesSimulatedPositions)
        #expect(overlay.lines.count == 6)
        #expect(overlay.lines.allSatisfy { $0.kind == .volume })
        #expect(overlay.lines.map {
            (UInt64($0.vertexA) << 32) | UInt64($0.vertexB)
        } == [
            1, 2, 3,
            (UInt64(1) << 32) | 2,
            (UInt64(1) << 32) | 3,
            (UInt64(2) << 32) | 3,
        ])
        #expect(overlay.fixedVertices == [
            EditorSoftBodyFixedVertexMarker(
                vertex: 3,
                position: SIMD3<Float>(2, 3, 5)
            ),
        ])
    }

    @Test("destruction viewport overlay exposes stable world-space connection lines")
    func destructionConnectionOverlay() {
        let adapter = EditorSceneAdapter()
        adapter.scene = SceneRuntime()
        adapter.scene.setResource(DestructibleAssetResource(assetsByResourceID: [
            "wall.fracture": DestructibleAsset(
                fragments: [
                    DestructibleFragmentAsset(
                        fragmentID: 2,
                        colliderResourceID: "fragment.2",
                        localTransform: LocalTransform(translation: SIMD3<Float>(1, 0, 0))
                    ),
                    DestructibleFragmentAsset(
                        fragmentID: 0,
                        colliderResourceID: "fragment.0",
                        localTransform: LocalTransform(translation: SIMD3<Float>(-1, 0, 0))
                    ),
                    DestructibleFragmentAsset(
                        fragmentID: 1,
                        colliderResourceID: "fragment.1"
                    ),
                ],
                connections: [
                    DestructibleConnectionAsset(
                        connectionID: 8,
                        fragmentA: 1,
                        fragmentB: 2
                    ),
                    DestructibleConnectionAsset(
                        connectionID: 4,
                        fragmentA: 0,
                        fragmentB: 1
                    ),
                ]
            ),
        ]))
        let entity = adapter.scene.createEntity()
        _ = adapter.scene.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(2, 3, 4)), for: entity
        )
        _ = adapter.scene.setComponent(
            Destructible(assetResourceID: "wall.fracture"), for: entity
        )
        _ = adapter.scene.tick(deltaTime: 0)

        let lines = adapter.viewportDestructionConnections(entityID: entity.rawValue)
        #expect(lines.map(\.connectionID) == [4, 8])
        #expect(lines.map(\.positionA) == [
            SIMD3<Float>(1, 3, 4), SIMD3<Float>(2, 3, 4),
        ])
        #expect(lines.map(\.positionB) == [
            SIMD3<Float>(2, 3, 4), SIMD3<Float>(3, 3, 4),
        ])
        #expect(lines.allSatisfy { !$0.isBroken && !$0.isSourceFractured })
        #expect(adapter.viewportDestructionConnections(
            entityID: entity.rawValue,
            maxConnections: 1
        ).map(\.connectionID) == [4])
        #expect(adapter.viewportDestructionConnections(
            entityID: entity.rawValue,
            maxConnections: 0
        ).isEmpty)
    }

    @Test("physics debug overlay draws compound shapes, bounds, joint axes and limits")
    func physicsDebugOverlay() {
        let adapter = EditorSceneAdapter()
        adapter.scene = SceneRuntime()
        let bodyA = adapter.scene.createEntity()
        let bodyB = adapter.scene.createEntity()
        let jointEntity = adapter.scene.createEntity()
        _ = adapter.scene.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(1, 0, 0)),
            for: bodyA
        )
        _ = adapter.scene.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(4, 0, 0)),
            for: bodyB
        )
        _ = adapter.scene.setComponent(Collider(shapes: [
            ColliderShapeInstance(
                shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero),
                localPosition: SIMD3<Float>(2, 0, 0)
            ),
            ColliderShapeInstance(
                shape: .sphere(radius: 0.25, center: .zero),
                localPosition: SIMD3<Float>(-1, 0, 0)
            ),
        ]), for: bodyA)
        _ = adapter.scene.setComponent(RigidBody(motionType: .static), for: bodyA)
        _ = adapter.scene.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero)),
            for: bodyB
        )
        _ = adapter.scene.setComponent(RigidBody(motionType: .static), for: bodyB)
        _ = adapter.scene.setComponent(PhysicsJoint(
            configuration: .hinge(HingeJointConfiguration(
                axisA: SIMD3<Float>(0, 1, 0),
                axisB: SIMD3<Float>(0, 1, 0),
                minimumAngle: -0.5,
                maximumAngle: 0.75
            )),
            entityA: bodyA,
            entityB: bodyB,
            pivotA: SIMD3<Float>(0.5, 0, 0),
            pivotB: SIMD3<Float>(-0.5, 0, 0)
        ), for: jointEntity)

        _ = adapter.scene.tick(deltaTime: 0)
        let overlay = adapter.viewportPhysicsDebugOverlay(entityID: bodyA.rawValue)
        let colliderLines = overlay.lines.filter { $0.kind == .collider }
        #expect(overlay.lines.filter { $0.kind == .bounds }.count == 12)
        #expect(colliderLines.count > 12)
        #expect(colliderLines.contains { max($0.positionA.x, $0.positionB.x) >= 3.5 })
        #expect(overlay.lines.contains { $0.kind == .joint })
        #expect(overlay.lines.filter { $0.kind == .jointAxis }.count == 2)
        #expect(overlay.lines.contains { $0.kind == .jointLimit })
        #expect(overlay.contacts.isEmpty)

        let sceneShapes = adapter.viewportPhysicsDebugOverlay(options: [.shapes])
        #expect(sceneShapes.lines.allSatisfy { $0.kind == .collider })
        #expect(sceneShapes.lines.contains { $0.entityID == bodyA.rawValue })
        #expect(sceneShapes.lines.contains { $0.entityID == bodyB.rawValue })
        #expect(sceneShapes.lines.first?.entityID == bodyA.rawValue)

        let sceneJoints = adapter.viewportPhysicsDebugOverlay(options: [.joints])
        #expect(!sceneJoints.lines.isEmpty)
        #expect(sceneJoints.lines.allSatisfy {
            $0.kind == .joint || $0.kind == .jointAxis || $0.kind == .jointLimit
        })
        #expect(sceneJoints.lines.allSatisfy { $0.entityID == jointEntity.rawValue })

        _ = adapter.scene.updateComponent(PhysicsJoint.self, for: jointEntity) { joint in
            joint.configuration = .sixDOF(SixDOFJointConfiguration(
                linearMinimum: SIMD3<Float>(-1, -2, -3),
                linearMaximum: SIMD3<Float>(1, 2, 3),
                angularMinimum: SIMD3<Float>(repeating: -0.25),
                angularMaximum: SIMD3<Float>(repeating: 0.5)
            ))
        }
        _ = adapter.scene.tick(deltaTime: 0)
        let sixDOFOverlay = adapter.viewportPhysicsDebugOverlay(entityID: bodyA.rawValue)
        #expect(sixDOFOverlay.lines.filter { $0.kind == .jointLimit }.count >= 84)

        let bounded = adapter.viewportPhysicsDebugOverlay(
            entityID: bodyA.rawValue,
            maxLines: 10,
            maxContacts: 0
        )
        #expect(bounded.lines.count == 10)
        #expect(bounded.contacts.isEmpty)
    }

    @Test("Scene manifest remaps ragdoll bodies and exposes its inspector")
    func sceneManifestRoundTripsRagdoll() throws {
        let source = EditorSceneAdapter()
        source.scene = SceneRuntime()
        let root = source.scene.createEntity()
        _ = source.scene.setComponent(SceneNameComponent(value: "Ragdoll Root"), for: root)
        let body = source.scene.createEntity()
        _ = source.scene.setComponent(SceneNameComponent(value: "Hips Body"), for: body)
        _ = source.scene.setComponent(Ragdoll(
            mode: .blended,
            blendWeight: 0.4,
            bones: [RagdollBoneMapping(boneName: "hips", paletteIndex: 0, bodyEntity: body)]
        ), for: root)

        let data = try JSONEncoder().encode(source.manifest(selectedEntityID: root.rawValue))
        let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let restored = EditorSceneAdapter()
        _ = restored.load(manifest: manifest)
        let restoredRootRaw = try #require(flatten(restored.roots).first { $0.name == "Ragdoll Root" }?.id)
        let restoredBodyRaw = try #require(flatten(restored.roots).first { $0.name == "Hips Body" }?.id)
        let ragdoll = try #require(restored.scene.component(Ragdoll.self, for: entityID(restoredRootRaw)))
        #expect(ragdoll.mode == .blended)
        #expect(ragdoll.blendWeight == 0.4)
        #expect(ragdoll.bones.first?.bodyEntity == entityID(restoredBodyRaw))
        #expect(restored.inspectorSections(for: restoredRootRaw).contains { $0.id == "ragdoll" })
    }

    @Test("Ragdoll generator builds bodies, colliders, joints and palette mappings")
    func generatesRagdollFromSkin() throws {
        let meshIndex = 98_765
        AssetRegistry.shared.registerForTesting(MeshAsset(
            name: "ragdoll-test",
            vertices: [],
            indices: [],
            nodes: [
                MeshNode(name: "hips"),
                MeshNode(name: "spine", parentIndex: 0, localTranslation: SIMD3<Float>(0, 1, 0)),
            ],
            skins: [MeshSkin(
                jointNodeIndices: [0, 1],
                inverseBindMatrices: [matrix_identity_float4x4, translationMatrix(SIMD3<Float>(0, -1, 0))]
            )]
        ), at: meshIndex)
        defer { AssetRegistry.shared.unregisterTestingMesh(at: meshIndex) }
        let adapter = EditorSceneAdapter()
        adapter.scene = SceneRuntime()
        let root = adapter.scene.createEntity()
        _ = adapter.scene.setLocalTransform(.identity, for: root)
        _ = adapter.scene.setComponent(SceneNameComponent(value: "Hero"), for: root)
        _ = adapter.scene.setComponent(AssetReferenceComponent(
            assetID: "test",
            name: "Hero",
            relativePath: "hero.gltf",
            absolutePath: "/hero.gltf",
            kind: "gltf",
            meshIndex: meshIndex
        ), for: root)

        let result = adapter.generateRagdoll(for: root.rawValue)
        #expect(result.error == nil)
        #expect(result.bodyCount == 2)
        #expect(result.jointCount == 1)
        let ragdoll = try #require(adapter.scene.component(Ragdoll.self, for: root))
        #expect(ragdoll.bones.count == 2)
        for mapping in ragdoll.bones {
            #expect(adapter.scene.hasComponent(RigidBody.self, for: mapping.bodyEntity))
            #expect(adapter.scene.hasComponent(Collider.self, for: mapping.bodyEntity))
        }
        let jointEntity = try #require(ragdoll.bones.first { $0.boneName == "spine" }?.jointEntity)
        #expect(adapter.scene.hasComponent(PhysicsJoint.self, for: jointEntity))
    }

    @Test("Scene manifest round-trips the renderable scene contract")
    func sceneManifestRoundTripsRenderableSceneContract() {
        let source = EditorSceneAdapter()
        guard let hero = flatten(source.roots).first(where: { $0.name == "Hero" }) else {
            Issue.record("Expected preview scene hero")
            return
        }
        let heroID = entityID(hero.id)
        _ = source.scene.setComponent(
            RenderMeshComponent(meshIndex: 12,
                                isVisible: true,
                                colorTint: SIMD3<Float>(0.4, 0.5, 0.6),
                                assetID: "hero.asset"),
            for: heroID
        )
        _ = source.scene.setComponent(
            RenderMaterialComponent(baseColorFactor: SIMD4<Float>(0.8, 0.7, 0.6, 0.9),
                                    baseColorTextureIndex: 2,
                                    normalTextureIndex: 4,
                                    metallicFactor: 0.3,
                                    roughnessFactor: 0.65,
                                    emissiveFactor: SIMD3<Float>(0.1, 0.2, 0.3)),
            for: heroID
        )

        let manifest = source.manifest(selectedEntityID: hero.id)
        let manifestHero = findNode(in: manifest.roots, id: hero.id)

        let meshDoc = manifestHero?.components.value(for: "renderMesh")?.objectValue
        #expect((meshDoc?["meshIndex"] as? NSNumber)?.intValue == 12)
        #expect(meshDoc?["assetID"] as? String == "hero.asset")
        #expect((meshDoc?["colorTint"] as? [NSNumber])?.map { Float(truncating: $0) } == [0.4, 0.5, 0.6])
        let materialDoc = manifestHero?.components.value(for: "renderMaterial")?.objectValue
        #expect((materialDoc?["baseColorFactor"] as? [NSNumber])?.map { Float(truncating: $0) } == [0.8, 0.7, 0.6, 0.9])
        #expect((materialDoc?["baseColorTextureIndex"] as? NSNumber)?.intValue == 2)
        #expect((materialDoc?["normalTextureIndex"] as? NSNumber)?.intValue == 4)

        let restored = EditorSceneAdapter()
        let result = restored.load(manifest: manifest)
        guard let restoredHeroID = result.selectedEntityID.map(entityID) else {
            Issue.record("Expected restored hero selection")
            return
        }

        let restoredMesh = restored.scene.component(RenderMeshComponent.self, for: restoredHeroID)
        let restoredMaterial = restored.scene.component(RenderMaterialComponent.self, for: restoredHeroID)
        #expect(restoredMesh?.meshIndex == 12)
        #expect(restoredMesh?.assetID == "hero.asset")
        #expect(restoredMesh?.colorTint == SIMD3<Float>(0.4, 0.5, 0.6))
        #expect(restoredMaterial?.baseColorFactor == SIMD4<Float>(0.8, 0.7, 0.6, 0.9))
        #expect(restoredMaterial?.baseColorTextureIndex == 2)
        #expect(restoredMaterial?.normalTextureIndex == 4)
        #expect(restoredMaterial?.metallicFactor == 0.3)
        #expect(restoredMaterial?.roughnessFactor == 0.65)
        #expect(restoredMaterial?.emissiveFactor == SIMD3<Float>(0.1, 0.2, 0.3))
    }

    @Test("Scene manifest round-trips a particle emitter through JSON")
    @MainActor
    func sceneManifestRoundTripsParticleEmitter() throws {
        let source = EditorSceneAdapter()
        guard let hero = flatten(source.roots).first(where: { $0.name == "Hero" }) else {
            Issue.record("Expected preview scene hero")
            return
        }
        let subEmitters = [
            ParticleSubEmitter(trigger: .death,
                               burstCount: 2,
                               probability: 0.5,
                               maxDepth: 1,
                               inheritVelocity: 0.25,
                               lifetime: 0.45,
                               startVelocity: SIMD3<Float>(2, 0, 0),
                               velocityRandomness: SIMD3<Float>(0.1, 0, 0),
                               startSize: 0.3,
                               endSize: 0.12,
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
        _ = source.scene.setComponent(
            ParticleEmitter(settings: .init {
                $0.emission.looping = false
                $0.emission.duration = 3.25
                $0.emission.simulationSpeed = 1.4
                $0.emission.prewarmTime = 0.75
                $0.emission.prewarmStep = 0.04
                $0.emission.emissionRate = 24
                $0.emission.emissionRateCurve = .constant(1.25)
                $0.emission.distanceEmissionRate = 9
                $0.emission.distanceEmissionRateCurve = .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 0),
                                ParticleCurveKeyframe(time: 1, value: 2),
                            ])
                $0.emission.burstCount = 5
                $0.emission.burstInterval = 0.4
                $0.emission.maxParticles = 64
                $0.emission.maxSpawnedParticlesPerFrame = 12
                $0.emission.maxRenderedParticles = 32
                $0.appearance.lifetime = 1.25
                $0.subEmitters.legacyTrigger = .death
                $0.subEmitters.legacyBurstCount = 4
                $0.subEmitters.legacyProbability = 0.8
                $0.subEmitters.legacyMaxDepth = 2
                $0.subEmitters.legacyInheritVelocity = 0.45
                $0.subEmitters.legacyLifetime = 0.6
                $0.subEmitters.legacyStartVelocity = SIMD3<Float>(1, 2, 3)
                $0.subEmitters.legacyVelocityRandomness = SIMD3<Float>(0.2, 0.3, 0.4)
                $0.subEmitters.legacyStartSize = 0.22
                $0.subEmitters.legacyEndSize = 0.06
                $0.subEmitters.legacyStartColor = SIMD4<Float>(1, 0.5, 0.25, 1)
                $0.subEmitters.legacyEndColor = SIMD4<Float>(1, 0.1, 0, 0)
                $0.subEmitters.rules = subEmitters
                $0.shape.spawnRadius = 0.3
                $0.shape.emissionShape = .box
                $0.shape.boxHalfExtents = SIMD3<Float>(1, 2, 3)
                $0.shape.coneRadius = 0.8
                $0.shape.coneHeight = 3.5
                $0.velocity.startVelocity = SIMD3<Float>(0, 2, 0)
                $0.velocity.velocityInheritance = 0.35
                $0.forces.gravity = SIMD3<Float>(0, -3, 0)
                $0.forces.noiseStrength = 1.5
                $0.forces.noiseScale = 2.25
                $0.forces.noiseSpeed = 0.5
                $0.forces.forceMode = .radial
                $0.forces.forceCenter = SIMD3<Float>(1, 2, 3)
                $0.forces.forceAxis = SIMD3<Float>(0, 1, 0)
                $0.forces.forceRadius = 8
                $0.forces.forceStrength = -2.5
                $0.forces.forceFalloff = 1.5
                $0.forces.vectorFieldMode = .curl
                $0.forces.vectorFieldDirection = SIMD3<Float>(0, 0, 1)
                $0.forces.vectorFieldStrength = 3.75
                $0.forces.vectorFieldScale = 1.5
                $0.forces.vectorFieldScrollSpeed = 0.25
                $0.collision.collisionMode = .worldPlane
                $0.gpuSimulation.simulationSpace = .world
                $0.gpuSimulation.simulationBackend = .gpuIfSupported
                $0.gpuSimulation.workgroupSize = 128
                $0.collision.collisionPlaneY = -0.5
                $0.collision.collisionRestitution = 0.6
                $0.collision.collisionDamping = 0.15
                $0.appearance.startSize = 0.4
                $0.appearance.endSize = 0.05
                $0.appearance.sizeRandomness = 0.45
                $0.appearance.startRotation = 0.2
                $0.appearance.rotationRandomness = 0.4
                $0.appearance.angularVelocity = 1.2
                $0.appearance.angularVelocityRandomness = 0.6
                $0.appearance.sizeCurve = .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 0),
                                ParticleCurveKeyframe(time: 1, value: 1),
                            ])
                $0.appearance.colorCurve = .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 1),
                                ParticleCurveKeyframe(time: 1, value: 0),
                            ])
                $0.appearance.blendMode = .additive
                $0.renderer.renderSortPriority = 14
                $0.renderer.renderAlignment = .velocity
                $0.renderer.velocityStretchScale = 0.3
                $0.renderer.velocityStretchMax = 7
                $0.renderer.maxRenderDistance = 96
                $0.renderer.renderDistanceFadeRange = 16
                $0.renderer.renderLODStartDistance = 32
                $0.renderer.renderLODEndDistance = 128
                $0.renderer.renderLODMinParticleScale = 0.4
                $0.renderer.renderBoundsMode = .automatic
                $0.renderer.renderBoundsRadius = 28
                $0.textureSheet.textureAssetID = "Assets/Textures/smoke.png"
                $0.textureSheet.texturePath = "/tmp/particle-smoke.png"
                $0.textureSheet.columns = 3
                $0.textureSheet.rows = 2
                $0.textureSheet.frameCount = 6
                $0.textureSheet.frameRate = 15
                $0.textureSheet.playbackMode = .loop
                $0.textureSheet.startFrame = 2
                $0.textureSheet.frameRandomness = 3
                $0.trails.trailLength = 0.8
                $0.trails.trailSegments = 6
                $0.trails.trailEndSizeScale = 0.3
                $0.trails.trailEndAlphaScale = 0.15
                $0.emission.seed = 777
            }),
            for: entityID(hero.id)
        )

        let original = try #require(source.scene.component(ParticleEmitter.self, for: entityID(hero.id)))
        let manifest = source.manifest(selectedEntityID: hero.id)
        let savedParticleDoc = try #require(
            findNode(in: manifest.roots, id: hero.id)?.components.value(for: "particleEmitter")?.objectValue
        )
        func decodeEmitter(_ doc: [String: Any]) throws -> ParticleEmitter {
            var scene = SceneRuntime()
            let entity = scene.createEntity()
            var context = ComponentDecodeContext(entityMap: [0: entity])
            SceneSerializer.applyComponentDocument([ManifestComponent(type: "particleEmitter", value: ComponentValue(jsonObject: doc))], to: entity, in: &scene, context: &context)
            return try #require(scene.component(ParticleEmitter.self, for: entity))
        }
        let savedEmitter = try decodeEmitter(savedParticleDoc)
        #expect(savedEmitter.settings == original.settings)
        #expect(savedEmitter.moduleStack == original.moduleStack)

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let decodedParticleDoc = try #require(
            findNode(in: decoded.roots, id: hero.id)?.components.value(for: "particleEmitter")?.objectValue
        )
        let decodedEmitter = try decodeEmitter(decodedParticleDoc)
        #expect(decodedEmitter.settings == savedEmitter.settings)
        #expect(decodedEmitter.moduleStack == savedEmitter.moduleStack)

        let restored = EditorSceneAdapter()
        let result = restored.load(manifest: decoded)
        #expect(result.succeeded)
        let restoredID = try #require(result.selectedEntityID.map(entityID))
        let emitter = try #require(restored.scene.component(ParticleEmitter.self, for: restoredID))
        #expect(emitter.settings == original.settings)
        #expect(emitter.moduleStack == original.moduleStack)
        #expect(emitter.particles.isEmpty)
    }

    @Test("Particle emitter manifest applies authored module settings")
    func particleEmitterManifestAppliesModuleStack() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(
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

        var encodeContext = ComponentEncodeContext(entityIndexMap: [entity: 0])
        var components = SceneSerializer.componentDocument(for: entity, in: scene, context: &encodeContext)
        let index = try #require(components.firstIndex { $0.type == "particleEmitter" })
        guard case .object(var particle) = components[index].value else {
            Issue.record("Expected particle emitter document")
            return
        }
        particle["moduleStack"] = ComponentValue(jsonObject:
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(overridingEmitter.moduleStack)))
        components[index].value = .object(particle)
        let data = try JSONEncoder().encode(components)
        let decoded = try JSONDecoder().decode([ManifestComponent].self, from: data)
        var restoredScene = SceneRuntime()
        let restoredEntity = restoredScene.createEntity()
        var context = ComponentDecodeContext(entityMap: [0: restoredEntity])
        SceneSerializer.applyComponentDocument(decoded, to: restoredEntity, in: &restoredScene, context: &context)
        let emitter = try #require(restoredScene.component(ParticleEmitter.self, for: restoredEntity))

        #expect(emitter.settings.emission.emissionRate == 42)
        #expect(emitter.settings.emission.maxParticles == 256)
        #expect(emitter.settings.collision.collisionRestitution == 0.8)
        #expect(emitter.settings.textureSheet.columns == 4)
        #expect(emitter.settings.textureSheet.rows == 2)
        #expect(emitter.settings.textureSheet.frameCount == 7)
        #expect(emitter.settings.textureSheet.playbackMode == .singleFrame)
        #expect(emitter.settings.textureSheet.startFrame == 3)
        #expect(emitter.settings.textureSheet.frameRandomness == 2)
        #expect(emitter.settings.gpuSimulation.workgroupSize == 128)
    }

    @Test("Resetting preview scene publishes a new revision")
    func resetPreviewScenePublishesRevision() {
        let scene = EditorSceneAdapter()
        var revisions: [UInt64] = []
        scene.onRevisionChanged = { revisions.append($0) }

        scene.resetToPreviewScene()

        #expect(revisions == [scene.revision])
        #expect(scene.defaultSelectionID != nil)
    }

    @Test("tickScene drives AnimationRuntime and writes a non-empty joint palette for skinned entity")
    func currentJointPaletteMapReturnsPaletteAfterTick() {
        let meshIndex = 9001
        AssetRegistry.shared.registerForTesting(Self.makeAnimatedMesh(), at: meshIndex)
        defer { AssetRegistry.shared.unregisterTestingMesh(at: meshIndex) }

        let adapter = EditorSceneAdapter()
        let entity = adapter.scene.createEntity()
        _ = adapter.scene.setComponent(AnimationPlayer(isPlaying: true), for: entity)
        _ = adapter.scene.setComponent(
            AssetReferenceComponent(
                assetID: "test:\(meshIndex)",
                name: "test",
                relativePath: "test.gltf",
                absolutePath: "/test.gltf",
                kind: "gltf",
                meshIndex: meshIndex
            ),
            for: entity
        )

        adapter.tickScene(deltaTime: 0.1)

        let palette = adapter.currentJointPaletteMap()
        #expect(palette.palette(for: entity) != nil)
        #expect(palette.palette(for: entity)?.matrices.isEmpty == false)
    }

    private static func makeAnimatedMesh() -> MeshAsset {
        let sampler = MeshAnimationSampler(
            inputTimes: [0, 1.0],
            outputValues: [SIMD4<Float>(0, 0, 0, 0), SIMD4<Float>(1, 0, 0, 0)]
        )
        let channel = MeshAnimationChannel(samplerIndex: 0, targetNodeIndex: 0, path: .translation)
        let clip = MeshAnimation(name: "walk", samplers: [sampler], channels: [channel])
        return MeshAsset(
            name: "test_skinned",
            vertices: [],
            indices: [],
            nodes: [MeshNode(name: "root")],
            skins: [MeshSkin(jointNodeIndices: [0], inverseBindMatrices: [matrix_identity_float4x4])],
            animations: [clip]
        )
    }

    @Test("Spawning imported mesh attaches registered mesh collider bounds")
    func spawningImportedMeshAttachesRegisteredMeshColliderBounds() {
        let registry = MeshBoundsRegistry.shared
        registry.clearAll()
        defer { registry.clearAll() }

        let localMin = SIMD3<Float>(-2, -1, -0.25)
        let localMax = SIMD3<Float>(2, 1, 0.25)
        registry.register(meshIndex: 42, min: localMin, max: localMax)

        let scene = EditorSceneAdapter()
        let asset = EditorAsset(
            id: "wide-mesh",
            name: "Wide Mesh",
            relativePath: "Meshes/Wide.obj",
            absolutePath: "/tmp/Meshes/Wide.obj",
            kind: .obj,
            meshIndex: 42
        )

        guard let rawID = scene.spawnEntity(from: asset, at: SIMD3<Float>(10, 0, 0)) else {
            Issue.record("Expected imported mesh spawn to create an entity")
            return
        }
        let entity = entityID(rawID)

        guard let collider = scene.scene.component(Collider.self, for: entity) else {
            Issue.record("Expected imported mesh spawn to attach a mesh collider")
            return
        }

        switch collider.shape {
        case let .mesh(resourceID, center):
            #expect(resourceID == "meshIndex:42")
            #expect(center == .zero)
        default:
            Issue.record("Expected imported mesh collider shape")
        }

        let resource = scene.scene.resource(MeshColliderBoundsResource.self)
        #expect(resource?.bounds(for: "meshIndex:42")?.min == localMin)
        #expect(resource?.bounds(for: "meshIndex:42")?.max == localMax)

        let hit = scene.scene.raycast(
            SceneRaycastQuery(
                origin: SIMD3<Float>(6, 0, 0),
                direction: SIMD3<Float>(1, 0, 0),
                maxDistance: 100,
                includeTriggers: true
            )
        )
        #expect(hit?.entity == entity)
        #expect(hit?.distance == 2)
    }
}

@Suite("Editor scene edit history")
struct EditorSceneEditHistoryTests {
    @Test("human transform edits undo and redo through the adapter history")
    func transformUndoRedo() throws {
        let adapter = EditorSceneAdapter()
        let entityID = try #require(adapter.defaultSelectionID)
        let original = try #require(adapter.entityLocalTranslation(entityID))
        let edited = original + SIMD3<Float>(1, 2, 3)

        adapter.setEntityLocalTranslation(entityID, to: edited)
        #expect(adapter.canUndoEdit)
        #expect(adapter.entityLocalTranslation(entityID) == edited)

        #expect(adapter.undoEdit())
        #expect(adapter.entityLocalTranslation(entityID) == original)
        #expect(adapter.canRedoEdit)

        #expect(adapter.redoEdit())
        #expect(adapter.entityLocalTranslation(entityID) == edited)
    }

    @Test("loading a document starts a fresh edit history")
    func loadResetsHistory() throws {
        let adapter = EditorSceneAdapter()
        let entityID = try #require(adapter.defaultSelectionID)
        let original = try #require(adapter.entityLocalTranslation(entityID))
        adapter.setEntityLocalTranslation(entityID, to: original + SIMD3<Float>(1, 0, 0))
        #expect(adapter.canUndoEdit)

        _ = adapter.load(manifest: adapter.manifest())
        #expect(!adapter.canUndoEdit)
        #expect(!adapter.canRedoEdit)
    }

    @Test("hierarchy visibility updates render state and participates in undo")
    func visibilityUndo() throws {
        let adapter = EditorSceneAdapter()
        let entity = try #require(adapter.scene.entities(with: RenderMeshComponent.self).first)
        #expect(adapter.isHierarchyVisible(entity.rawValue))

        #expect(adapter.setHierarchyVisibility(false, for: [entity.rawValue]))
        #expect(!adapter.isHierarchyVisible(entity.rawValue))

        #expect(adapter.undoEdit())
        #expect(adapter.isHierarchyVisible(entity.rawValue))
    }

    @Test("imported entity setup is a single undo step")
    func groupedSpawnUndo() throws {
        let adapter = EditorSceneAdapter()
        let originalCount = adapter.entityCount
        let asset = EditorAsset(id: "models/crate.glb", name: "Crate",
                                relativePath: "models/crate.glb",
                                absolutePath: "/tmp/crate.glb", kind: .glb, meshIndex: 2)

        #expect(adapter.spawnEntity(from: asset) != nil)
        #expect(adapter.entityCount == originalCount + 1)

        #expect(adapter.undoEdit())
        #expect(adapter.entityCount == originalCount)
        #expect(!adapter.canUndoEdit)
    }

    @Test("grouped multi-asset spawn arranges and undoes the selection as one step")
    func groupedMultiAssetSpawnUndo() throws {
        let adapter = EditorSceneAdapter()
        let originalCount = adapter.entityCount
        let assets = [
            EditorAsset(id: "models/crate.glb", name: "Crate",
                        relativePath: "models/crate.glb",
                        absolutePath: "/tmp/crate.glb", kind: .glb, meshIndex: 2),
            EditorAsset(id: "models/barrel.obj", name: "Barrel",
                        relativePath: "models/barrel.obj",
                        absolutePath: "/tmp/barrel.obj", kind: .obj, meshIndex: 3),
            EditorAsset(id: "models/rock.glb", name: "Rock",
                        relativePath: "models/rock.glb",
                        absolutePath: "/tmp/rock.glb", kind: .glb, meshIndex: 4),
        ]

        let entityIDs = try #require(adapter.spawnEntities(from: assets))
        #expect(entityIDs.count == assets.count)
        #expect(adapter.entityCount == originalCount + assets.count)
        let positions = entityIDs.compactMap { adapter.entityLocalTranslation($0) }
        #expect(positions.count == assets.count)
        #expect(simd_distance(positions[0], positions[1]) > 0.5)
        #expect(simd_distance(positions[1], positions[2]) > 0.5)
        #expect(adapter.canUndoEdit)

        #expect(adapter.undoEdit())
        #expect(adapter.entityCount == originalCount)
        #expect(!adapter.canUndoEdit)

        #expect(adapter.spawnEntities(from: [assets[0], EditorAsset(
            id: "textures/wood.png", name: "Wood",
            relativePath: "textures/wood.png", absolutePath: "/tmp/wood.png",
            kind: .png, meshIndex: 0
        )]) == nil)
        #expect(adapter.entityCount == originalCount)
        adapter.setAuthoringEnabled(false)
        #expect(adapter.spawnEntities(from: assets) == nil)
        #expect(adapter.entityCount == originalCount)
        #expect(!adapter.canUndoEdit)
    }

    @Test("locked entities reject authored edits")
    func lockedEntityRejectsEdit() throws {
        let adapter = EditorSceneAdapter()
        let entityID = try #require(adapter.defaultSelectionID)
        let original = try #require(adapter.entityLocalTranslation(entityID))
        var reportedError: String?
        adapter.onTransactionError = { reportedError = $0 }
        adapter.setEntityLocked(true, entityIDs: [entityID])

        adapter.setEntityLocalTranslation(entityID, to: original + SIMD3<Float>(1, 0, 0))

        #expect(adapter.entityLocalTranslation(entityID) == original)
        #expect(reportedError?.contains("locked") == true)
        #expect(adapter.canUndoEdit)
        #expect(adapter.undoEdit())
        #expect(!adapter.isEntityLocked(entityID))
    }

    @Test("multi-entity deletion is atomic and uses one undo step")
    func multiEntityDeletionIsAtomic() throws {
        let adapter = EditorSceneAdapter()
        let entityIDs = Set(adapter.roots.prefix(2).map(\.id))
        let originalCount = adapter.entityCount
        #expect(entityIDs.count == 2)

        #expect(adapter.deleteEntities(entityIDs))
        #expect(adapter.entityCount == originalCount - 2)
        #expect(entityIDs.allSatisfy { adapter.entitySummary(id: $0) == nil })

        #expect(adapter.undoEdit())
        #expect(adapter.entityCount == originalCount)
        #expect(entityIDs.allSatisfy { adapter.entitySummary(id: $0) != nil })
        #expect(!adapter.canUndoEdit)
    }

    @Test("multi-entity deletion fails as a unit when one entity is locked")
    func multiEntityDeletionHonorsLocksAtomically() throws {
        let adapter = EditorSceneAdapter()
        let entityIDs = Set(adapter.roots.prefix(2).map(\.id))
        let lockedID = try #require(entityIDs.first)
        let originalCount = adapter.entityCount
        var reportedError: String?
        adapter.onTransactionError = { reportedError = $0 }
        adapter.setEntityLocked(true, entityIDs: [lockedID])

        #expect(!adapter.deleteEntities(entityIDs))
        #expect(adapter.entityCount == originalCount)
        #expect(entityIDs.allSatisfy { adapter.entitySummary(id: $0) != nil })
        #expect(reportedError?.contains("locked") == true)
    }

    @Test("multi-entity deletion rejects stale selections instead of partially deleting")
    func multiEntityDeletionRejectsStaleSelections() throws {
        let adapter = EditorSceneAdapter()
        let validID = try #require(adapter.roots.first?.id)
        let originalCount = adapter.entityCount

        #expect(!adapter.deleteEntities([validID, UInt64.max]))
        #expect(adapter.entityCount == originalCount)
        #expect(adapter.entitySummary(id: validID) != nil)
        #expect(!adapter.canUndoEdit)
    }

    @Test("deleting an ancestor and its selected descendant is a single valid transaction")
    func multiEntityDeletionCollapsesSelectedDescendants() throws {
        let adapter = EditorSceneAdapter()
        let parentID = try #require(adapter.spawnEntity(template: .empty))
        let childID = try #require(adapter.spawnEntity(template: .empty,
                                                       parentID: parentID))
        let populatedCount = adapter.entityCount

        #expect(adapter.deleteEntities([parentID, childID]))
        #expect(adapter.entityCount == populatedCount - 2)
        #expect(adapter.entitySummary(id: parentID) == nil)
        #expect(adapter.entitySummary(id: childID) == nil)

        #expect(adapter.undoEdit())
        #expect(adapter.entitySummary(id: parentID) != nil)
        #expect(adapter.entitySummary(id: childID) != nil)
        #expect(adapter.entityHasAncestor(childID, in: [parentID]))
    }

    @Test("hierarchy rename trims input, rejects empty names, and is undoable")
    func hierarchyRenameIsValidatedAndUndoable() throws {
        let adapter = EditorSceneAdapter()
        let entityID = try #require(adapter.defaultSelectionID)
        let originalName = try #require(adapter.entitySummary(id: entityID)?.name)

        #expect(!adapter.renameEntity(entityID, to: "   \n"))
        #expect(adapter.entitySummary(id: entityID)?.name == originalName)
        #expect(!adapter.canUndoEdit)

        #expect(adapter.renameEntity(entityID, to: "  Production Camera  "))
        #expect(adapter.entitySummary(id: entityID)?.name == "Production Camera")
        #expect(adapter.undoEdit())
        #expect(adapter.entitySummary(id: entityID)?.name == originalName)
        #expect(!adapter.canUndoEdit)
    }

    @Test("multi-entity duplication is atomic and uses one undo step")
    func multiEntityDuplicationIsAtomic() throws {
        let adapter = EditorSceneAdapter()
        let sourceIDs = Set(adapter.roots.prefix(2).map(\.id))
        let originalCount = adapter.entityCount
        #expect(sourceIDs.count == 2)

        let duplicatedIDs = try #require(adapter.duplicateEntities(sourceIDs))
        #expect(duplicatedIDs.count == 2)
        #expect(adapter.entityCount == originalCount + 2)
        #expect(duplicatedIDs.allSatisfy { adapter.entitySummary(id: $0) != nil })

        #expect(adapter.undoEdit())
        #expect(adapter.entityCount == originalCount)
        #expect(duplicatedIDs.allSatisfy { adapter.entitySummary(id: $0) == nil })
        #expect(!adapter.canUndoEdit)
    }

    @Test("multi-entity duplication rejects a locked member as a unit")
    func multiEntityDuplicationHonorsLocksAtomically() throws {
        let adapter = EditorSceneAdapter()
        let sourceIDs = Set(adapter.roots.prefix(2).map(\.id))
        let lockedID = try #require(sourceIDs.first)
        let originalCount = adapter.entityCount
        adapter.setEntityLocked(true, entityIDs: [lockedID])

        #expect(adapter.duplicateEntities(sourceIDs) == nil)
        #expect(adapter.entityCount == originalCount)
    }

    @Test("moving a nested multi-selection to root preserves descendants and is one undo step")
    func multiEntityMoveToRootIsAtomic() throws {
        let adapter = EditorSceneAdapter()
        let grandparentID = try #require(adapter.spawnEntity(template: .empty))
        let parentID = try #require(adapter.spawnEntity(template: .empty,
                                                        parentID: grandparentID))
        let childID = try #require(adapter.spawnEntity(template: .empty,
                                                       parentID: parentID))

        #expect(adapter.moveEntitiesToRoot([parentID, childID]))
        #expect(adapter.roots.contains { $0.id == parentID })
        #expect(!adapter.roots.contains { $0.id == childID })
        #expect(adapter.entityHasAncestor(childID, in: [parentID]))

        #expect(adapter.undoEdit())
        #expect(adapter.entityHasAncestor(parentID, in: [grandparentID]))
        #expect(adapter.entityHasAncestor(childID, in: [parentID]))
    }

    @Test("moving a root selected with its descendant does not detach the descendant")
    func moveToRootCollapsesSelectedDescendantsBeforeFiltering() throws {
        let adapter = EditorSceneAdapter()
        let rootID = try #require(adapter.spawnEntity(template: .empty))
        let childID = try #require(adapter.spawnEntity(template: .empty,
                                                       parentID: rootID))

        #expect(!adapter.moveEntitiesToRoot([rootID, childID]))
        #expect(adapter.entityHasAncestor(childID, in: [rootID]))
    }

    @Test("moving a multi-selection to root preserves the hierarchy's visible order")
    func moveToRootPreservesSiblingOrder() throws {
        let adapter = EditorSceneAdapter()
        let parentID = try #require(adapter.spawnEntity(template: .empty))
        let firstID = try #require(adapter.spawnEntity(template: .empty,
                                                       parentID: parentID))
        let secondID = try #require(adapter.spawnEntity(template: .empty,
                                                        parentID: parentID))

        #expect(adapter.moveEntity(secondID, to: parentID, at: 0) != nil)
        let siblingOrder = try #require(adapter.roots.first(where: { $0.id == parentID }))
            .children.map(\.id)
        #expect(siblingOrder == [secondID, firstID])

        #expect(adapter.moveEntitiesToRoot([firstID, secondID]))
        let rootOrder = adapter.roots.map(\.id)
        #expect(Array(rootOrder.suffix(2)) == [secondID, firstID])

        #expect(adapter.undoEdit())
        let restoredChildren = try #require(adapter.roots.first(where: { $0.id == parentID }))
            .children.map(\.id)
        #expect(restoredChildren == [secondID, firstID])
    }

    @Test("hierarchy locks round-trip and remap entity identifiers")
    func lockedEntityRoundTrip() throws {
        let adapter = EditorSceneAdapter()
        let originalID = try #require(adapter.defaultSelectionID)
        adapter.setEntityLocked(true, entityIDs: [originalID])

        let data = try JSONEncoder().encode(adapter.manifest(selectedEntityID: originalID))
        let manifest = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        #expect(manifest.lockedEntityIDs == [originalID])

        let restored = EditorSceneAdapter()
        let result = restored.load(manifest: manifest, notify: false)
        let remappedID = try #require(result.selectedEntityID)
        #expect(restored.isEntityLocked(remappedID))
    }

    @Test("hierarchy lock changes participate in one-step undo and redo")
    func hierarchyLockUndoRedo() throws {
        let adapter = EditorSceneAdapter()
        let entityID = try #require(adapter.defaultSelectionID)

        adapter.setEntityLocked(true, entityIDs: [entityID])
        #expect(adapter.isEntityLocked(entityID))
        #expect(adapter.canUndoEdit)
        #expect(adapter.undoEdit())
        #expect(!adapter.isEntityLocked(entityID))
        #expect(adapter.canRedoEdit)
        #expect(adapter.redoEdit())
        #expect(adapter.isEntityLocked(entityID))
    }

    @Test("interactive transform updates coalesce into one undo entry")
    func interactiveTransformsCoalesceForUndo() throws {
        let adapter = EditorSceneAdapter()
        let entityID = try #require(adapter.defaultSelectionID)
        let original = try #require(adapter.entityLocalTranslation(entityID))

        adapter.beginInteractiveEditHistoryGroup()
        for x in 1...5 {
            var matrix = try #require(adapter.entityLocalMatrix(entityID))
            matrix.columns.3.x = original.x + Float(x)
            #expect(adapter.setEntityLocalMatrices([entityID: matrix]))
        }
        #expect(!adapter.canUndoEdit)
        adapter.endInteractiveEditHistoryGroup()

        #expect(adapter.canUndoEdit)
        #expect(adapter.undoEdit())
        #expect(adapter.entityLocalTranslation(entityID) == original)
        #expect(!adapter.canUndoEdit)
    }

    @Test("cancelling an interactive transform restores its starting scene without history")
    func interactiveTransformCancellationRestoresStart() throws {
        let adapter = EditorSceneAdapter()
        let entityID = try #require(adapter.defaultSelectionID)
        let original = try #require(adapter.entityLocalTranslation(entityID))
        var revisionNotifications = 0
        adapter.onRevisionChanged = { _ in revisionNotifications += 1 }

        adapter.beginInteractiveEditHistoryGroup()
        var matrix = try #require(adapter.entityLocalMatrix(entityID))
        matrix.columns.3.x = original.x + 12
        #expect(adapter.setEntityLocalMatrices([entityID: matrix]))

        adapter.cancelInteractiveEditHistoryGroup()
        adapter.endInteractiveEditHistoryGroup() // late pointer-up is harmless

        #expect(adapter.entityLocalTranslation(entityID) == original)
        #expect(!adapter.canUndoEdit)
        #expect(revisionNotifications >= 2) // live edit plus restored scene
    }

    @Test("multi-entity transforms reject locked members atomically")
    func multiEntityTransformsHonorLocksAtomically() throws {
        let adapter = EditorSceneAdapter()
        let ids = adapter.roots.prefix(2).map(\.id)
        #expect(ids.count == 2)
        let firstID = try #require(ids.first)
        let secondID = try #require(ids.last)
        let firstOriginal = try #require(adapter.entityLocalMatrix(firstID))
        let secondOriginal = try #require(adapter.entityLocalMatrix(secondID))
        adapter.setEntityLocked(true, entityIDs: [secondID])
        var firstNext = firstOriginal
        var secondNext = secondOriginal
        firstNext.columns.3.x += 3
        secondNext.columns.3.x += 3

        #expect(!adapter.setEntityLocalMatrices([
            firstID: firstNext,
            secondID: secondNext,
        ]))
        #expect(adapter.entityLocalMatrix(firstID)?.columns.3 == firstOriginal.columns.3)
        #expect(adapter.entityLocalMatrix(secondID)?.columns.3 == secondOriginal.columns.3)
    }
}

@Suite("GameSaveDocument")
struct GameSaveDocumentTests {
    @Test("AudioSource round-trips through manifest encode/decode")
    func audioSourceRoundTrip() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "SFX"), for: entity)
        _ = scene.setComponent(SceneKindComponent(value: "Audio"), for: entity)
        _ = scene.setLocalTransform(.identity, for: entity)
        let src = AudioSource(clipName: "explosion", volume: 0.8, pitch: 1.2,
                              loop: true, playOnAwake: false, spatialBlend: 0.5)
        _ = scene.setComponent(src, for: entity)

        let adapter = EditorSceneAdapter()
        adapter.scene = scene
        let manifest = adapter.manifest()

        var adapter2 = EditorSceneAdapter()
        _ = adapter2.load(manifest: manifest, notify: false)
        let restored = adapter2.scene.component(AudioSource.self,
                                                for: adapter2.scene.entities().first!)
        #expect(restored?.clipName == "explosion")
        #expect(restored?.volume == 0.8)
        #expect(restored?.loop == true)
        #expect(restored?.playOnAwake == false)
    }

    @Test("AudioListener round-trips through manifest encode/decode")
    func audioListenerRoundTrip() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Listener"), for: entity)
        _ = scene.setComponent(SceneKindComponent(value: "Audio Listener"), for: entity)
        _ = scene.setLocalTransform(.identity, for: entity)
        _ = scene.setComponent(AudioListener(masterVolume: 0.35), for: entity)

        let adapter = EditorSceneAdapter()
        adapter.scene = scene
        let encoded = try JSONEncoder().encode(adapter.manifest())
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: encoded)

        let restoredAdapter = EditorSceneAdapter()
        _ = restoredAdapter.load(manifest: decoded, notify: false)
        let restoredEntity = try #require(restoredAdapter.scene.entities().first)
        let restored = restoredAdapter.scene.component(AudioListener.self, for: restoredEntity)
        #expect(restored?.masterVolume == 0.35)
    }

    @Test("AnimationPlayer round-trips through manifest encode/decode")
    func animationPlayerRoundTrip() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Hero"), for: entity)
        _ = scene.setComponent(SceneKindComponent(value: "Character"), for: entity)
        _ = scene.setLocalTransform(.identity, for: entity)
        let player = AnimationPlayer(clipName: "run", speed: 1.5,
                                     loop: true, isPlaying: true, time: 3.14)
        _ = scene.setComponent(player, for: entity)

        var adapter = EditorSceneAdapter()
        adapter.scene = scene
        let manifest = adapter.manifest()

        var adapter2 = EditorSceneAdapter()
        _ = adapter2.load(manifest: manifest, notify: false)
        let restored = adapter2.scene.component(AnimationPlayer.self,
                                                for: adapter2.scene.entities().first!)
        #expect(restored?.clipName == "run")
        #expect(restored?.speed == 1.5)
        #expect(restored?.time == 3.14)
        #expect(restored?.isPlaying == true)
    }

    @Test("AnimationGraphPlayer round-trips through manifest encode/decode")
    func animationGraphPlayerRoundTrip() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Hero"), for: entity)
        _ = scene.setComponent(SceneKindComponent(value: "Character"), for: entity)
        _ = scene.setLocalTransform(.identity, for: entity)
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
                    AnimationState(name: "Run", motion: .blendSpace1D("locomotion")),
                ],
                transitions: [
                    AnimationTransition(from: "Idle",
                                        to: "Run",
                                        parameter: "speed",
                                        comparison: .greaterThan,
                                        threshold: 0.5,
                                        duration: 0.25),
                ]
            )
        )
        _ = scene.setComponent(
            AnimationGraphPlayer(graph: graph,
                                 parameters: ["speed": 0.8],
                                 activeState: "Run",
                                 previousState: "Idle"),
            for: entity
        )

        var adapter = EditorSceneAdapter()
        adapter.scene = scene
        let manifest = adapter.manifest()

        var adapter2 = EditorSceneAdapter()
        _ = adapter2.load(manifest: manifest, notify: false)
        let restored = adapter2.scene.component(AnimationGraphPlayer.self,
                                                for: adapter2.scene.entities().first!)
        #expect(restored?.graph.blendSpaces1D.first?.name == "locomotion")
        #expect(restored?.graph.stateMachine.transitions.first?.duration == 0.25)
        #expect(restored?.parameters["speed"] == 0.8)
        #expect(restored?.activeState == "Run")
        #expect(restored?.previousState == "Idle")
    }

    @Test("new manifests use the current schema version")
    func currentSchemaVersion() {
        let adapter = EditorSceneAdapter()
        let manifest = adapter.manifest()
        #expect(manifest.schemaVersion == EditorSceneManifest.currentSchemaVersion)
    }

    @Test("GameSaveDocument write and read round-trip")
    func gameSaveDocumentWriteRead() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let adapter = EditorSceneAdapter()
        let manifest = adapter.manifest()
        let doc = GameSaveDocument(slot: 0, manifest: manifest)
        let url = GameSaveDocument.url(slot: 0, projectDirectory: tmp.path)
        try doc.write(to: url)

        let loaded = try GameSaveDocument.read(from: url)
        #expect(loaded?.slot == 0)
        #expect(loaded?.manifest == manifest)
    }

    @Test("GameSaveDocument.read returns nil for missing file")
    func gameSaveReadMissingReturnsNil() throws {
        let url = GameSaveDocument.url(slot: 99, projectDirectory: "/tmp/nonexistent-\(UUID().uuidString)")
        let result = try GameSaveDocument.read(from: url)
        #expect(result == nil)
    }
}

private func flatten(_ nodes: [EditorSceneNode]) -> [EditorSceneNode] {
    nodes.flatMap { [$0] + flatten($0.children) }
}

private func findNode(in nodes: [EditorSceneManifestNode], id: UInt64) -> EditorSceneManifestNode? {
    for node in nodes {
        if node.id == id {
            return node
        }
        if let found = findNode(in: node.children, id: id) {
            return found
        }
    }
    return nil
}

private func translationMatrix(_ value: SIMD3<Float>) -> simd_float4x4 {
    var matrix = matrix_identity_float4x4
    matrix.columns.3 = SIMD4<Float>(value, 1)
    return matrix
}

private func entityID(_ rawValue: UInt64) -> EntityID {
    EntityID(index: UInt32(rawValue & 0xFFFF_FFFF),
             generation: UInt32(rawValue >> 32))
}
