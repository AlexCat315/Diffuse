@testable import EditorCore
import RenderBackend
import SceneRuntime
import Testing

@Suite("Particle feedback scene lifetime", .serialized)
struct ParticleFeedbackLifetimeTests {
    @Test("readback counters reach the editor report")
    func readbackReport() {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        adapter.makeParticleSimulationFeedbackHandler()([snapshot])
        adapter.tickScene()
        let report = adapter.currentParticleSimulationEventApplyReport()
        #expect(report.totalReadbackEventCount == 9)
        #expect(report.droppedReadbackEventCount == 1)
        #expect(report.gpuAliveParticleCount == 8)
        #expect(report.gpuExpiredParticleCount == 2)
        #expect(report.gpuCollisionEventCount == 3)
        #expect(report.gpuSpawnedParticleCount == 4)
        #expect(report.gpuDroppedSpawnCount == 5)
        #expect(report.gpuCompactedParticleCount == 6)
    }

    @Test("scene replacement discards queued and late callbacks but accepts a new handler",
          arguments: ["reset", "load", "undo", "edit"])
    func invalidatedFeedback(operation: String) throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let entity = adapter.scene.createEntity()
        adapter.resetEditHistory()
        if operation == "undo" {
            #expect(adapter.addComponent("light", to: entity.rawValue))
        }
        let handler = adapter.makeParticleSimulationFeedbackHandler()
        handler([snapshot])
        adapter.tickScene()
        #expect(adapter.currentParticleSimulationEventApplyReport().totalReadbackEventCount == 9)
        handler([snapshot]) // Queued feedback from the previous authored scene.
        switch operation {
        case "reset": adapter.resetToPreviewScene()
        case "load": #expect(adapter.load(manifest: adapter.manifest()).succeeded)
        case "undo":
            #expect(adapter.undoEdit())
        default: #expect(adapter.addComponent("light", to: entity.rawValue))
        }
        #expect(adapter.currentParticleSimulationEventApplyReport() == .empty)
        handler([snapshot]) // A render-thread callback can arrive after replacement.
        adapter.tickScene()
        #expect(adapter.currentParticleSimulationEventApplyReport() == .empty)
        adapter.makeParticleSimulationFeedbackHandler()([snapshot])
        adapter.tickScene()
        #expect(adapter.currentParticleSimulationEventApplyReport().totalReadbackEventCount == 9)
    }

    private var snapshot: GPUParticleSimulationEventSnapshot {
        GPUParticleSimulationEventSnapshot(slot: 0, emitterRawValue: nil, eventCapacity: 8,
            totalEventCount: 9, droppedEventCount: 1, records: [], aliveParticleCount: 8,
            expiredParticleCount: 2, collisionEventCount: 3, gpuSpawnedParticleCount: 4,
            gpuDroppedSpawnCount: 5, compactedParticleCount: 6)
    }
}
