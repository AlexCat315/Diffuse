import AudioRuntime
import EngineKernel
import Foundation
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    public func currentRenderCamera() -> RenderCamera {
        scene.extractedRenderScene?.scene.camera ?? RenderCamera.fallbackPerspective
    }

    @discardableResult
    public func tickScene(deltaTime: Double = 0,
                          frameIndex: UInt64 = 0,
                          inputEvents: [InputEvent] = [],
                          drivesAudio: Bool = false) -> Bool {
        applyPendingParticleFeedback()
        _ = scene.tick(deltaTime: deltaTime,
                       frameIndex: frameIndex,
                       inputEvents: inputEvents)
        if drivesAudio {
            AudioEngine.shared.tick(scene: scene)
        }
        return true
    }

    public func registerScript(_ script: Script, named name: String? = nil) -> ScriptHandle {
        scriptRuntime.register(script, named: name)
    }

    public func currentSceneSnapshot() -> SceneRuntimeSnapshot {
        scene.snapshot
    }

    public func currentInGameCanvas() -> InGameCanvas {
        scene.resource(InGameCanvas.self) ?? InGameCanvas()
    }

    public func makeParticleSimulationFeedbackHandler()
        -> @Sendable ([GPUParticleSimulationEventSnapshot]) -> Void {
        particleFeedbackLock.lock()
        let generation = particleFeedbackGeneration
        particleFeedbackLock.unlock()
        return { [weak self] snapshots in
            guard !snapshots.isEmpty, let self else { return }
            self.particleFeedbackLock.lock()
            if self.particleFeedbackGeneration == generation {
                self.pendingParticleFeedback.append(contentsOf: snapshots)
            }
            self.particleFeedbackLock.unlock()
        }
    }

    private func applyPendingParticleFeedback() {
        particleFeedbackLock.lock()
        let snapshots = pendingParticleFeedback
        pendingParticleFeedback.removeAll(keepingCapacity: true)
        particleFeedbackLock.unlock()
        guard !snapshots.isEmpty else { return }

        let totalReadbackEventCount = snapshots.reduce(0) { $0 + $1.totalEventCount }
        let droppedReadbackEventCount = snapshots.reduce(0) { $0 + $1.droppedEventCount }
        let gpuAliveParticleCount = snapshots.reduce(0) { $0 + $1.aliveParticleCount }
        let gpuExpiredParticleCount = snapshots.reduce(0) { $0 + $1.expiredParticleCount }
        let gpuCollisionEventCount = snapshots.reduce(0) { $0 + $1.collisionEventCount }
        let gpuSpawnedParticleCount = snapshots.reduce(0) { $0 + $1.gpuSpawnedParticleCount }
        let gpuDroppedSpawnCount = snapshots.reduce(0) { $0 + $1.gpuDroppedSpawnCount }
        let gpuCompactedParticleCount = snapshots.reduce(0) { $0 + $1.compactedParticleCount }
        var eventsByEntity: [EntityID: [ParticleEvent]] = [:]
        for snapshot in snapshots {
            guard let rawValue = snapshot.emitterRawValue else { continue }
            let events = snapshot.makeParticleEvents()
            guard !events.isEmpty else { continue }
            eventsByEntity[EntityID(rawValue: rawValue), default: []].append(contentsOf: events)
        }

        var report = eventsByEntity.isEmpty
            ? ParticleSimulationEventApplyReport.empty
            : scene.applyParticleSimulationEvents(eventsByEntity)
        report.totalReadbackEventCount = totalReadbackEventCount
        report.droppedReadbackEventCount = droppedReadbackEventCount
        report.gpuAliveParticleCount = gpuAliveParticleCount
        report.gpuExpiredParticleCount = gpuExpiredParticleCount
        report.gpuCollisionEventCount = gpuCollisionEventCount
        report.gpuSpawnedParticleCount = gpuSpawnedParticleCount
        report.gpuDroppedSpawnCount = gpuDroppedSpawnCount
        report.gpuCompactedParticleCount = gpuCompactedParticleCount
        scene.applyParticleSimulationReadbackStats(report)
        lastParticleFeedbackReport = report
    }

    public func currentJointPaletteMap() -> JointPaletteMap {
        scene.resource(JointPaletteMap.self) ?? JointPaletteMap()
    }

    public func currentRenderScene() -> RenderScene {
        scene.renderScene
    }

    public func currentParticleFrameStats() -> ParticleFrameStatsResource {
        scene.particleFrameStats
    }

    public func currentParticleSimulationEventApplyReport() -> ParticleSimulationEventApplyReport {
        lastParticleFeedbackReport
    }

    public func currentParticleScalabilityState() -> ParticleScalabilityStateResource {
        scene.particleScalabilityState
    }

    public func currentParticleGPUSimulationPlan(for rawID: UInt64?) -> ParticleGPUSimulationPlan? {
        guard let rawID, let entity = makeEntityID(rawID) else { return nil }
        return scene.component(ParticleEmitter.self, for: entity)?.gpuSimulationPlan
    }

    public func currentParticleModuleValidationIssues(for rawID: UInt64?) -> [ParticleModuleIssue] {
        guard let rawID, let entity = makeEntityID(rawID),
              let emitter = scene.component(ParticleEmitter.self, for: entity)
        else {
            return []
        }
        return emitter.moduleValidationIssues
    }

    public func entityWorldPosition(_ rawID: UInt64) -> SIMD3<Float>? {
        guard let entity = makeEntityID(rawID) else { return nil }
        return scene.worldTransform(for: entity)?.translation
    }

    public func entityWorldMatrix(_ rawID: UInt64) -> simd_float4x4? {
        guard let entity = makeEntityID(rawID) else { return nil }
        return scene.worldTransform(for: entity)?.matrix
    }

    public func entityLocalTranslation(_ rawID: UInt64) -> SIMD3<Float>? {
        guard let entity = makeEntityID(rawID) else { return nil }
        guard let local = scene.localTransform(for: entity) else { return nil }
        return local.translation
    }

    public func setEntityLocalTranslation(_ rawID: UInt64, to value: SIMD3<Float>) {
        guard let entity = makeEntityID(rawID) else { return }
        var local = scene.localTransform(for: entity) ?? LocalTransform()
        local.matrix.columns.3 = SIMD4<Float>(value.x, value.y, value.z, 1)
        _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                  summary: "Update entity translation",
                                  targetRawIDs: [rawID],
                                  mutations: [.setLocalTransform(entityID: rawID, transform: local)])
    }

    public func entityLocalMatrix(_ rawID: UInt64) -> simd_float4x4? {
        guard let entity = makeEntityID(rawID) else { return nil }
        return scene.localTransform(for: entity)?.matrix
    }

    public func entityParentWorldMatrix(_ rawID: UInt64) -> simd_float4x4 {
        guard let entity = makeEntityID(rawID),
              let parent = scene.parent(of: entity),
              let parentWorld = scene.worldTransform(for: parent)
        else {
            return matrix_identity_float4x4
        }
        return parentWorld.matrix
    }

    public func entityHasAncestor(_ rawID: UInt64, in candidateRawIDs: Set<UInt64>) -> Bool {
        guard var current = makeEntityID(rawID).flatMap({ scene.parent(of: $0) }) else {
            return false
        }
        while true {
            if candidateRawIDs.contains(current.rawValue) {
                return true
            }
            guard let parent = scene.parent(of: current) else {
                return false
            }
            current = parent
        }
    }

    public func setEntityLocalMatrix(_ rawID: UInt64, to matrix: simd_float4x4) {
        _ = setEntityLocalMatrices([rawID: matrix])
    }

    /// Applies a multi-selection transform atomically. This prevents a locked
    /// or stale member from leaving only part of the selection transformed.
    @discardableResult
    public func setEntityLocalMatrices(_ matricesByEntityID: [UInt64: simd_float4x4]) -> Bool {
        let entityIDs = matricesByEntityID.keys.sorted()
        guard !entityIDs.isEmpty else { return false }
        var mutations: [SceneMutation] = []
        mutations.reserveCapacity(entityIDs.count)
        for rawID in entityIDs {
            guard let matrix = matricesByEntityID[rawID],
                  let entity = makeEntityID(rawID),
                  scene.contains(entity) else { return false }
            var local = scene.localTransform(for: entity) ?? LocalTransform()
            local.matrix = matrix
            mutations.append(.setLocalTransform(entityID: rawID, transform: local))
        }
        return applySceneTransaction(
            intentVerb: entityIDs.count == 1 ? "scene.set_local_transform" : "scene.set_local_transforms",
            summary: entityIDs.count == 1 ? "Update entity transform" : "Update entity transforms",
            targetRawIDs: entityIDs,
            mutations: mutations
        ) != nil
    }

    private func makeEntityID(_ rawID: UInt64) -> EntityID? {
        EntityID(
            index: UInt32(rawID & 0xFFFF_FFFF),
            generation: UInt32(rawID >> 32)
        )
    }
}
