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

        #expect(manifest.schemaVersion == 4)
        #expect(manifest.revision == scene.revision)
        #expect(manifest.entityCount == scene.entityCount)
        #expect(manifest.selectedEntityID == scene.defaultSelectionID)
        #expect(!manifest.roots.isEmpty)
        #expect(manifest.roots.contains { $0.name == "Main Camera" })
        #expect(manifest.roots.contains { $0.camera != nil })
    }

    @Test("Preview scene reports active particles so the viewport keeps driving frames")
    func previewSceneHasActiveParticles() {
        let scene = EditorSceneAdapter()
        // The preview scene seeds an always-emitting "Sparks" emitter; under the
        // event-driven frame policy this is what keeps the viewport rendering so
        // particles animate instead of freezing.
        #expect(scene.hasActiveParticles())
    }

    @Test("Editor scene adapter exposes particle frame stats after ticking")
    func editorSceneAdapterExposesParticleFrameStats() {
        let adapter = EditorSceneAdapter()
        let entity = adapter.scene.createEntity()
        _ = adapter.scene.setComponent(
            ParticleEmitter(emissionRate: 10,
                            maxParticles: 100,
                            lifetime: 100,
                            gravity: .zero),
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

    @Test("Editor scene adapter exposes selected particle GPU simulation plan")
    func editorSceneAdapterExposesSelectedParticleGPUPlan() throws {
        let adapter = EditorSceneAdapter()
        let entity = adapter.scene.createEntity()
        var emitter = ParticleEmitter(emissionRate: 10,
                                      maxParticles: 128,
                                      lifetime: 1,
                                      gravity: .zero)
        emitter.distanceEmissionRate = 4
        emitter.simulationBackend = .gpuRequired
        emitter.gpuSimulationWorkgroupSize = 32
        _ = adapter.scene.setComponent(emitter, for: entity)

        let plan = try #require(adapter.currentParticleGPUSimulationPlan(for: entity.rawValue))

        #expect(plan.status == .requiredButUnsupported)
        #expect(plan.dispatchWorkgroups == 4)
        #expect(plan.workgroupSize == 32)
        #expect(plan.unsupportedReasons == [.distanceEmission])
        #expect(adapter.currentParticleGPUSimulationPlan(for: nil) == nil)

        let issues = adapter.currentParticleModuleValidationIssues(for: entity.rawValue)
        #expect(issues.contains {
            $0.moduleID == "gpuSimulation" && $0.code == "gpuRequiredButUnsupported"
        })
        #expect(adapter.currentParticleModuleValidationIssues(for: nil).isEmpty)
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
        #expect(findNode(in: manifest.roots, id: cameraNode.id)?.camera?.aspectRatio == 1.777)

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let restored = EditorSceneAdapter()
        _ = restored.load(manifest: decoded)
        let restoredID = try #require(flatten(restored.roots).first { $0.name == "Main Camera" }?.id)
        #expect(restored.scene.component(CameraComponent.self, for: entityID(restoredID))?.aspectRatio == 1.777)
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

        #expect(manifestHero?.renderMesh?.meshIndex == 12)
        #expect(manifestHero?.renderMesh?.assetID == "hero.asset")
        #expect(manifestHero?.renderMesh?.colorTint?.simdValue == SIMD3<Float>(0.4, 0.5, 0.6))
        #expect(manifestHero?.renderMaterial?.baseColorFactor.simdValue == SIMD4<Float>(0.8, 0.7, 0.6, 0.9))
        #expect(manifestHero?.renderMaterial?.baseColorTextureIndex == 2)
        #expect(manifestHero?.renderMaterial?.normalTextureIndex == 4)

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
            ParticleEmitter(looping: false, duration: 3.25,
                            prewarmTime: 0.75,
                            prewarmStep: 0.04,
                            emissionRate: 24,
                            emissionRateCurve: .constant(1.25),
                            distanceEmissionRate: 9,
                            distanceEmissionRateCurve: .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 0),
                                ParticleCurveKeyframe(time: 1, value: 2),
                            ]),
                            burstCount: 5, burstInterval: 0.4,
                            maxParticles: 64,
                            maxRenderedParticles: 32,
                            lifetime: 1.25,
                            subEmitterTrigger: .death,
                            subEmitterBurstCount: 4,
                            subEmitterProbability: 0.8,
                            subEmitterMaxDepth: 2,
                            subEmitterInheritVelocity: 0.45,
                            subEmitterLifetime: 0.6,
                            subEmitterStartVelocity: SIMD3<Float>(1, 2, 3),
                            subEmitterVelocityRandomness: SIMD3<Float>(0.2, 0.3, 0.4),
                            subEmitterStartSize: 0.22,
                            subEmitterEndSize: 0.06,
                            subEmitterStartColor: SIMD4<Float>(1, 0.5, 0.25, 1),
                            subEmitterEndColor: SIMD4<Float>(1, 0.1, 0, 0),
                            subEmitters: subEmitters,
                            spawnRadius: 0.3, emissionShape: .box,
                            boxHalfExtents: SIMD3<Float>(1, 2, 3),
                            coneRadius: 0.8, coneHeight: 3.5,
                            startVelocity: SIMD3<Float>(0, 2, 0),
                            velocityInheritance: 0.35,
                            gravity: SIMD3<Float>(0, -3, 0),
                            noiseStrength: 1.5, noiseScale: 2.25, noiseSpeed: 0.5,
                            forceMode: .radial,
                            forceCenter: SIMD3<Float>(1, 2, 3),
                            forceAxis: SIMD3<Float>(0, 1, 0),
                            forceRadius: 8,
                            forceStrength: -2.5,
                            forceFalloff: 1.5,
                            vectorFieldMode: .curl,
                            vectorFieldDirection: SIMD3<Float>(0, 0, 1),
                            vectorFieldStrength: 3.75,
                            vectorFieldScale: 1.5,
                            vectorFieldScrollSpeed: 0.25,
                            collisionMode: .worldPlane, simulationSpace: .world,
                            simulationBackend: .gpuIfSupported,
                            gpuSimulationWorkgroupSize: 128,
                            collisionPlaneY: -0.5,
                            collisionRestitution: 0.6, collisionDamping: 0.15,
                            startSize: 0.4, endSize: 0.05,
                            sizeRandomness: 0.45,
                            startRotation: 0.2,
                            rotationRandomness: 0.4,
                            angularVelocity: 1.2,
                            angularVelocityRandomness: 0.6,
                            sizeCurve: .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 0),
                                ParticleCurveKeyframe(time: 1, value: 1),
                            ]),
                            colorCurve: .keyframes([
                                ParticleCurveKeyframe(time: 0, value: 1),
                                ParticleCurveKeyframe(time: 1, value: 0),
                            ]),
                            blendMode: .additive,
                            renderAlignment: .velocity,
                            velocityStretchScale: 0.3,
                            velocityStretchMax: 7,
                            maxRenderDistance: 96,
                            renderDistanceFadeRange: 16,
                            renderLODStartDistance: 32,
                            renderLODEndDistance: 128,
                            renderLODMinParticleScale: 0.4,
                            renderBoundsMode: .automatic,
                            renderBoundsRadius: 28,
                            textureAssetID: "Assets/Textures/smoke.png",
                            texturePath: "/tmp/particle-smoke.png",
                            textureSheetColumns: 3,
                            textureSheetRows: 2,
                            textureSheetFrameCount: 6,
                            textureSheetFrameRate: 15,
                            textureSheetPlaybackMode: .loop,
                            textureSheetStartFrame: 2,
                            textureSheetFrameRandomness: 3,
                            trailLength: 0.8,
                            trailSegments: 6,
                            trailEndSizeScale: 0.3,
                            trailEndAlphaScale: 0.15,
            seed: 777),
            for: entityID(hero.id)
        )

        let manifest = source.manifest(selectedEntityID: hero.id)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.prewarmTime == 0.75)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.prewarmStep == 0.04)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.emissionRate == 24)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.maxRenderedParticles == 32)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.emissionRateCurve == .constant(1.25))
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.distanceEmissionRate == 9)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.distanceEmissionRateCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 1, value: 2),
        ]))
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.subEmitterTrigger == .death)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.subEmitterBurstCount == 4)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.subEmitterProbability == 0.8)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.subEmitterMaxDepth == 2)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.subEmitterLifetime == 0.6)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.subEmitters.map(\.component) == subEmitters)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.forceMode == .radial)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.forceCenter.simdValue == SIMD3<Float>(1, 2, 3))
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.forceAxis.simdValue == SIMD3<Float>(0, 1, 0))
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.forceRadius == 8)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.forceStrength == -2.5)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.forceFalloff == 1.5)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.vectorFieldMode == .curl)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.vectorFieldDirection.simdValue == SIMD3<Float>(0, 0, 1))
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.vectorFieldStrength == 3.75)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.vectorFieldScale == 1.5)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.vectorFieldScrollSpeed == 0.25)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.simulationBackend == .gpuIfSupported)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.gpuSimulationWorkgroupSize == 128)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.maxRenderDistance == 96)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.renderDistanceFadeRange == 16)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.renderLODStartDistance == 32)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.renderLODEndDistance == 128)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.renderLODMinParticleScale == 0.4)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.renderBoundsMode == .automatic)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.renderBoundsRadius == 28)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.textureSheetFrameCount == 6)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.textureSheetPlaybackMode == .loop)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.textureSheetStartFrame == 2)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.textureSheetFrameRandomness == 3)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.trailSegments == 6)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.moduleStack?.version
                == ParticleModuleStack.currentVersion)
        #expect(findNode(in: manifest.roots, id: hero.id)?.particleEmitter?.moduleStack?.modules.map(\.id) == [
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

        // Survive a full Codable cycle (mirrors how saves persist the manifest).
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        #expect(findNode(in: decoded.roots, id: hero.id)?.particleEmitter?.moduleStack?.modules.count == 11)

        let restored = EditorSceneAdapter()
        let result = restored.load(manifest: decoded)
        guard let restoredID = result.selectedEntityID.map(entityID) else {
            Issue.record("Expected restored selection")
            return
        }
        let e = restored.scene.component(ParticleEmitter.self, for: restoredID)
        #expect(e != nil)
        #expect(e!.emissionRate == 24)
        #expect(e!.emissionRateCurve == .constant(1.25))
        #expect(e!.distanceEmissionRate == 9)
        #expect(e!.distanceEmissionRateCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 1, value: 2),
        ]))
        #expect(e!.looping == false)
        #expect(e!.duration == 3.25)
        #expect(e!.prewarmTime == 0.75)
        #expect(e!.prewarmStep == 0.04)
        #expect(e!.burstCount == 5)
        #expect(e!.burstInterval == 0.4)
        #expect(e!.maxParticles == 64)
        #expect(e!.maxRenderedParticles == 32)
        #expect(e!.lifetime == 1.25)
        #expect(e!.subEmitterTrigger == .death)
        #expect(e!.subEmitterBurstCount == 4)
        #expect(e!.subEmitterProbability == 0.8)
        #expect(e!.subEmitterMaxDepth == 2)
        #expect(e!.subEmitterInheritVelocity == 0.45)
        #expect(e!.subEmitterLifetime == 0.6)
        #expect(e!.subEmitterStartVelocity == SIMD3<Float>(1, 2, 3))
        #expect(e!.subEmitterVelocityRandomness == SIMD3<Float>(0.2, 0.3, 0.4))
        #expect(e!.subEmitterStartSize == 0.22)
        #expect(e!.subEmitterEndSize == 0.06)
        #expect(e!.subEmitterStartColor == SIMD4<Float>(1, 0.5, 0.25, 1))
        #expect(e!.subEmitterEndColor == SIMD4<Float>(1, 0.1, 0, 0))
        #expect(e!.subEmitters == subEmitters)
        #expect(e!.spawnRadius == 0.3)
        #expect(e!.emissionShape == .box)
        #expect(e!.boxHalfExtents == SIMD3<Float>(1, 2, 3))
        #expect(e!.coneRadius == 0.8)
        #expect(e!.coneHeight == 3.5)
        #expect(e!.startVelocity == SIMD3<Float>(0, 2, 0))
        #expect(e!.velocityInheritance == 0.35)
        #expect(e!.noiseStrength == 1.5)
        #expect(e!.noiseScale == 2.25)
        #expect(e!.noiseSpeed == 0.5)
        #expect(e!.forceMode == .radial)
        #expect(e!.forceCenter == SIMD3<Float>(1, 2, 3))
        #expect(e!.forceAxis == SIMD3<Float>(0, 1, 0))
        #expect(e!.forceRadius == 8)
        #expect(e!.forceStrength == -2.5)
        #expect(e!.forceFalloff == 1.5)
        #expect(e!.vectorFieldMode == .curl)
        #expect(e!.vectorFieldDirection == SIMD3<Float>(0, 0, 1))
        #expect(e!.vectorFieldStrength == 3.75)
        #expect(e!.vectorFieldScale == 1.5)
        #expect(e!.vectorFieldScrollSpeed == 0.25)
        #expect(e!.simulationBackend == .gpuIfSupported)
        #expect(e!.gpuSimulationWorkgroupSize == 128)
        #expect(e!.collisionMode == .worldPlane)
        #expect(e!.simulationSpace == .world)
        #expect(e!.collisionPlaneY == -0.5)
        #expect(e!.collisionRestitution == 0.6)
        #expect(e!.collisionDamping == 0.15)
        #expect(e!.sizeRandomness == 0.45)
        #expect(e!.startRotation == 0.2)
        #expect(e!.rotationRandomness == 0.4)
        #expect(e!.angularVelocity == 1.2)
        #expect(e!.angularVelocityRandomness == 0.6)
        #expect(e!.sizeCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 1, value: 1),
        ]))
        #expect(e!.colorCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 1),
            ParticleCurveKeyframe(time: 1, value: 0),
        ]))
        #expect(e!.blendMode == .additive)
        #expect(e!.renderAlignment == .velocity)
        #expect(e!.velocityStretchScale == 0.3)
        #expect(e!.velocityStretchMax == 7)
        #expect(e!.maxRenderDistance == 96)
        #expect(e!.renderDistanceFadeRange == 16)
        #expect(e!.renderLODStartDistance == 32)
        #expect(e!.renderLODEndDistance == 128)
        #expect(e!.renderLODMinParticleScale == 0.4)
        #expect(e!.renderBoundsMode == .automatic)
        #expect(e!.renderBoundsRadius == 28)
        #expect(e!.textureAssetID == "Assets/Textures/smoke.png")
        #expect(e!.texturePath == "/tmp/particle-smoke.png")
        #expect(e!.textureSheetColumns == 3)
        #expect(e!.textureSheetRows == 2)
        #expect(e!.textureSheetFrameCount == 6)
        #expect(e!.textureSheetFrameRate == 15)
        #expect(e!.textureSheetPlaybackMode == .loop)
        #expect(e!.textureSheetStartFrame == 2)
        #expect(e!.textureSheetFrameRandomness == 3)
        #expect(e!.trailLength == 0.8)
        #expect(e!.trailSegments == 6)
        #expect(e!.trailEndSizeScale == 0.3)
        #expect(e!.trailEndAlphaScale == 0.15)
        #expect(e!.seed == 777)
    }

    @Test("Particle emitter manifest applies module stack over legacy fields")
    func particleEmitterManifestAppliesModuleStack() throws {
        let legacy = EditorSceneManifestParticleEmitter(
            ParticleEmitter(emissionRate: 1,
                            maxParticles: 4,
                            textureSheetColumns: 1,
                            textureSheetRows: 1,
                            textureSheetPlaybackMode: .automatic)
        )
        let overridingEmitter = ParticleEmitter(emissionRate: 42,
                                                maxParticles: 256,
                                                gpuSimulationWorkgroupSize: 128,
                                                collisionRestitution: 0.8,
                                                textureSheetColumns: 4,
                                                textureSheetRows: 2,
                                                textureSheetFrameCount: 7,
                                                textureSheetPlaybackMode: .singleFrame,
                                                textureSheetStartFrame: 3,
                                                textureSheetFrameRandomness: 2)

        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json["moduleStack"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(overridingEmitter.moduleStack))

        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(EditorSceneManifestParticleEmitter.self, from: data)
        let emitter = decoded.component

        #expect(emitter.emissionRate == 42)
        #expect(emitter.maxParticles == 256)
        #expect(emitter.collisionRestitution == 0.8)
        #expect(emitter.textureSheetColumns == 4)
        #expect(emitter.textureSheetRows == 2)
        #expect(emitter.textureSheetFrameCount == 7)
        #expect(emitter.textureSheetPlaybackMode == .singleFrame)
        #expect(emitter.textureSheetStartFrame == 3)
        #expect(emitter.textureSheetFrameRandomness == 2)
        #expect(emitter.gpuSimulationWorkgroupSize == 128)
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
        defer { AssetRegistry.shared.reset() }

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

        var adapter = EditorSceneAdapter()
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

    @Test("schemaVersion is 4 for new manifests")
    func schemaVersionIs4() {
        let adapter = EditorSceneAdapter()
        let manifest = adapter.manifest()
        #expect(manifest.schemaVersion == 4)
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

private func entityID(_ rawValue: UInt64) -> EntityID {
    EntityID(index: UInt32(rawValue & 0xFFFF_FFFF),
             generation: UInt32(rawValue >> 32))
}
