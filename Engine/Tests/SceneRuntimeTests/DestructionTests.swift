import SceneRuntime
import SIMDCompat
import Testing

@Suite("Pre-fractured destruction")
struct DestructionTests {
    private let resourceID = "wall.prefractured"

    private func makeRuntime(
        fragmentBudget: Int = 8,
        maximumLifetime: Float = 30,
        sleepingRecycleDelay: Float = 5,
        connectionImpulseThreshold: Float = 0
    ) -> (SceneRuntime, EntityID) {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .jolt,
            gravity: .zero,
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            capacity: PhysicsCapacitySettings(workerThreadCount: 1)
        ))
        let geometry = MeshColliderGeometry(
            positions: [
                SIMD3<Float>(-0.2, -0.2, -0.2),
                SIMD3<Float>(0.2, -0.2, -0.2),
                SIMD3<Float>(0, 0.2, -0.2),
                SIMD3<Float>(0, 0, 0.2),
            ],
            triangleIndices: [0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3]
        )
        var fragments: [DestructibleFragmentAsset] = []
        for index in 0..<3 {
            let resourceID = "fragment.\(index)"
            let translation = SIMD3<Float>(Float(index - 1) * 0.5, 0, 0)
            fragments.append(DestructibleFragmentAsset(
                fragmentID: UInt32(index),
                colliderResourceID: resourceID,
                localTransform: LocalTransform(translation: translation),
                mass: Float(index + 1)
            ))
        }
        let asset = DestructibleAsset(
            revision: 7,
            fragments: fragments,
            connections: [
                DestructibleConnectionAsset(
                    connectionID: 10,
                    fragmentA: 0,
                    fragmentB: 1,
                    impulseThreshold: connectionImpulseThreshold
                ),
                DestructibleConnectionAsset(
                    connectionID: 11,
                    fragmentA: 1,
                    fragmentB: 2,
                    impulseThreshold: 50
                ),
            ]
        )
        runtime.setResource(MeshColliderGeometryResource(geometryByResourceID: [
            "fragment.0": geometry,
            "fragment.1": geometry,
            "fragment.2": geometry,
        ]))
        runtime.setResource(DestructibleAssetResource(assetsByResourceID: [resourceID: asset]))

        let source = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(2, 3, 4)),
            for: source
        )
        _ = runtime.setComponent(
            Collider(
                shape: .box(halfExtents: SIMD3<Float>(0.75, 0.5, 0.5), center: .zero),
                layerID: 3,
                material: PhysicsMaterial(friction: 0.8, restitution: 0.1)
            ),
            for: source
        )
        _ = runtime.setComponent(RigidBody(motionType: .static), for: source)
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 42), for: source)
        _ = runtime.setComponent(
            Destructible(
                assetResourceID: resourceID,
                damageThreshold: 10,
                impulseThreshold: 10,
                fragmentBudget: fragmentBudget,
                maximumFragmentLifetimeSeconds: maximumLifetime,
                sleepingRecycleDelaySeconds: sleepingRecycleDelay,
                separationImpulse: 0
            ),
            for: source
        )
        return (runtime, source)
    }

    @Test("damage accumulates and fragments participate in the current physics prepare")
    func currentFrameActivation() throws {
        var (runtime, source) = makeRuntime()
        runtime.submitDestructionCommand(DestructionCommand(entity: source, damage: 4))
        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(runtime.destructionEventFrame.events.isEmpty)
        #expect(runtime.destructionStateFrame.sources[source]?.accumulatedDamage == 4)

        runtime.submitDestructionCommand(DestructionCommand(entity: source, damage: 6))
        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        let event = try #require(runtime.destructionEventFrame.events.first)
        #expect(event.cause == .damage)
        #expect(event.fragmentIDs == [0, 1, 2])
        #expect(event.brokenConnectionIDs == [10, 11])
        #expect(report.physicsBodyCount == 3)
        #expect(runtime.component(Collider.self, for: source) == nil)
        #expect(runtime.component(RigidBody.self, for: source) == nil)
        #expect(runtime.component(RenderMeshComponent.self, for: source)?.isVisible == false)
        #expect(runtime.destructionStateFrame.sources[source]?.hasFractured == true)
        #expect(runtime.destructionStateFrame.activeFragmentCount == 3)
        for (index, entity) in event.fragmentEntities.enumerated() {
            #expect(runtime.component(DestructibleFragment.self, for: entity)?.fragmentID == UInt32(index))
            #expect(runtime.component(RigidBody.self, for: entity)?.motionType == .dynamic)
            #expect(runtime.component(Collider.self, for: entity)?.layerID == 3)
        }
        let positions = event.fragmentEntities.compactMap {
            runtime.worldTransform(for: $0)?.translation.x
        }
        #expect(positions == [1.5, 2, 2.5])
    }

    @Test("a low-threshold connection can detach before the entity threshold")
    func connectionGraphActivation() throws {
        var (runtime, source) = makeRuntime(connectionImpulseThreshold: 2)
        runtime.submitDestructionCommand(DestructionCommand(
            entity: source,
            impulse: SIMD3<Float>(3, 0, 0)
        ))
        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        let event = try #require(runtime.destructionEventFrame.events.first)
        #expect(event.cause == .connectionBreak)
        #expect(event.appliedImpulse == 3)
        #expect(event.brokenConnectionIDs == [10, 11])
    }

    @Test("fragment budgets use stable fragment-ID truncation")
    func stableBudget() throws {
        var (runtime, source) = makeRuntime(fragmentBudget: 2)
        runtime.setResource(DestructionSettingsResource(maximumActiveFragmentCount: 2))
        runtime.submitDestructionCommand(DestructionCommand(entity: source, forceFracture: true))
        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        let event = try #require(runtime.destructionEventFrame.events.first)
        #expect(event.fragmentIDs == [0, 1])
        #expect(event.droppedFragmentCount == 1)
        #expect(runtime.destructionStateFrame.activeFragmentCount == 2)
    }

    @Test("Jolt contact impulses trigger destruction through the unified listener")
    func contactImpulseActivation() throws {
        var (runtime, source) = makeRuntime()
        _ = runtime.updateComponent(Destructible.self, for: source) {
            $0.damageThreshold = 10_000
            $0.impulseThreshold = 0.01
        }
        let projectile = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(2, 3, 0)),
            for: projectile
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.35, center: .zero)),
            for: projectile
        )
        _ = runtime.setComponent(
            RigidBody(
                mass: 2,
                linearVelocity: SIMD3<Float>(0, 0, 20),
                allowSleep: false,
                continuousCollisionDetection: true
            ),
            for: projectile
        )
        var destructionEvent: DestructionEvent?
        for frame in 0..<30 where destructionEvent == nil {
            let report = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
            #expect(report.physicsError == nil)
            destructionEvent = runtime.destructionEventFrame.events.first
        }
        let event = try #require(destructionEvent)
        #expect(event.sourceEntity == source)
        #expect(event.cause == .contactImpulse)
        #expect(event.appliedImpulse > 0)
    }

    @Test("missing and invalid assets fail without replacing the intact body")
    func invalidAssets() throws {
        var (runtime, source) = makeRuntime()
        _ = runtime.updateComponent(Destructible.self, for: source) {
            $0.assetResourceID = "missing.asset"
        }
        runtime.submitDestructionCommand(DestructionCommand(entity: source, forceFracture: true))
        _ = runtime.tick(deltaTime: 0)
        #expect(runtime.destructionEventFrame.failures.first?.reason == .missingAsset)
        #expect(runtime.component(Collider.self, for: source) != nil)
        #expect(runtime.component(RigidBody.self, for: source) != nil)

        _ = runtime.updateComponent(Destructible.self, for: source) {
            $0.assetResourceID = resourceID
        }
        var assets = try #require(runtime.resource(DestructibleAssetResource.self))
        assets.assetsByResourceID[resourceID]?.connections[0].damageThreshold = .nan
        runtime.setResource(assets)
        runtime.submitDestructionCommand(DestructionCommand(entity: source, forceFracture: true))
        _ = runtime.tick(deltaTime: 0)
        #expect(runtime.destructionEventFrame.failures.first?.reason == .invalidAsset)
        #expect(runtime.component(RigidBody.self, for: source) != nil)

        assets.assetsByResourceID[resourceID]?.connections[0].damageThreshold = 0
        runtime.setResource(assets)
        runtime.setResource(MeshColliderGeometryResource())
        runtime.submitDestructionCommand(DestructionCommand(entity: source, forceFracture: true))
        _ = runtime.tick(deltaTime: 0)
        #expect(runtime.destructionEventFrame.failures.first?.reason == .invalidAsset)
        #expect(runtime.component(Collider.self, for: source) != nil)
    }

    @Test("non-finite commands and mutated policies fail before replacing the intact body")
    func invalidCommandAndConfiguration() {
        var (runtime, source) = makeRuntime()
        var invalidCommand = DestructionCommand(entity: source, forceFracture: true)
        invalidCommand.damage = .nan
        runtime.submitDestructionCommand(invalidCommand)
        _ = runtime.tick(deltaTime: 0)
        #expect(runtime.destructionEventFrame.failures.first?.reason == .invalidCommand)
        #expect(runtime.component(RigidBody.self, for: source) != nil)

        _ = runtime.updateComponent(Destructible.self, for: source) {
            $0.separationImpulse = .infinity
        }
        runtime.submitDestructionCommand(DestructionCommand(entity: source, forceFracture: true))
        _ = runtime.tick(deltaTime: 0)
        #expect(runtime.destructionEventFrame.failures.first?.reason == .invalidConfiguration)
        #expect(runtime.component(Collider.self, for: source) != nil)
        #expect(runtime.component(RigidBody.self, for: source) != nil)
    }

    @Test("fragments recycle after their maximum lifetime")
    func lifetimeRecycle() throws {
        var (runtime, source) = makeRuntime(maximumLifetime: 0.02, sleepingRecycleDelay: 0)
        runtime.submitDestructionCommand(DestructionCommand(entity: source, forceFracture: true))
        _ = runtime.tick(deltaTime: 0.001)
        let fragments = try #require(runtime.destructionEventFrame.events.first?.fragmentEntities)
        _ = runtime.tick(deltaTime: 0.03)
        #expect(runtime.destructionEventFrame.recycledFragments.count == 3)
        #expect(runtime.destructionEventFrame.recycledFragments.allSatisfy { $0.reason == .lifetimeExpired })
        #expect(fragments.allSatisfy { !runtime.contains($0) })
        #expect(runtime.destructionStateFrame.activeFragmentCount == 0)
    }

    @Test("sleeping and removed-source policies recycle owned fragments")
    func sleepingAndSourceRecycle() throws {
        var (runtime, source) = makeRuntime(maximumLifetime: 0, sleepingRecycleDelay: 0.01)
        runtime.submitDestructionCommand(DestructionCommand(entity: source, forceFracture: true))
        _ = runtime.tick(deltaTime: 0.001)
        let fragments = try #require(runtime.destructionEventFrame.events.first?.fragmentEntities)
        for fragment in fragments {
            let slept = runtime.sleepRigidBody(fragment)
            #expect(slept)
        }
        _ = runtime.tick(deltaTime: 0.001)
        _ = runtime.tick(deltaTime: 0.02)
        #expect(runtime.destructionEventFrame.recycledFragments.allSatisfy { $0.reason == .sleeping })

        var (secondRuntime, secondSource) = makeRuntime(maximumLifetime: 0, sleepingRecycleDelay: 0)
        secondRuntime.submitDestructionCommand(DestructionCommand(entity: secondSource, forceFracture: true))
        _ = secondRuntime.tick(deltaTime: 0)
        let secondFragments = try #require(secondRuntime.destructionEventFrame.events.first?.fragmentEntities)
        let destroyed = secondRuntime.destroyEntity(secondSource)
        #expect(destroyed)
        _ = secondRuntime.tick(deltaTime: 0)
        #expect(secondRuntime.destructionEventFrame.recycledFragments.allSatisfy { $0.reason == .sourceRemoved })
        #expect(secondFragments.allSatisfy { !secondRuntime.contains($0) })
    }

    @Test("authored destructible policy survives scene serialization")
    func serialization() throws {
        var runtime = SceneRuntime()
        let entity = runtime.createEntity()
        let destructible = Destructible(
            assetResourceID: "tower.fracture",
            damageThreshold: 75,
            impulseThreshold: 12,
            fragmentBudget: 128,
            maximumFragmentLifetimeSeconds: 20,
            sleepingRecycleDelaySeconds: 3,
            separationImpulse: 0.2,
            isEnabled: false
        )
        _ = runtime.setComponent(destructible, for: entity)
        let data = try SceneSerializer.serialize(runtime)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        let restoredEntity = try #require(restored.entities().first)
        #expect(restored.component(Destructible.self, for: restoredEntity) == destructible)
        #expect(restored.entities(with: DestructibleFragment.self).isEmpty)
    }

    @Test("authored scene capture after fracture restores the intact source only")
    func fracturedSceneCaptureRestoresAuthoredSource() throws {
        var (runtime, source) = makeRuntime()
        let authoredBody = try #require(runtime.component(RigidBody.self, for: source))
        let authoredCollider = try #require(runtime.component(Collider.self, for: source))
        let authoredMesh = try #require(runtime.component(RenderMeshComponent.self, for: source))

        runtime.submitDestructionCommand(DestructionCommand(
            entity: source,
            forceFracture: true
        ))
        _ = runtime.tick(deltaTime: 0)
        #expect(runtime.entities(with: DestructibleFragment.self).count == 3)

        let data = try SceneSerializer.serialize(runtime)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)

        let restoredSource = try #require(restored.entities(with: Destructible.self).first)
        #expect(restored.entities().count == 1)
        #expect(restored.entities(with: DestructibleFragment.self).isEmpty)
        #expect(restored.component(RigidBody.self, for: restoredSource) == authoredBody)
        #expect(restored.component(Collider.self, for: restoredSource) == authoredCollider)
        #expect(restored.component(RenderMeshComponent.self, for: restoredSource) == authoredMesh)
    }

    @Test("prefab capture after fracture restores the intact source and rejects fragment roots")
    func fracturedPrefabCaptureRestoresAuthoredSource() throws {
        var (runtime, source) = makeRuntime()
        let authoredCollider = try #require(runtime.component(Collider.self, for: source))
        runtime.submitDestructionCommand(DestructionCommand(
            entity: source,
            forceFracture: true
        ))
        _ = runtime.tick(deltaTime: 0)
        let fragment = try #require(runtime.entities(with: DestructibleFragment.self).first)

        #expect(try Prefab.capture(from: runtime, root: fragment) == nil)
        let prefab = try #require(try Prefab.capture(from: runtime, root: source))
        var restored = SceneRuntime()
        let restoredSource = try #require(try prefab.instantiate(into: &restored))

        #expect(restored.entities().count == 1)
        #expect(restored.entities(with: DestructibleFragment.self).isEmpty)
        #expect(restored.component(RigidBody.self, for: restoredSource)?.motionType == .static)
        #expect(restored.component(Collider.self, for: restoredSource) == authoredCollider)
        #expect(restored.component(RenderMeshComponent.self, for: restoredSource)?.isVisible == true)
    }

    @Test("game save preserves fractured ownership, source snapshot, damage, and remaining lifetime")
    func fracturedGameSaveRoundTrip() throws {
        var (runtime, source) = makeRuntime(maximumLifetime: 1, sleepingRecycleDelay: 0)
        runtime.submitDestructionCommand(DestructionCommand(entity: source, damage: 4))
        _ = runtime.tick(deltaTime: 0)
        runtime.submitDestructionCommand(DestructionCommand(
            entity: source,
            forceFracture: true
        ))
        _ = runtime.tick(deltaTime: 0.1)
        _ = runtime.tick(deltaTime: 0.35)
        let movingFragment = try #require(
            runtime.entities(with: DestructibleFragment.self).first {
                runtime.component(DestructibleFragment.self, for: $0)?.fragmentID == 0
            }
        )
        _ = runtime.updateComponent(RigidBody.self, for: movingFragment) {
            $0.linearVelocity = SIMD3<Float>(7, 8, 9)
            $0.angularVelocity = SIMD3<Float>(1, 2, 3)
            $0.accumulatedLinearImpulse = SIMD3<Float>(4, 5, 6)
        }
        let savedFragmentBody = try #require(
            runtime.component(RigidBody.self, for: movingFragment)
        )

        let save = try GameSave.capture(scene: runtime)
        let loaded = try GameSave.load(save.serialized())
        var restored = SceneRuntime()
        _ = restored.createEntity() // Prove ownership references are relocatable.
        try loaded.restoreScene(into: &restored)

        let restoredSource = try #require(restored.entities(with: Destructible.self).first)
        let fragments = restored.entities(with: DestructibleFragment.self)
        #expect(restored.entities().count == 5)
        #expect(fragments.count == 3)
        #expect(restored.component(RigidBody.self, for: restoredSource) == nil)
        #expect(restored.component(Collider.self, for: restoredSource) == nil)
        #expect(restored.component(RenderMeshComponent.self, for: restoredSource)?.isVisible == false)
        #expect(fragments.allSatisfy {
            restored.component(DestructibleFragment.self, for: $0)?.sourceEntity == restoredSource
        })
        #expect(fragments.compactMap {
            restored.component(DestructibleFragment.self, for: $0)?.fragmentID
        }.sorted() == [0, 1, 2])
        let restoredMovingFragment = try #require(fragments.first {
            restored.component(DestructibleFragment.self, for: $0)?.fragmentID == 0
        })
        #expect(restored.component(RigidBody.self, for: restoredMovingFragment) == savedFragmentBody)

        _ = restored.tick(deltaTime: 0)
        #expect(restored.destructionStateFrame.sources[restoredSource]?.hasFractured == true)
        #expect(restored.destructionStateFrame.sources[restoredSource]?.accumulatedDamage == 4)
        #expect(restored.destructionStateFrame.activeFragmentCount == 3)

        // Scene capture from a loaded game still has the authored source snapshot.
        let authoredData = try SceneSerializer.serialize(restored)
        var authoredRestore = SceneRuntime()
        try SceneSerializer.deserialize(authoredData, into: &authoredRestore)
        let authoredSource = try #require(
            authoredRestore.entities(with: Destructible.self).first
        )
        #expect(authoredRestore.entities(with: DestructibleFragment.self).isEmpty)
        #expect(authoredRestore.component(RigidBody.self, for: authoredSource)?.motionType == .static)
        #expect(authoredRestore.component(Collider.self, for: authoredSource) != nil)
        #expect(authoredRestore.component(RenderMeshComponent.self, for: authoredSource)?.isVisible == true)

        _ = restored.tick(deltaTime: 0.60)
        #expect(restored.entities(with: DestructibleFragment.self).count == 3)
        _ = restored.tick(deltaTime: 0.06)
        #expect(restored.entities(with: DestructibleFragment.self).isEmpty)
    }

    @Test("destruction commands are captured by deterministic physics recording")
    func recording() throws {
        var (runtime, source) = makeRuntime()
        runtime.beginPhysicsCommandRecording(maxFrames: 2)
        runtime.submitDestructionCommand(DestructionCommand(
            entity: source,
            damage: 3,
            impulse: SIMD3<Float>(1, 2, 3),
            worldPoint: SIMD3<Float>(2, 3, 4)
        ))
        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        let tape = runtime.endPhysicsCommandRecording()
        let frame = try #require(tape.frames.first)
        #expect(frame.destructionCommands.count == 1)
        #expect(frame.destructionCommands.first?.entity == source)
        #expect(frame.destructionCommands.first?.damage == 3)
    }

    @Test("event capacity reports overflow without changing stable command order")
    func eventCapacityOverflow() throws {
        var (runtime, firstSource) = makeRuntime()
        _ = runtime.updateComponent(Destructible.self, for: firstSource) {
            $0.assetResourceID = "missing.first"
        }
        let secondSource = runtime.createEntity()
        _ = runtime.setComponent(
            Destructible(assetResourceID: "missing.second"),
            for: secondSource
        )
        runtime.setResource(DestructionSettingsResource(
            maximumActiveFragmentCount: 8,
            maximumEventCountPerFrame: 1
        ))
        runtime.submitDestructionCommand(DestructionCommand(
            entity: secondSource,
            forceFracture: true
        ))
        runtime.submitDestructionCommand(DestructionCommand(
            entity: firstSource,
            forceFracture: true
        ))

        _ = runtime.tick(deltaTime: 0)

        let failure = try #require(runtime.destructionEventFrame.failures.first)
        #expect(failure.sourceEntity == firstSource)
        #expect(runtime.destructionEventFrame.failures.count == 1)
        #expect(runtime.destructionEventFrame.didOverflow)
    }

    @Test("recorded damage and fracture replay to identical destruction hashes")
    func deterministicReplay() throws {
        var (recordingRuntime, source) = makeRuntime()
        recordingRuntime.beginPhysicsCommandRecording(maxFrames: 4)
        recordingRuntime.submitDestructionCommand(DestructionCommand(entity: source, damage: 4))
        _ = recordingRuntime.tick(deltaTime: 1.0 / 60.0)
        recordingRuntime.submitDestructionCommand(DestructionCommand(entity: source, damage: 6))
        _ = recordingRuntime.tick(deltaTime: 1.0 / 60.0)
        let expectedState = recordingRuntime.destructionStateFrame
        let tape = recordingRuntime.endPhysicsCommandRecording()
        #expect(tape.frames.count == 2)
        #expect(tape.frames[0].expectedStateHash != tape.frames[1].expectedStateHash)

        var (replayRuntime, replaySource) = makeRuntime()
        #expect(replaySource == source)
        let replay = replayRuntime.replayPhysicsCommands(tape)

        #expect(replay.isDeterministic)
        #expect(replay.replayedFrameCount == 2)
        #expect(replayRuntime.destructionStateFrame == expectedState)
        #expect(replayRuntime.destructionStateFrame.sources[replaySource]?.activeFragmentIDs == [0, 1, 2])
    }
}
