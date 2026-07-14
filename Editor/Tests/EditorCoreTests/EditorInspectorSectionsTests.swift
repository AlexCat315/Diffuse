@testable import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat
import Testing

@Suite("EditorInspectorSections", .serialized)
struct EditorInspectorSectionsTests {

    private func makeEntity(in adapter: EditorSceneAdapter) -> UInt64 {
        adapter.scene.createEntity().rawValue
    }

    private func field(_ adapter: EditorSceneAdapter, _ rawID: UInt64,
                       section: String, field: String) -> EditorInspectorFieldValue? {
        for s in adapter.inspectorSections(for: rawID) where s.id == section {
            for f in s.fields where f.id == field { return f.value }
        }
        return nil
    }

    private func hasSection(_ adapter: EditorSceneAdapter, _ rawID: UInt64, _ id: String) -> Bool {
        adapter.inspectorSections(for: rawID).contains { $0.id == id }
    }

    // MARK: - Camera

    @Test("camera section appears only when the entity has a camera")
    func cameraSectionPresence() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        #expect(!hasSection(adapter, id, "camera"))
        _ = adapter.addComponent(.camera, to: id)
        #expect(hasSection(adapter, id, "camera"))
    }

    @Test("camera active binding writes back to the component")
    func cameraActiveBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.camera, to: id)

        guard case let .bool(binding) = field(adapter, id, section: "camera", field: "camera-active") else {
            Issue.record("expected camera-active bool field"); return
        }
        binding.wrappedValue = true
        #expect(adapter.scene.component(CameraComponent.self, for: EntityID(rawValue: id)!)?.isActive == true)
    }

    @Test("camera FOV binding shows degrees and stores radians")
    func cameraFOVBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.camera, to: id)

        guard case let .constrainedNumber(binding, _, _, _, _) =
                field(adapter, id, section: "camera", field: "camera-fov") else {
            Issue.record("expected camera-fov number field"); return
        }
        binding.wrappedValue = 90 // degrees
        let radians = adapter.scene.component(CameraComponent.self, for: EntityID(rawValue: id)!)?.fovYRadians
        #expect(radians != nil)
        #expect(abs(radians! - .pi / 2) < 1e-4)
        // And the getter reflects it back in degrees.
        #expect(abs(binding.wrappedValue - 90) < 1e-3)
    }

    @Test("camera aspect binding writes back to the component")
    func cameraAspectBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.camera, to: id)

        guard case let .constrainedNumber(binding, _, _, _, _) =
                field(adapter, id, section: "camera", field: "camera-aspect") else {
            Issue.record("expected camera-aspect number field"); return
        }
        binding.wrappedValue = 1.777
        let aspect = adapter.scene.component(CameraComponent.self, for: EntityID(rawValue: id)!)?.aspectRatio
        #expect(aspect != nil)
        #expect(abs(aspect! - 1.777) < 1e-4)
        #expect(abs(binding.wrappedValue - 1.777) < 1e-4)
    }

    // MARK: - Jolt Physics

    @Test("physics settings inspector authors the Jolt world configuration")
    func physicsSettingsBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        #expect(hasSection(adapter, id, "physics-settings"))

        guard case let .physicsSimulationMode(mode) =
                field(adapter, id, section: "physics-settings", field: "physics-simulation-mode"),
              case let .vector3(gravityX, gravityY, gravityZ) =
                field(adapter, id, section: "physics-settings", field: "physics-gravity"),
              case let .constrainedNumber(fixedStep, _, _, _, _) =
                field(adapter, id, section: "physics-settings", field: "physics-fixed-step"),
              case let .constrainedNumber(maxSubsteps, _, _, _, _) =
                field(adapter, id, section: "physics-settings", field: "physics-max-substeps"),
              case let .constrainedNumber(collisionSteps, _, _, _, _) =
                field(adapter, id, section: "physics-settings", field: "physics-collision-steps"),
              case let .bool(allowSleep) =
                field(adapter, id, section: "physics-settings", field: "physics-allow-sleep") else {
            Issue.record("expected complete physics settings fields"); return
        }

        mode.wrappedValue = .preview
        gravityX.wrappedValue = 1
        gravityY.wrappedValue = -20
        gravityZ.wrappedValue = 2
        fixedStep.wrappedValue = 1.0 / 120.0
        maxSubsteps.wrappedValue = 8
        collisionSteps.wrappedValue = 3
        allowSleep.wrappedValue = false

        let settings = try #require(adapter.scene.resource(PhysicsSettingsResource.self))
        #expect(settings.backendKind == .jolt)
        #expect(settings.simulationMode == .preview)
        #expect(settings.gravity == SIMD3<Float>(1, -20, 2))
        #expect(abs(settings.fixedTimeStepSeconds - (1.0 / 120.0)) < 0.000_001)
        #expect(settings.maxSubstepsPerFrame == 8)
        #expect(settings.collisionSteps == 3)
        #expect(!settings.allowSleep)
    }

    @Test("rigid body inspector edits Jolt velocity damping and CCD settings")
    func rigidBodyJoltSettingsBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        let entity = try #require(EntityID(rawValue: id))
        _ = adapter.addComponent(.rigidBody, to: id)

        guard case let .vector3(linearX, linearY, linearZ) =
                field(adapter, id, section: "rigid-body", field: "linear-velocity") else {
            Issue.record("expected linear velocity field"); return
        }
        linearX.wrappedValue = 1
        linearY.wrappedValue = 2
        linearZ.wrappedValue = 3

        guard case let .vector3(angularX, angularY, angularZ) =
                field(adapter, id, section: "rigid-body", field: "angular-velocity") else {
            Issue.record("expected angular velocity field"); return
        }
        angularX.wrappedValue = 4
        angularY.wrappedValue = 5
        angularZ.wrappedValue = 6

        guard case let .constrainedNumber(linearDamping, _, _, _, _) =
                field(adapter, id, section: "rigid-body", field: "linear-damping"),
              case let .constrainedNumber(angularDamping, _, _, _, _) =
                field(adapter, id, section: "rigid-body", field: "angular-damping"),
              case let .bool(ccd) =
                field(adapter, id, section: "rigid-body", field: "continuous-collision-detection") else {
            Issue.record("expected damping and CCD fields"); return
        }
        linearDamping.wrappedValue = 0.25
        angularDamping.wrappedValue = 0.5
        ccd.wrappedValue = true

        let body = try #require(adapter.scene.component(RigidBody.self, for: entity))
        #expect(body.linearVelocity == SIMD3<Float>(1, 2, 3))
        #expect(body.angularVelocity == SIMD3<Float>(4, 5, 6))
        #expect(body.linearDamping == 0.25)
        #expect(body.angularDamping == 0.5)
        #expect(body.continuousCollisionDetection)
    }

    @Test("vehicle inspector exposes authored controls and writes them back")
    func vehicleBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        let entity = try #require(EntityID(rawValue: id))
        #expect(!hasSection(adapter, id, "vehicle"))
        #expect(adapter.addComponent(.vehicle, to: id))
        #expect(hasSection(adapter, id, "vehicle"))

        guard case let .bool(enabled) =
                field(adapter, id, section: "vehicle", field: "vehicle-enabled"),
              case let .constrainedNumber(maxTorque, _, _, _, _) =
                field(adapter, id, section: "vehicle", field: "vehicle-max-torque"),
              case let .constrainedNumber(clutchStrength, _, _, _, _) =
                field(adapter, id, section: "vehicle", field: "vehicle-clutch-strength"),
              case let .vehicleControllerKind(controllerKind) =
                field(adapter, id, section: "vehicle", field: "vehicle-controller") else {
            Issue.record("expected vehicle authored controls"); return
        }
        enabled.wrappedValue = false
        maxTorque.wrappedValue = 780
        clutchStrength.wrappedValue = 18

        let vehicle = try #require(adapter.scene.component(Vehicle.self, for: entity))
        #expect(!vehicle.isEnabled)
        #expect(vehicle.engine.maxTorque == 780)
        #expect(vehicle.transmission.clutchStrength == 18)

        controllerKind.wrappedValue = .tracked
        guard case let .constrainedNumber(trackForwardFriction, _, _, _, _) =
                field(adapter, id, section: "vehicle", field: "vehicle-track-longitudinal-friction"),
              case let .constrainedNumber(trackSideFriction, _, _, _, _) =
                field(adapter, id, section: "vehicle", field: "vehicle-track-lateral-friction") else {
            Issue.record("expected tracked vehicle controls"); return
        }
        trackForwardFriction.wrappedValue = 5
        trackSideFriction.wrappedValue = 2.5
        guard case let .tracked(tracked)? =
                adapter.scene.component(Vehicle.self, for: entity)?.controller else {
            Issue.record("expected tracked vehicle component"); return
        }
        #expect(tracked.longitudinalFriction == 5)
        #expect(tracked.lateralFriction == 2.5)

        guard case let .vehicleControllerKind(updatedControllerKind) =
                field(adapter, id, section: "vehicle", field: "vehicle-controller") else {
            Issue.record("expected updated controller selector"); return
        }
        updatedControllerKind.wrappedValue = .motorcycle
        guard case let .constrainedNumber(maxLean, _, _, _, _) =
                field(adapter, id, section: "vehicle", field: "vehicle-motorcycle-max-lean"),
              case let .bool(leanEnabled) =
                field(adapter, id, section: "vehicle", field: "vehicle-motorcycle-lean-enabled") else {
            Issue.record("expected motorcycle vehicle controls"); return
        }
        maxLean.wrappedValue = 0.6
        leanEnabled.wrappedValue = false
        guard case let .motorcycle(motorcycle)? =
                adapter.scene.component(Vehicle.self, for: entity)?.controller else {
            Issue.record("expected motorcycle vehicle component"); return
        }
        #expect(motorcycle.maxLeanAngle == 0.6)
        #expect(!motorcycle.isLeanControllerEnabled)

        #expect(adapter.removeComponent(.vehicle, from: id))
        #expect(!hasSection(adapter, id, "vehicle"))
    }

    @Test("soft-body and cloth inspector edits simulation, topology, and fixed points")
    func softBodyAndClothBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        let entity = try #require(EntityID(rawValue: id))
        #expect(adapter.addComponent(.softBody, to: id))
        #expect(adapter.addComponent(.cloth, to: id))
        #expect(hasSection(adapter, id, "soft-body"))
        #expect(hasSection(adapter, id, "cloth"))

        guard case let .bool(enabled) =
                field(adapter, id, section: "soft-body", field: "soft-body-enabled"),
              case let .bool(selfCollision) =
                field(adapter, id, section: "soft-body", field: "soft-body-self-collision"),
              case let .constrainedNumber(pressure, _, _, _, _) =
                field(adapter, id, section: "soft-body", field: "soft-body-pressure"),
              case let .constrainedNumber(iterations, _, _, _, _) =
                field(adapter, id, section: "soft-body", field: "soft-body-iterations"),
              case let .constrainedNumber(gridX, _, _, _, _) =
                field(adapter, id, section: "cloth", field: "cloth-grid-x"),
              case let .json(fixedVertices, _) =
                field(adapter, id, section: "cloth", field: "cloth-fixed-vertices"),
              case let .text(bendType) =
                field(adapter, id, section: "cloth", field: "cloth-bend-type") else {
            Issue.record("expected soft-body and cloth authored controls"); return
        }
        enabled.wrappedValue = false
        selfCollision.wrappedValue = true
        pressure.wrappedValue = 2.5
        iterations.wrappedValue = 11
        gridX.wrappedValue = 6
        fixedVertices.wrappedValue = "[0,2,5,999]"
        bendType.wrappedValue = "dihedral"

        let softBody = try #require(adapter.scene.component(SoftBody.self, for: entity))
        let cloth = try #require(adapter.scene.component(Cloth.self, for: entity))
        #expect(!softBody.isEnabled)
        #expect(softBody.selfCollision)
        #expect(softBody.pressure == 2.5)
        #expect(softBody.solverIterations == 11)
        #expect(cloth.gridSizeX == 6)
        #expect(cloth.fixedVertexIndices == [0, 2, 5])
        #expect(cloth.bendType == .dihedral)

        #expect(adapter.removeComponent(.cloth, from: id))
        #expect(adapter.removeComponent(.softBody, from: id))
        #expect(!hasSection(adapter, id, "cloth"))
        #expect(!hasSection(adapter, id, "soft-body"))
    }

    @Test("surface soft-body inspector edits asset topology and excludes cloth")
    func softBodyMeshBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        let entity = try #require(EntityID(rawValue: id))
        _ = adapter.scene.setComponent(
            AssetReferenceComponent(
                assetID: "mesh-12",
                name: "Tetra",
                relativePath: "Tetra.glb",
                absolutePath: "/tmp/Tetra.glb",
                kind: "model",
                meshIndex: 12
            ),
            for: entity
        )
        adapter.scene.setResource(MeshColliderGeometryResource(geometryByResourceID: [
            "meshIndex:12": MeshColliderGeometry(
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

        #expect(adapter.addComponent(.softBody, to: id))
        #expect(adapter.addComponent(.softBodyMesh, to: id))
        #expect(hasSection(adapter, id, "soft-body-mesh"))
        #expect(!adapter.addableComponentKinds(on: id).contains(.cloth))
        #expect(!adapter.addComponent(.cloth, to: id))

        guard case let .text(resource) =
                field(adapter, id, section: "soft-body-mesh", field: "soft-body-mesh-resource"),
              case let .json(fixedVertices, _) =
                field(adapter, id, section: "soft-body-mesh", field: "soft-body-mesh-fixed"),
              case let .constrainedNumber(compliance, _, _, _, _) =
                field(adapter, id, section: "soft-body-mesh", field: "soft-body-mesh-compliance"),
              case let .constrainedNumber(volumeCompliance, _, _, _, _) =
                field(adapter, id, section: "soft-body-mesh", field: "soft-body-mesh-volume"),
              case let .text(bendType) =
                field(adapter, id, section: "soft-body-mesh", field: "soft-body-mesh-bend-type"),
              case let .readOnly(tetrahedronCount) =
                field(adapter, id, section: "soft-body-mesh", field: "soft-body-mesh-tetrahedra") else {
            Issue.record("expected surface soft-body authored controls"); return
        }

        #expect(resource.wrappedValue == "meshIndex:12")
        #expect(tetrahedronCount == "1")
        resource.wrappedValue = "soft.tetra"
        fixedVertices.wrappedValue = "[7,2,-1,2]"
        compliance.wrappedValue = 0.006
        volumeCompliance.wrappedValue = 0.002
        bendType.wrappedValue = "distance"

        let mesh = try #require(adapter.scene.component(SoftBodyMesh.self, for: entity))
        #expect(mesh.resourceID == "soft.tetra")
        #expect(mesh.fixedVertexIndices == [2, 7])
        #expect(mesh.compliance == 0.006)
        #expect(mesh.volumeCompliance == 0.002)
        #expect(mesh.bendType == .distance)

        #expect(adapter.removeComponent(.softBodyMesh, from: id))
        #expect(!hasSection(adapter, id, "soft-body-mesh"))
        #expect(adapter.addableComponentKinds(on: id).contains(.cloth))
    }

    @Test("destructible inspector edits pre-fracture thresholds and recycling policy")
    func destructibleBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        let entity = try #require(EntityID(rawValue: id))
        #expect(adapter.addComponent(.destructible, to: id))
        #expect(hasSection(adapter, id, "destructible"))

        guard case let .bool(enabled) =
                field(adapter, id, section: "destructible", field: "destructible-enabled"),
              case let .text(asset) =
                field(adapter, id, section: "destructible", field: "destructible-asset"),
              case let .constrainedNumber(damage, _, _, _, _) =
                field(adapter, id, section: "destructible", field: "destructible-damage-threshold"),
              case let .constrainedNumber(impulse, _, _, _, _) =
                field(adapter, id, section: "destructible", field: "destructible-impulse-threshold"),
              case let .constrainedNumber(budget, _, _, _, _) =
                field(adapter, id, section: "destructible", field: "destructible-fragment-budget"),
              case let .constrainedNumber(lifetime, _, _, _, _) =
                field(adapter, id, section: "destructible", field: "destructible-lifetime"),
              case let .constrainedNumber(recycleDelay, _, _, _, _) =
                field(adapter, id, section: "destructible", field: "destructible-sleep-recycle") else {
            Issue.record("expected destructible authored controls"); return
        }
        enabled.wrappedValue = false
        asset.wrappedValue = "tower.prefractured"
        damage.wrappedValue = 80
        impulse.wrappedValue = 14
        budget.wrappedValue = 96
        lifetime.wrappedValue = 25
        recycleDelay.wrappedValue = 4

        let destructible = try #require(adapter.scene.component(Destructible.self, for: entity))
        #expect(!destructible.isEnabled)
        #expect(destructible.assetResourceID == "tower.prefractured")
        #expect(destructible.damageThreshold == 80)
        #expect(destructible.impulseThreshold == 14)
        #expect(destructible.fragmentBudget == 96)
        #expect(destructible.maximumFragmentLifetimeSeconds == 25)
        #expect(destructible.sleepingRecycleDelaySeconds == 4)

        #expect(adapter.removeComponent(.destructible, from: id))
        #expect(!hasSection(adapter, id, "destructible"))
    }

    @Test("collider inspector edits Jolt shape center and collision mask")
    func colliderJoltSettingsBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        let entity = try #require(EntityID(rawValue: id))
        _ = adapter.addComponent(.collider, to: id)

        guard case let .vector3(centerX, centerY, centerZ) =
                field(adapter, id, section: "collider", field: "shape-center"),
              case let .constrainedNumber(layerMask, _, _, _, _) =
                field(adapter, id, section: "collider", field: "layer-mask") else {
            Issue.record("expected collider center and layer mask fields"); return
        }
        centerX.wrappedValue = 1
        centerY.wrappedValue = 2
        centerZ.wrappedValue = 3
        layerMask.wrappedValue = 0x00F0

        let collider = try #require(adapter.scene.component(Collider.self, for: entity))
        #expect(collider.shape.center == SIMD3<Float>(1, 2, 3))
        #expect(collider.layerMask == 0x00F0)
    }

    // MARK: - Audio Listener

    @Test("audio listener volume binding writes back")
    func audioListenerBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.audioListener, to: id)
        #expect(hasSection(adapter, id, "audio-listener"))

        guard case let .constrainedNumber(binding, _, _, _, _) =
                field(adapter, id, section: "audio-listener", field: "audio-listener-volume") else {
            Issue.record("expected master volume field"); return
        }
        binding.wrappedValue = 0.25
        #expect(adapter.scene.component(AudioListener.self, for: EntityID(rawValue: id)!)?.masterVolume == 0.25)
    }

    // MARK: - Animation Graph

    @Test("animation graph definition JSON binding writes back")
    func animationGraphDefinitionBinding() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        let entity = EntityID(rawValue: id)!
        _ = adapter.addComponent(.animationGraphPlayer, to: id)

        guard case let .json(binding, _) =
                field(adapter, id, section: "animation-graph-player", field: "anim-graph-definition") else {
            Issue.record("expected animation graph definition JSON field"); return
        }

        let graph = AnimationGraph(
            blendSpaces1D: [
                AnimationBlendSpace1D(name: "Locomotion",
                                      parameter: "speed",
                                      samples: [
                                        AnimationBlendSample1D(clipName: "idle", threshold: 0),
                                        AnimationBlendSample1D(clipName: "walk", threshold: 1),
                                      ]),
            ],
            stateMachine: AnimationStateMachine(
                initialState: "Move",
                states: [
                    AnimationState(name: "Move", motion: .blendSpace1D("Locomotion")),
                ]
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(graph)
        binding.wrappedValue = String(decoding: data, as: UTF8.self)

        let player = adapter.scene.component(AnimationGraphPlayer.self, for: entity)
        #expect(player?.graph == graph)
        #expect(player?.activeState == "Move")
        #expect(binding.wrappedValue.contains("\"blendSpace1D\""))
    }

    // MARK: - Particle Emitter

    @Test("particle emitter section appears with the component")
    func particleSectionPresence() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        #expect(!hasSection(adapter, id, "particle-emitter"))
        #expect(hasSection(adapter, id, "particle-scalability"))
        _ = adapter.addComponent(.particleEmitter, to: id)
        #expect(hasSection(adapter, id, "particle-emitter"))
    }

    @Test("particle inspector exposes the module stack")
    func particleModuleStackField() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)

        guard case let .particleModuleStack(binding) =
            field(adapter, id, section: "particle-emitter", field: "particle-module-stack") else {
            Issue.record("expected particle module stack field")
            return
        }

        let stack = binding.wrappedValue
        #expect(stack.version == ParticleModuleStack.currentVersion)
        #expect(stack.modules.map(\.id) == [
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
    }

    @Test("particle module stack binding preserves disabled module authoring state")
    func particleModuleStackBindingPreservesDisabledModuleAuthoringState() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)
        let entity = try #require(EntityID(rawValue: id))

        guard case let .particleModuleStack(binding) =
            field(adapter, id, section: "particle-emitter", field: "particle-module-stack") else {
            Issue.record("expected particle module stack field")
            return
        }

        var stack = binding.wrappedValue
        let forcesIndex = try #require(stack.modules.firstIndex { $0.id == "forces" })
        stack.modules[forcesIndex].isEnabled = false
        if case var .forces(settings) = stack.modules[forcesIndex].settings {
            settings.gravity.y = -7
            stack.modules[forcesIndex].settings = .forces(settings)
        } else {
            Issue.record("expected forces module settings")
        }
        binding.wrappedValue = stack

        let storedStack = try #require(adapter.scene.component(ParticleEmitter.self, for: entity)?.moduleStack)
        let forces = try #require(storedStack.modules.first { $0.id == "forces" })
        #expect(!forces.isEnabled)
        if case let .forces(settings) = forces.settings {
            #expect(settings.gravity.y == -7)
        } else {
            Issue.record("expected forces module settings")
        }

        if case let .vector3(_, gravityY, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-gravity") {
            gravityY.wrappedValue = -3
        } else {
            Issue.record("missing gravity field")
        }

        #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.gravity.y == -3)
        let rebasedStack = try #require(adapter.scene.component(ParticleEmitter.self, for: entity)?.moduleStack)
        let rebasedForces = try #require(rebasedStack.modules.first { $0.id == "forces" })
        #expect(!rebasedForces.isEnabled)
        if case let .forces(settings) = rebasedForces.settings {
            #expect(settings.gravity.y == -7)
        } else {
            Issue.record("expected forces module settings")
        }
    }

    @Test("particle module stack binding writes order and reset state")
    func particleModuleStackBindingWritesOrderAndResetState() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)
        let entity = try #require(EntityID(rawValue: id))

        guard case let .particleModuleStack(binding) =
            field(adapter, id, section: "particle-emitter", field: "particle-module-stack") else {
            Issue.record("expected particle module stack field")
            return
        }

        var moved = binding.wrappedValue
        let rendererIndex = try #require(moved.modules.firstIndex { $0.id == "renderer" })
        moved.moveModule(from: rendererIndex, to: 0)
        moved.modules[0].isEnabled = false
        binding.wrappedValue = moved

        var stored = try #require(adapter.scene.component(ParticleEmitter.self, for: entity)?.moduleStack)
        #expect(stored.modules.first?.id == "renderer")
        #expect(stored.modules.first?.isEnabled == false)

        stored.resetAuthoringState()
        binding.wrappedValue = stored

        let reset = try #require(adapter.scene.component(ParticleEmitter.self, for: entity)?.moduleStack)
        #expect(reset.modules.map(\.id) == ParticleModuleStack.defaultModuleIDs)
        #expect(reset.modules.allSatisfy { $0.isEnabled })
        #expect(reset.modules.allSatisfy { !$0.isExpanded })
    }

    @Test("particle module stack binding writes single module default reset")
    func particleModuleStackBindingWritesSingleModuleDefaultReset() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)
        let entity = try #require(EntityID(rawValue: id))

        guard case let .particleModuleStack(binding) =
            field(adapter, id, section: "particle-emitter", field: "particle-module-stack") else {
            Issue.record("expected particle module stack field")
            return
        }

        var stack = binding.wrappedValue
        let rendererIndex = try #require(stack.modules.firstIndex { $0.id == "renderer" })
        stack.modules[rendererIndex].isExpanded = true
        if case var .renderer(module) = stack.modules[rendererIndex].settings {
            module.renderMode = .ribbon
            module.renderSortPriority = 9
            module.renderBoundsMode = .manual
            module.renderBoundsRadius = 12
            stack.modules[rendererIndex].settings = .renderer(module)
        } else {
            Issue.record("expected renderer module settings")
        }
        binding.wrappedValue = stack
        #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderMode == .ribbon)

        var stored = try #require(adapter.scene.component(ParticleEmitter.self, for: entity)?.moduleStack)
        #expect(stored.moduleSettingsDifferFromDefault("renderer"))
        stored.resetModuleSettings(for: "renderer")
        binding.wrappedValue = stored

        let resetEmitter = try #require(adapter.scene.component(ParticleEmitter.self, for: entity))
        let resetStack = resetEmitter.moduleStack
        let resetRenderer = try #require(resetStack.modules.first { $0.id == "renderer" })
        #expect(resetEmitter.renderMode == .billboard)
        #expect(resetEmitter.renderSortPriority == 0)
        #expect(resetEmitter.renderBoundsMode == .disabled)
        #expect(resetRenderer.isExpanded)
        #expect(!resetStack.moduleSettingsDifferFromDefault("renderer"))
    }

    @Test("particle module stack binding writes inline module settings")
    func particleModuleStackBindingWritesInlineModuleSettings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)
        let entity = try #require(EntityID(rawValue: id))

        guard case let .particleModuleStack(binding) =
            field(adapter, id, section: "particle-emitter", field: "particle-module-stack") else {
            Issue.record("expected particle module stack field")
            return
        }

        var stack = binding.wrappedValue
        let emissionIndex = try #require(stack.modules.firstIndex { $0.id == "emission" })
        stack.modules[emissionIndex].isExpanded = true
        if case var .emission(module) = stack.modules[emissionIndex].settings {
            module.emissionRate = 77
            module.maxParticles = 512
            module.maxSpawnedParticlesPerFrame = 96
            module.simulationSpeed = 1.75
            module.distanceEmissionRate = 9
            module.emissionRateCurve = .easeInOut
            module.distanceEmissionRateCurve = .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0.25),
                ParticleCurveKeyframe(time: 1, value: 1.5),
            ])
            module.burstInterval = 0.25
            module.seed = 123_456_789
            stack.modules[emissionIndex].settings = .emission(module)
        } else {
            Issue.record("expected emission module settings")
        }

        let shapeIndex = try #require(stack.modules.firstIndex { $0.id == "shape" })
        stack.modules[shapeIndex].isExpanded = true
        if case var .shape(module) = stack.modules[shapeIndex].settings {
            module.emissionShape = .cone
            module.originOffset = SIMD3<Float>(0.5, 1.5, -2.5)
            module.spawnRadius = 2.25
            module.boxHalfExtents = SIMD3<Float>(4, 5, 6)
            module.coneRadius = 3.5
            module.coneHeight = 7
            stack.modules[shapeIndex].settings = .shape(module)
        } else {
            Issue.record("expected shape module settings")
        }

        let forcesIndex = try #require(stack.modules.firstIndex { $0.id == "forces" })
        stack.modules[forcesIndex].isExpanded = true
        if case var .forces(module) = stack.modules[forcesIndex].settings {
            module.forceMode = .radial
            module.vectorFieldMode = .curl
            module.gravity = SIMD3<Float>(1, -4, 2)
            module.noiseStrength = 2.5
            module.noiseScale = 1.75
            module.noiseSpeed = 0.6
            module.forceCenter = SIMD3<Float>(3, 4, 5)
            module.forceRadius = 11
            module.forceFalloff = 1.5
            module.vectorFieldStrength = 8.5
            module.vectorFieldScale = 3
            module.vectorFieldScrollSpeed = 0.75
            stack.modules[forcesIndex].settings = .forces(module)
        } else {
            Issue.record("expected forces module settings")
        }

        let velocityIndex = try #require(stack.modules.firstIndex { $0.id == "velocity" })
        stack.modules[velocityIndex].isExpanded = true
        if case var .velocity(module) = stack.modules[velocityIndex].settings {
            module.startVelocity = SIMD3<Float>(1, 2, 3)
            module.velocityRandomness = SIMD3<Float>(0.25, 0.5, 0.75)
            module.velocityInheritance = 0.4
            stack.modules[velocityIndex].settings = .velocity(module)
        } else {
            Issue.record("expected velocity module settings")
        }

        let collisionIndex = try #require(stack.modules.firstIndex { $0.id == "collision" })
        stack.modules[collisionIndex].isExpanded = true
        if case var .collision(module) = stack.modules[collisionIndex].settings {
            module.collisionMode = .worldPlane
            module.collisionPlaneY = -2
            module.collisionRestitution = 0.8
            module.collisionDamping = 0.35
            stack.modules[collisionIndex].settings = .collision(module)
        } else {
            Issue.record("expected collision module settings")
        }

        let appearanceIndex = try #require(stack.modules.firstIndex { $0.id == "appearance" })
        stack.modules[appearanceIndex].isExpanded = true
        if case var .appearance(module) = stack.modules[appearanceIndex].settings {
            module.blendMode = .additive
            module.lifetime = 2.5
            module.lifetimeRandomness = 0.4
            module.startSize = 1.2
            module.endSize = 0.3
            module.sizeRandomness = 0.25
            module.sizeCurve = .easeOut
            module.startColor = SIMD4<Float>(0.9, 0.25, 0.1, 0.8)
            module.endColor = SIMD4<Float>(0.1, 0.35, 1, 0.2)
            module.colorCurve = .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 0.65, value: 0.9),
                ParticleCurveKeyframe(time: 1, value: 1),
            ])
            module.startRotation = 15
            module.rotationRandomness = 45
            module.angularVelocity = 120
            module.angularVelocityRandomness = 30
            stack.modules[appearanceIndex].settings = .appearance(module)
        } else {
            Issue.record("expected appearance module settings")
        }

        let textureSheetIndex = try #require(stack.modules.firstIndex { $0.id == "textureSheet" })
        stack.modules[textureSheetIndex].isExpanded = true
        if case var .textureSheet(module) = stack.modules[textureSheetIndex].settings {
            module.playbackMode = .loop
            module.frameRate = 24
            module.columns = 4
            module.rows = 2
            module.frameCount = 8
            module.startFrame = 2
            module.frameRandomness = 3
            stack.modules[textureSheetIndex].settings = .textureSheet(module)
        } else {
            Issue.record("expected texture sheet module settings")
        }

        let rendererIndex = try #require(stack.modules.firstIndex { $0.id == "renderer" })
        stack.modules[rendererIndex].isExpanded = true
        if case var .renderer(module) = stack.modules[rendererIndex].settings {
            module.renderMode = .ribbon
            module.sortMode = .oldestFirst
            module.renderSortPriority = 12
            module.renderAlignment = .velocity
            module.renderBoundsMode = .manual
            module.maxRenderDistance = 123
            module.renderDistanceFadeRange = 9
            module.renderLODStartDistance = 30
            module.renderLODEndDistance = 120
            module.renderLODMinParticleScale = 0.35
            module.renderBoundsRadius = 42
            module.velocityStretchScale = 0.5
            module.velocityStretchMax = 9
            stack.modules[rendererIndex].settings = .renderer(module)
        } else {
            Issue.record("expected renderer module settings")
        }

        let trailsIndex = try #require(stack.modules.firstIndex { $0.id == "trails" })
        stack.modules[trailsIndex].isExpanded = true
        if case var .trails(module) = stack.modules[trailsIndex].settings {
            module.trailLength = 1.25
            module.trailSegments = 7
            module.trailEndAlphaScale = 0.3
            module.ribbonWidthScale = 1.6
            module.ribbonTailWidthScale = 0.2
            module.ribbonTailAlphaScale = 0.4
            module.ribbonMaxSegmentLength = 5
            module.ribbonJoinOverlapScale = 0.15
            module.ribbonSmoothingSegments = 4
            module.ribbonTextureTiling = 4
            module.ribbonTextureOffset = 0.75
            module.trailEndSizeScale = 0.45
            stack.modules[trailsIndex].settings = .trails(module)
        } else {
            Issue.record("expected trails module settings")
        }

        let subEmittersIndex = try #require(stack.modules.firstIndex { $0.id == "subEmitters" })
        stack.modules[subEmittersIndex].isExpanded = true
        if case var .subEmitters(module) = stack.modules[subEmittersIndex].settings {
            module.legacyTrigger = .collision
            module.legacyBurstCount = 3
            module.legacyProbability = 0.6
            module.legacyMaxDepth = 2
            module.legacyInheritVelocity = 0.25
            module.legacyLifetime = 1.75
            module.rules = [
                ParticleSubEmitter(trigger: .death,
                                   burstCount: 5,
                                   probability: 0.75,
                                   maxDepth: 3,
                                   inheritVelocity: 0.5,
                                   lifetime: 0.9,
                                   startVelocity: SIMD3<Float>(0, 2, 0),
                                   velocityRandomness: SIMD3<Float>(0.1, 0.2, 0.3),
                                   startSize: 0.4,
                                   endSize: 0.1,
                                   startColor: SIMD4<Float>(1, 0.5, 0.25, 1),
                                   endColor: SIMD4<Float>(1, 0.1, 0, 0)),
            ]
            stack.modules[subEmittersIndex].settings = .subEmitters(module)
        } else {
            Issue.record("expected sub emitters module settings")
        }

        let gpuIndex = try #require(stack.modules.firstIndex { $0.id == "gpuSimulation" })
        stack.modules[gpuIndex].isExpanded = true
        if case var .gpuSimulation(module) = stack.modules[gpuIndex].settings {
            module.simulationSpace = .world
            module.simulationBackend = .gpuIfSupported
            module.workgroupSize = 96
            stack.modules[gpuIndex].settings = .gpuSimulation(module)
        } else {
            Issue.record("expected gpu simulation module settings")
        }

        binding.wrappedValue = stack

        let emitter = try #require(adapter.scene.component(ParticleEmitter.self, for: entity))
        #expect(emitter.emissionRate == 77)
        #expect(emitter.maxParticles == 512)
        #expect(emitter.maxSpawnedParticlesPerFrame == 96)
        #expect(emitter.simulationSpeed == 1.75)
        #expect(emitter.distanceEmissionRate == 9)
        #expect(emitter.emissionRateCurve == .easeInOut)
        #expect(emitter.distanceEmissionRateCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 0.25),
            ParticleCurveKeyframe(time: 1, value: 1.5),
        ]))
        #expect(emitter.burstInterval == 0.25)
        #expect(emitter.seed == 123_456_789)
        #expect(emitter.emissionShape == .cone)
        #expect(emitter.originOffset == SIMD3<Float>(0.5, 1.5, -2.5))
        #expect(emitter.spawnRadius == 2.25)
        #expect(emitter.boxHalfExtents == SIMD3<Float>(4, 5, 6))
        #expect(emitter.coneRadius == 3.5)
        #expect(emitter.coneHeight == 7)
        #expect(emitter.forceMode == .radial)
        #expect(emitter.vectorFieldMode == .curl)
        #expect(emitter.gravity == SIMD3<Float>(1, -4, 2))
        #expect(emitter.noiseStrength == 2.5)
        #expect(emitter.noiseScale == 1.75)
        #expect(emitter.noiseSpeed == 0.6)
        #expect(emitter.forceCenter == SIMD3<Float>(3, 4, 5))
        #expect(emitter.forceRadius == 11)
        #expect(emitter.forceFalloff == 1.5)
        #expect(emitter.vectorFieldStrength == 8.5)
        #expect(emitter.vectorFieldScale == 3)
        #expect(emitter.vectorFieldScrollSpeed == 0.75)
        #expect(emitter.startVelocity == SIMD3<Float>(1, 2, 3))
        #expect(emitter.velocityRandomness == SIMD3<Float>(0.25, 0.5, 0.75))
        #expect(emitter.velocityInheritance == 0.4)
        #expect(emitter.collisionMode == .worldPlane)
        #expect(emitter.collisionPlaneY == -2)
        #expect(emitter.collisionRestitution == 0.8)
        #expect(emitter.collisionDamping == 0.35)
        #expect(emitter.blendMode == .additive)
        #expect(emitter.lifetime == 2.5)
        #expect(emitter.lifetimeRandomness == 0.4)
        #expect(emitter.startSize == 1.2)
        #expect(emitter.endSize == 0.3)
        #expect(emitter.sizeRandomness == 0.25)
        #expect(emitter.sizeCurve == .easeOut)
        #expect(emitter.startColor == SIMD4<Float>(0.9, 0.25, 0.1, 0.8))
        #expect(emitter.endColor == SIMD4<Float>(0.1, 0.35, 1, 0.2))
        #expect(emitter.colorCurve == .keyframes([
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 0.65, value: 0.9),
            ParticleCurveKeyframe(time: 1, value: 1),
        ]))
        #expect(emitter.startRotation == 15)
        #expect(emitter.rotationRandomness == 45)
        #expect(emitter.angularVelocity == 120)
        #expect(emitter.angularVelocityRandomness == 30)
        #expect(emitter.textureSheetPlaybackMode == .loop)
        #expect(emitter.textureSheetFrameRate == 24)
        #expect(emitter.textureSheetColumns == 4)
        #expect(emitter.textureSheetRows == 2)
        #expect(emitter.textureSheetFrameCount == 8)
        #expect(emitter.textureSheetStartFrame == 2)
        #expect(emitter.textureSheetFrameRandomness == 3)
        #expect(emitter.renderMode == .ribbon)
        #expect(emitter.sortMode == .oldestFirst)
        #expect(emitter.renderSortPriority == 12)
        #expect(emitter.renderAlignment == .velocity)
        #expect(emitter.renderBoundsMode == .manual)
        #expect(emitter.maxRenderDistance == 123)
        #expect(emitter.renderDistanceFadeRange == 9)
        #expect(emitter.renderLODStartDistance == 30)
        #expect(emitter.renderLODEndDistance == 120)
        #expect(emitter.renderLODMinParticleScale == 0.35)
        #expect(emitter.renderBoundsRadius == 42)
        #expect(emitter.velocityStretchScale == 0.5)
        #expect(emitter.velocityStretchMax == 9)
        #expect(emitter.trailLength == 1.25)
        #expect(emitter.trailSegments == 7)
        #expect(emitter.trailEndAlphaScale == 0.3)
        #expect(emitter.trailEndSizeScale == 0.45)
        #expect(emitter.ribbonWidthScale == 1.6)
        #expect(emitter.ribbonTailWidthScale == 0.2)
        #expect(emitter.ribbonTailAlphaScale == 0.4)
        #expect(emitter.ribbonMaxSegmentLength == 5)
        #expect(emitter.ribbonJoinOverlapScale == 0.15)
        #expect(emitter.ribbonSmoothingSegments == 4)
        #expect(emitter.ribbonTextureTiling == 4)
        #expect(emitter.ribbonTextureOffset == 0.75)
        #expect(emitter.subEmitterTrigger == .collision)
        #expect(emitter.subEmitterBurstCount == 3)
        #expect(emitter.subEmitterProbability == 0.6)
        #expect(emitter.subEmitterMaxDepth == 2)
        #expect(emitter.subEmitterInheritVelocity == 0.25)
        #expect(emitter.subEmitterLifetime == 1.75)
        #expect(emitter.subEmitters == [
            ParticleSubEmitter(trigger: .death,
                               burstCount: 5,
                               probability: 0.75,
                               maxDepth: 3,
                               inheritVelocity: 0.5,
                               lifetime: 0.9,
                               startVelocity: SIMD3<Float>(0, 2, 0),
                               velocityRandomness: SIMD3<Float>(0.1, 0.2, 0.3),
                               startSize: 0.4,
                               endSize: 0.1,
                               startColor: SIMD4<Float>(1, 0.5, 0.25, 1),
                               endColor: SIMD4<Float>(1, 0.1, 0, 0)),
        ])
        #expect(emitter.simulationSpace == .world)
        #expect(emitter.simulationBackend == .gpuIfSupported)
        #expect(emitter.gpuSimulationWorkgroupSize == 96)

        let storedStack = emitter.moduleStack
        #expect(storedStack.modules.first { $0.id == "emission" }?.isExpanded == true)
        #expect(storedStack.modules.first { $0.id == "shape" }?.isExpanded == true)
        #expect(storedStack.modules.first { $0.id == "forces" }?.isExpanded == true)
        #expect(storedStack.modules.first { $0.id == "velocity" }?.isExpanded == true)
        #expect(storedStack.modules.first { $0.id == "collision" }?.isExpanded == true)
        #expect(storedStack.modules.first { $0.id == "appearance" }?.isExpanded == true)
        #expect(storedStack.modules.first { $0.id == "textureSheet" }?.isExpanded == true)
        #expect(storedStack.modules.first { $0.id == "renderer" }?.isExpanded == true)
        #expect(storedStack.modules.first { $0.id == "trails" }?.isExpanded == true)
        #expect(storedStack.modules.first { $0.id == "subEmitters" }?.isExpanded == true)
        #expect(storedStack.modules.first { $0.id == "gpuSimulation" }?.isExpanded == true)
    }

    @Test("particle scalability bindings write scene resources")
    func particleScalabilityBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)

        guard case let .constrainedNumber(emissionScale, _, _, _, _) =
                field(adapter, id, section: "particle-scalability", field: "particle-scale-emission") else {
            Issue.record("expected emission scale field"); return
        }
        emissionScale.wrappedValue = 0.5
        #expect(adapter.scene.resource(ParticleScalabilityResource.self)?.emissionScale == 0.5)

        guard case let .constrainedNumber(liveCapScale, _, _, _, _) =
                field(adapter, id, section: "particle-scalability", field: "particle-scale-live-cap") else {
            Issue.record("expected live cap scale field"); return
        }
        liveCapScale.wrappedValue = 0.25
        #expect(adapter.scene.resource(ParticleScalabilityResource.self)?.maxLiveParticleScale == 0.25)

        guard case let .bool(enabled) =
                field(adapter, id, section: "particle-scalability", field: "particle-policy-enabled") else {
            Issue.record("expected policy enabled field"); return
        }
        enabled.wrappedValue = true
        #expect(adapter.scene.resource(ParticleScalabilityPolicyResource.self)?.isEnabled == true)

        guard case let .constrainedNumber(targetLive, _, _, _, _) =
                field(adapter, id, section: "particle-scalability", field: "particle-policy-target-live") else {
            Issue.record("expected target live field"); return
        }
        targetLive.wrappedValue = 12_345
        #expect(adapter.scene.resource(ParticleScalabilityPolicyResource.self)?.targetLiveParticles == 12_345)

        guard case let .constrainedNumber(minimumScale, _, _, _, _) =
                field(adapter, id, section: "particle-scalability", field: "particle-policy-min-scale") else {
            Issue.record("expected minimum scale field"); return
        }
        minimumScale.wrappedValue = 1.5
        #expect(adapter.scene.resource(ParticleScalabilityPolicyResource.self)?.minimumScale == 1)
    }

    @Test("particle scalar and bool bindings write back")
    func particleScalarBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)
        let entity = EntityID(rawValue: id)!

        if case let .constrainedNumber(rate, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-rate") {
            rate.wrappedValue = 42
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.emissionRate == 42)
        } else { Issue.record("missing rate field") }

        if case let .particleCurve(rateCurve) =
            field(adapter, id, section: "particle-emitter", field: "particle-rate-curve") {
            rateCurve.wrappedValue = .constant(1.5)
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.emissionRateCurve == .constant(1.5))
        } else { Issue.record("missing rate curve field") }

        if case let .constrainedNumber(duration, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-duration") {
            duration.wrappedValue = 2.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.duration == 2.5)
        } else { Issue.record("missing duration field") }

        if case let .constrainedNumber(speed, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-simulation-speed") {
            speed.wrappedValue = 0.25
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.simulationSpeed == 0.25)
        } else { Issue.record("missing speed field") }

        if case let .constrainedNumber(prewarm, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-prewarm-time") {
            prewarm.wrappedValue = 1.25
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.prewarmTime == 1.25)
        } else { Issue.record("missing prewarm field") }

        if case let .constrainedNumber(prewarmStep, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-prewarm-step") {
            prewarmStep.wrappedValue = 0.05
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.prewarmStep == 0.05)
        } else { Issue.record("missing prewarm step field") }

        if case let .constrainedNumber(maxP, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-max") {
            maxP.wrappedValue = 128
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.maxParticles == 128)
        } else { Issue.record("missing max field") }

        if case let .constrainedNumber(maxSpawned, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-max-spawned-per-frame") {
            maxSpawned.wrappedValue = 48
            #expect(adapter.scene.component(ParticleEmitter.self,
                                            for: entity)?.maxSpawnedParticlesPerFrame == 48)
        } else { Issue.record("missing max spawned per frame field") }

        if case let .constrainedNumber(maxRendered, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-max-rendered") {
            maxRendered.wrappedValue = 64
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.maxRenderedParticles == 64)
        } else { Issue.record("missing max rendered field") }

        if case let .constrainedNumber(burstCount, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-burst-count") {
            burstCount.wrappedValue = 4.8
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.burstCount == 5)
        } else { Issue.record("missing burst count field") }

        if case let .constrainedNumber(burstInterval, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-burst-interval") {
            burstInterval.wrappedValue = 0.25
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.burstInterval == 0.25)
        } else { Issue.record("missing burst interval field") }

        if case let .constrainedNumber(distanceRate, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-distance-rate") {
            distanceRate.wrappedValue = 12
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.distanceEmissionRate == 12)
        } else { Issue.record("missing distance emission field") }

        if case let .particleCurve(distanceRateCurve) =
            field(adapter, id, section: "particle-emitter", field: "particle-distance-rate-curve") {
            distanceRateCurve.wrappedValue = .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 2),
            ])
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.distanceEmissionRateCurve == .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 2),
            ]))
        } else { Issue.record("missing distance rate curve field") }

        if case let .particleSubEmitterTrigger(trigger) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-trigger") {
            trigger.wrappedValue = .collision
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterTrigger == .collision)
        } else { Issue.record("missing sub-emitter trigger field") }

        if case let .constrainedNumber(subCount, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-burst") {
            subCount.wrappedValue = 3.8
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterBurstCount == 4)
        } else { Issue.record("missing sub-emitter count field") }

        if case let .constrainedNumber(subChance, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-probability") {
            subChance.wrappedValue = 0.75
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterProbability == 0.75)
        } else { Issue.record("missing sub-emitter chance field") }

        if case let .constrainedNumber(subDepth, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-depth") {
            subDepth.wrappedValue = 2.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterMaxDepth == 2)
        } else { Issue.record("missing sub-emitter depth field") }

        if case let .constrainedNumber(subInherit, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-inherit") {
            subInherit.wrappedValue = 0.45
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterInheritVelocity == 0.45)
        } else { Issue.record("missing sub-emitter inherit field") }

        if case let .constrainedNumber(subLifetime, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-lifetime") {
            subLifetime.wrappedValue = 0.6
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterLifetime == 0.6)
        } else { Issue.record("missing sub-emitter lifetime field") }

        if case let .constrainedNumber(subStartSize, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-start-size") {
            subStartSize.wrappedValue = 0.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterStartSize == 0.2)
        } else { Issue.record("missing sub-emitter start size field") }

        if case let .constrainedNumber(subEndSize, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-end-size") {
            subEndSize.wrappedValue = 0.05
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterEndSize == 0.05)
        } else { Issue.record("missing sub-emitter end size field") }

        if case let .particleSubEmitters(subEmitters) =
            field(adapter, id, section: "particle-emitter", field: "particle-sub-emitters") {
            #expect(subEmitters.wrappedValue.isEmpty)

            subEmitters.wrappedValue = [
                ParticleSubEmitter(trigger: .death,
                                   burstCount: 4,
                                   probability: 0.5,
                                   maxDepth: 1,
                                   inheritVelocity: 0.25,
                                   lifetime: 0.4,
                                   startVelocity: SIMD3<Float>(0, 1, 0),
                                   velocityRandomness: SIMD3<Float>(0.1, 0.2, 0.3),
                                   startSize: 0.3,
                                   endSize: 0.1,
                                   startColor: SIMD4<Float>(1, 0.5, 0.25, 1),
                                   endColor: SIMD4<Float>(1, 0.2, 0.1, 0)),
                ParticleSubEmitter(trigger: .collision,
                                   burstCount: 2,
                                   probability: 1,
                                   maxDepth: 2,
                                   inheritVelocity: 0,
                                   lifetime: 0.2,
                                   startVelocity: SIMD3<Float>(1, 0, 0),
                                   velocityRandomness: .zero,
                                   startSize: 0.2,
                                   endSize: 0,
                                   startColor: SIMD4<Float>(0.2, 0.4, 1, 1),
                                   endColor: SIMD4<Float>(0.2, 0.4, 1, 0)),
            ]
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitters.count == 2)
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitters[0].trigger == .death)
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitters[1].trigger == .collision)

            var edited = subEmitters.wrappedValue
            edited[0].burstCount = -3
            edited[0].probability = 2
            edited[0].maxDepth = -1
            edited[0].inheritVelocity = -0.25
            edited[0].lifetime = -2
            edited[0].startSize = -1
            edited[0].endSize = -1
            edited.removeLast()
            subEmitters.wrappedValue = edited

            let stored = adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitters
            #expect(stored?.count == 1)
            #expect(stored?[0].burstCount == 0)
            #expect(stored?[0].probability == 1)
            #expect(stored?[0].maxDepth == 0)
            #expect(stored?[0].inheritVelocity == 0)
            #expect(stored?[0].lifetime == 0.0001)
            #expect(stored?[0].startSize == 0)
            #expect(stored?[0].endSize == 0)

            subEmitters.wrappedValue = []
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitters.isEmpty == true)
        } else { Issue.record("missing particle sub-emitters field") }

        if case let .constrainedNumber(sheetColumns, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-columns") {
            sheetColumns.wrappedValue = 4
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetColumns == 4)
        } else { Issue.record("missing texture sheet columns field") }

        if case let .constrainedNumber(sheetRows, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-rows") {
            sheetRows.wrappedValue = 2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetRows == 2)
        } else { Issue.record("missing texture sheet rows field") }

        if case let .constrainedNumber(sheetFrames, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-frames") {
            sheetFrames.wrappedValue = 7.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetFrameCount == 7)
        } else { Issue.record("missing texture sheet frame field") }

        if case let .constrainedNumber(sheetFPS, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-fps") {
            sheetFPS.wrappedValue = 12
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetFrameRate == 12)
        } else { Issue.record("missing texture sheet fps field") }

        if case let .particleTextureSheetPlaybackMode(playback) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-playback") {
            playback.wrappedValue = .loop
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetPlaybackMode == .loop)
        } else { Issue.record("missing texture sheet playback field") }

        if case let .constrainedNumber(sheetStart, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-start-frame") {
            sheetStart.wrappedValue = 3.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetStartFrame == 3)
        } else { Issue.record("missing texture sheet start frame field") }

        if case let .constrainedNumber(sheetRandom, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture-sheet-random") {
            sheetRandom.wrappedValue = 2.9
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureSheetFrameRandomness == 3)
        } else { Issue.record("missing texture sheet random field") }

        if case let .constrainedNumber(trailLength, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-trail-length") {
            trailLength.wrappedValue = 0.75
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.trailLength == 0.75)
        } else { Issue.record("missing trail length field") }

        if case let .constrainedNumber(trailSegments, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-trail-segments") {
            trailSegments.wrappedValue = 6.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.trailSegments == 6)
        } else { Issue.record("missing trail segments field") }

        if case let .constrainedNumber(trailEndSize, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-trail-end-size") {
            trailEndSize.wrappedValue = 0.35
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.trailEndSizeScale == 0.35)
        } else { Issue.record("missing trail end size field") }

        if case let .constrainedNumber(trailEndAlpha, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-trail-end-alpha") {
            trailEndAlpha.wrappedValue = 0.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.trailEndAlphaScale == 0.2)
        } else { Issue.record("missing trail end alpha field") }

        if case let .bool(emitting) = field(adapter, id, section: "particle-emitter", field: "particle-emitting") {
            emitting.wrappedValue = false
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.isEmitting == false)
        } else { Issue.record("missing emitting field") }

        if case let .particleEmissionShape(shape) =
            field(adapter, id, section: "particle-emitter", field: "particle-shape") {
            shape.wrappedValue = .cone
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.emissionShape == .cone)
        } else { Issue.record("missing shape field") }

        if case let .particleCollisionMode(mode) =
            field(adapter, id, section: "particle-emitter", field: "particle-collision-mode") {
            mode.wrappedValue = .worldPlane
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.collisionMode == .worldPlane)
        } else { Issue.record("missing collision mode field") }

        if case let .particleSimulationSpace(space) =
            field(adapter, id, section: "particle-emitter", field: "particle-simulation-space") {
            space.wrappedValue = .world
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.simulationSpace == .world)
        } else { Issue.record("missing simulation space field") }

        if case let .particleSimulationBackend(backend) =
            field(adapter, id, section: "particle-emitter", field: "particle-simulation-backend") {
            backend.wrappedValue = .gpuRequired
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.simulationBackend == .gpuRequired)
        } else { Issue.record("missing simulation backend field") }

        if case let .constrainedNumber(workgroupSize, minimum, maximum, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-gpu-workgroup-size") {
            #expect(minimum == 1)
            #expect(maximum == Float(ParticleGPUSimulationPlan.maximumWorkgroupSize))
            workgroupSize.wrappedValue = 128
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.gpuSimulationWorkgroupSize == 128)
        } else { Issue.record("missing GPU workgroup field") }

        if case let .readOnly(gpuStatus) =
            field(adapter, id, section: "particle-emitter", field: "particle-gpu-status") {
            #expect(gpuStatus.contains("Unsupported"))
            #expect(gpuStatus.contains("distance emission"))
        } else { Issue.record("missing GPU status field") }

        if case let .constrainedNumber(restitution, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-collision-restitution") {
            restitution.wrappedValue = 0.7
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.collisionRestitution == 0.7)
        } else { Issue.record("missing restitution field") }

        if case let .constrainedNumber(noiseStrength, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-noise-strength") {
            noiseStrength.wrappedValue = 1.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.noiseStrength == 1.5)
        } else { Issue.record("missing noise strength field") }

        if case let .constrainedNumber(noiseScale, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-noise-scale") {
            noiseScale.wrappedValue = 2.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.noiseScale == 2.5)
        } else { Issue.record("missing noise scale field") }

        if case let .constrainedNumber(noiseSpeed, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-noise-speed") {
            noiseSpeed.wrappedValue = 0.75
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.noiseSpeed == 0.75)
        } else { Issue.record("missing noise speed field") }

        if case let .particleForceMode(forceMode) =
            field(adapter, id, section: "particle-emitter", field: "particle-force-mode") {
            forceMode.wrappedValue = .vortex
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.forceMode == .vortex)
        } else { Issue.record("missing force mode field") }

        if case let .constrainedNumber(forceRadius, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-force-radius") {
            forceRadius.wrappedValue = 12
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.forceRadius == 12)
        } else { Issue.record("missing force radius field") }

        if case let .constrainedNumber(forceStrength, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-force-strength") {
            forceStrength.wrappedValue = -3.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.forceStrength == -3.5)
        } else { Issue.record("missing force strength field") }

        if case let .constrainedNumber(forceFalloff, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-force-falloff") {
            forceFalloff.wrappedValue = 2.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.forceFalloff == 2.5)
        } else { Issue.record("missing force falloff field") }

        if case let .particleVectorFieldMode(vectorFieldMode) =
            field(adapter, id, section: "particle-emitter", field: "particle-vector-field-mode") {
            vectorFieldMode.wrappedValue = .curl
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.vectorFieldMode == .curl)
        } else { Issue.record("missing vector field mode field") }

        if case let .vector3(x, y, z) =
            field(adapter, id, section: "particle-emitter", field: "particle-vector-field-direction") {
            x.wrappedValue = 0
            y.wrappedValue = 0
            z.wrappedValue = 1
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.vectorFieldDirection
                    == SIMD3<Float>(0, 0, 1))
        } else { Issue.record("missing vector field direction field") }

        if case let .constrainedNumber(vectorFieldStrength, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-vector-field-strength") {
            vectorFieldStrength.wrappedValue = 6.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.vectorFieldStrength == 6.5)
        } else { Issue.record("missing vector field strength field") }

        if case let .constrainedNumber(vectorFieldScale, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-vector-field-scale") {
            vectorFieldScale.wrappedValue = 2.25
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.vectorFieldScale == 2.25)
        } else { Issue.record("missing vector field scale field") }

        if case let .constrainedNumber(vectorFieldScroll, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-vector-field-scroll") {
            vectorFieldScroll.wrappedValue = 0.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.vectorFieldScrollSpeed == 0.5)
        } else { Issue.record("missing vector field scroll field") }

        if case let .particleCurve(sizeCurve) =
            field(adapter, id, section: "particle-emitter", field: "particle-size-curve") {
            sizeCurve.wrappedValue = .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 1),
            ])
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.sizeCurve == .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 1),
            ]))
        } else { Issue.record("missing size curve field") }

        if case let .constrainedNumber(sizeRandomness, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-size-randomness") {
            sizeRandomness.wrappedValue = 0.3
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.sizeRandomness == 0.3)
        } else { Issue.record("missing size randomness field") }

        if case let .constrainedNumber(rotation, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-rotation") {
            rotation.wrappedValue = 0.4
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.startRotation == 0.4)
        } else { Issue.record("missing rotation field") }

        if case let .constrainedNumber(rotationRandom, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-rotation-randomness") {
            rotationRandom.wrappedValue = 0.2
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.rotationRandomness == 0.2)
        } else { Issue.record("missing rotation randomness field") }

        if case let .constrainedNumber(spin, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-angular-velocity") {
            spin.wrappedValue = 1.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.angularVelocity == 1.5)
        } else { Issue.record("missing angular velocity field") }

        if case let .constrainedNumber(spinRandom, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-angular-velocity-randomness") {
            spinRandom.wrappedValue = 0.75
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.angularVelocityRandomness == 0.75)
        } else { Issue.record("missing angular velocity randomness field") }

        if case let .constrainedNumber(velocityInheritance, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-velocity-inheritance") {
            velocityInheritance.wrappedValue = 0.4
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.velocityInheritance == 0.4)
        } else { Issue.record("missing velocity inheritance field") }

        if case let .particleCurve(colorCurve) =
            field(adapter, id, section: "particle-emitter", field: "particle-color-curve") {
            colorCurve.wrappedValue = .easeOut
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.colorCurve == .easeOut)
        } else { Issue.record("missing color curve field") }

        if case let .particleBlendMode(blendMode) =
            field(adapter, id, section: "particle-emitter", field: "particle-blend-mode") {
            blendMode.wrappedValue = .additive
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.blendMode == .additive)
        } else { Issue.record("missing blend mode field") }

        if case let .particleRenderAlignment(alignment) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-alignment") {
            alignment.wrappedValue = .velocity
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderAlignment == .velocity)
        } else { Issue.record("missing render alignment field") }

        if case let .constrainedNumber(velocityStretch, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-velocity-stretch-scale") {
            velocityStretch.wrappedValue = 0.5
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.velocityStretchScale == 0.5)
        } else { Issue.record("missing velocity stretch field") }

        if case let .constrainedNumber(maxStretch, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-velocity-stretch-max") {
            maxStretch.wrappedValue = 6
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.velocityStretchMax == 6)
        } else { Issue.record("missing max stretch field") }

        if case let .constrainedNumber(maxRenderDistance, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-max-render-distance") {
            maxRenderDistance.wrappedValue = 120
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.maxRenderDistance == 120)
        } else { Issue.record("missing max render distance field") }

        if case let .constrainedNumber(distanceFade, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-distance-fade") {
            distanceFade.wrappedValue = 24
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderDistanceFadeRange == 24)
        } else { Issue.record("missing render distance fade field") }

        if case let .constrainedNumber(lodStart, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-lod-start") {
            lodStart.wrappedValue = 40
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderLODStartDistance == 40)
        } else { Issue.record("missing render LOD start field") }

        if case let .constrainedNumber(lodEnd, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-lod-end") {
            lodEnd.wrappedValue = 120
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderLODEndDistance == 120)
        } else { Issue.record("missing render LOD end field") }

        if case let .constrainedNumber(lodScale, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-lod-min-scale") {
            lodScale.wrappedValue = 0.3
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderLODMinParticleScale == 0.3)
        } else { Issue.record("missing render LOD scale field") }

        if case let .particleRenderBoundsMode(boundsMode) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-bounds-mode") {
            boundsMode.wrappedValue = .automatic
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderBoundsMode == .automatic)
        } else { Issue.record("missing render bounds mode field") }

        if case let .constrainedNumber(boundsRadius, _, _, _, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-bounds-radius") {
            boundsRadius.wrappedValue = 48
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.renderBoundsRadius == 48)
        } else { Issue.record("missing render bounds radius field") }

        if case let .readOnly(estimate) =
            field(adapter, id, section: "particle-emitter", field: "particle-render-bounds-estimate") {
            #expect(!estimate.isEmpty)
        } else { Issue.record("missing render bounds estimate field") }

        if case let .asset(textureAsset, acceptedKinds, _) =
            field(adapter, id, section: "particle-emitter", field: "particle-texture") {
            #expect(acceptedKinds == ["Texture"])
            textureAsset.wrappedValue = EditorInspectorAssetRef(id: "Assets/Textures/smoke.png",
                                                                name: "smoke",
                                                                subtitle: "/tmp/particle-smoke.png",
                                                                kind: "Texture")
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureAssetID == "Assets/Textures/smoke.png")
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.texturePath == "/tmp/particle-smoke.png")
            textureAsset.wrappedValue = nil
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.textureAssetID == nil)
            #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.texturePath == nil)
        } else { Issue.record("missing particle texture asset field") }
    }

    @Test("particle gravity vector and color bindings write back")
    func particleVectorAndColorBindings() throws {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.particleEmitter, to: id)
        let entity = EntityID(rawValue: id)!

        guard case let .vector3(gx, gy, gz) =
                field(adapter, id, section: "particle-emitter", field: "particle-gravity") else {
            Issue.record("expected gravity vector3"); return
        }
        gx.wrappedValue = 1; gy.wrappedValue = -20; gz.wrappedValue = 3
        let g = adapter.scene.component(ParticleEmitter.self, for: entity)?.gravity
        #expect(g == SIMD3<Float>(1, -20, 3))

        guard case let .vector3(bx, by, bz) =
                field(adapter, id, section: "particle-emitter", field: "particle-box-extents") else {
            Issue.record("expected box extents vector3"); return
        }
        bx.wrappedValue = 2; by.wrappedValue = 3; bz.wrappedValue = 4
        let box = adapter.scene.component(ParticleEmitter.self, for: entity)?.boxHalfExtents
        #expect(box == SIMD3<Float>(2, 3, 4))

        guard case let .vector3(fcx, fcy, fcz) =
                field(adapter, id, section: "particle-emitter", field: "particle-force-center") else {
            Issue.record("expected force center vector3"); return
        }
        fcx.wrappedValue = 1; fcy.wrappedValue = 2; fcz.wrappedValue = 3
        let center = adapter.scene.component(ParticleEmitter.self, for: entity)?.forceCenter
        #expect(center == SIMD3<Float>(1, 2, 3))

        guard case let .vector3(fax, fay, faz) =
                field(adapter, id, section: "particle-emitter", field: "particle-force-axis") else {
            Issue.record("expected force axis vector3"); return
        }
        fax.wrappedValue = 0; fay.wrappedValue = 1; faz.wrappedValue = 0
        let axis = adapter.scene.component(ParticleEmitter.self, for: entity)?.forceAxis
        #expect(axis == SIMD3<Float>(0, 1, 0))

        guard case let .vector3(svx, svy, svz) =
                field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-velocity") else {
            Issue.record("expected sub-emitter velocity vector3"); return
        }
        svx.wrappedValue = 1; svy.wrappedValue = 2; svz.wrappedValue = 3
        let subVelocity = adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterStartVelocity
        #expect(subVelocity == SIMD3<Float>(1, 2, 3))

        guard case let .vector3(srx, sry, srz) =
                field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-velocity-random") else {
            Issue.record("expected sub-emitter velocity random vector3"); return
        }
        srx.wrappedValue = 0.1; sry.wrappedValue = 0.2; srz.wrappedValue = 0.3
        let subRandom = adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterVelocityRandomness
        #expect(subRandom == SIMD3<Float>(0.1, 0.2, 0.3))

        guard case let .color(subStart) =
                field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-start-color") else {
            Issue.record("expected sub-emitter start color"); return
        }
        subStart.wrappedValue = Color(r: 1, g: 0.5, b: 0, a: 1)
        let subStartColor = adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterStartColor
        #expect(subStartColor == SIMD4<Float>(1, 0.5, 0, 1))

        guard case let .color(subEnd) =
                field(adapter, id, section: "particle-emitter", field: "particle-sub-emitter-end-color") else {
            Issue.record("expected sub-emitter end color"); return
        }
        subEnd.wrappedValue = Color(r: 1, g: 0, b: 0, a: 0)
        let subEndColor = adapter.scene.component(ParticleEmitter.self, for: entity)?.subEmitterEndColor
        #expect(subEndColor == SIMD4<Float>(1, 0, 0, 0))

        guard case let .color(start) =
                field(adapter, id, section: "particle-emitter", field: "particle-start-color") else {
            Issue.record("expected start color"); return
        }
        start.wrappedValue = Color(r: 1, g: 0, b: 0, a: 1)
        let c = adapter.scene.component(ParticleEmitter.self, for: entity)?.startColor
        #expect(c == SIMD4<Float>(1, 0, 0, 1))
    }
}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(index: UInt32(rawValue & 0xFFFF_FFFF), generation: UInt32(rawValue >> 32))
    }
}
