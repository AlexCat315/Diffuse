import AIRuntime
import ContextMemory
import AssetPipeline
import AudioRuntime
import CapabilityRuntime
import EngineCore
import EngineKernel
import IntentRuntime
import ObservationBus
import PerceptionRuntime
import PluginRuntime
import SemanticPipeline
import RenderBackend
import RHIWGPU
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat

extension EditorApplication {
    public func currentRenderStats() -> RenderFrameStats {
        engine.currentRenderStats()
    }

    public func currentRenderScene() -> RenderScene {
        scene.currentRenderScene()
    }

    public func currentParticleFrameStats() -> ParticleFrameStatsResource {
        scene.currentParticleFrameStats()
    }

    public func currentParticleSimulationEventApplyReport() -> ParticleSimulationEventApplyReport {
        scene.currentParticleSimulationEventApplyReport()
    }

    public func currentParticleScalabilityState() -> ParticleScalabilityStateResource {
        scene.currentParticleScalabilityState()
    }

    public func currentViewportSurfaceState() -> ViewportSurfaceState {
        engine.currentViewportSurfaceState()
    }

    public func currentFrameStats() -> EditorFrameStats {
        store.state.timing.frameStats
    }

    func makeParticleDiagnosticsSample() -> EditorParticleDiagnosticsSample {
        let stats = scene.currentParticleFrameStats()
        let eventReport = scene.currentParticleSimulationEventApplyReport()
        let renderSummary = scene.currentRenderScene().particleSummary
        let renderStats = engine.currentRenderStats()
        let nextSampleIndex = (store.state.timing.particleDiagnosticsHistory.last?.sampleIndex ?? 0) &+ 1
        return EditorParticleDiagnosticsSample(
            sampleIndex: nextSampleIndex,
            frameIndex: store.state.timing.frameIndex,
            simulatedDeltaTime: stats.simulatedDeltaTime,
            emitterCount: stats.emitterCount,
            activeEmitterCount: stats.activeEmitterCount,
            liveParticleCount: stats.liveParticleCount,
            liveParticleLimit: stats.liveParticleLimit,
            requestedSpawnCount: stats.requestedSpawnCount,
            spawnedParticleCount: stats.spawnedParticleCount,
            droppedSpawnCount: stats.droppedSpawnCount,
            capacityLimitedSpawnCount: stats.capacityLimitedSpawnCount,
            spawnBudgetLimitedCount: stats.spawnBudgetLimitedCount,
            spawnBudgetConsumedCount: stats.spawnBudgetConsumedCount,
            spawnBudgetLimit: stats.spawnBudgetLimit,
            eventRequestedSpawnCount: eventReport.requestedSpawnCount,
            eventDroppedSpawnCount: eventReport.droppedSpawnCount,
            droppedReadbackEventCount: eventReport.droppedReadbackEventCount,
            cpuRenderInstanceCount: renderSummary.cpuRenderInstanceCount,
            gpuRenderInstanceCount: renderSummary.gpuRenderInstanceCount,
            cpuBatchCount: renderSummary.cpuBatchCount,
            gpuBatchCount: renderSummary.gpuBatchCount,
            gpuSimulationParticleCount: renderStats.gpuParticleSimulationParticleCount,
            gpuWorkgroupCount: particleGPUWorkgroupTotal(renderStats),
            gpuSortItemCount: renderStats.gpuParticleSortItemCount,
            gpuSortPaddedItemCount: renderStats.gpuParticleSortPaddedItemCount
        )
    }

    private func particleGPUWorkgroupTotal(_ stats: RenderFrameStats) -> Int {
        stats.gpuParticleSimulationDispatchWorkgroups
            + stats.gpuParticleSortDispatchWorkgroups
            + stats.gpuParticleInstanceDispatchWorkgroups
            + stats.gpuParticleCullDispatchWorkgroups
    }

    /// Accumulates raw delta time and dispatches `EditorFrameStats` when the
    /// diagnostics averaging window is full. Combines:
    ///   - PhaseTimings from EngineHost (input / simulation / renderPrepare / renderSubmit)
    ///   - GPU present time from the render completion handler
    ///   - RenderFrameStats from the GPU backend (draw calls, passes, etc.)
    func recordAndDispatchFrameStats(deltaTime: Double,
                                              simulationDelta: Double) -> Bool {
        guard deltaTime.isFinite, deltaTime > 0 else { return false }
        frameTimingAccumulator += deltaTime
        frameTimingCount += 1
        guard frameTimingAccumulator >= Self.frameStatsDispatchInterval else { return false }

        let phaseTimings = engine.lastTimings
        let renderStats = lastRenderFrameStats

        let frameSeconds = frameTimingAccumulator / Double(frameTimingCount)

        let stats = EditorFrameStats(
            frameSeconds: frameSeconds,
            inputSeconds: phaseTimings.inputSeconds,
            simulationSeconds: phaseTimings.simulationSeconds,
            renderPrepareSeconds: phaseTimings.renderPrepareSeconds,
            renderSubmitSeconds: phaseTimings.renderSubmitSeconds,
            gpuPresentSeconds: lastRenderSubmitSeconds,
            drawCallCount: renderStats.drawCallCount,
            passCount: renderStats.passCount,
            renderBundleCount: renderStats.renderBundleCount,
            shadowedLightCount: renderStats.shadowedLightCount,
            shadowCascadeCount: renderStats.shadowCascadeCount,
            shadowMapResolution: renderStats.shadowMapResolution,
            cpuSkyboxEncodeNS: renderStats.cpuSkyboxEncodeNS,
            cpuBaseEncodeNS: renderStats.cpuBaseEncodeNS,
            cpuPostProcessEncodeNS: renderStats.cpuPostProcessEncodeNS
        )

        store.dispatch(.updateFrameStats(stats))

        // Reset the averaging window.
        frameTimingAccumulator = 0
        frameTimingCount = 0
        return true
    }
}
