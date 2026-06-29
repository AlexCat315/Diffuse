@testable import EditorApp
import EditorCore
import RenderBackend
import SceneRuntime
import Testing

@Suite("Developer particle diagnostics")
struct DeveloperParticleDiagnosticsTests {

    @Test("capacity-limited spawns are reported as a critical particle health issue")
    func capacityLimitedSpawnsAreCritical() {
        let stats = ParticleFrameStatsResource(emitterStats: [
            ParticleEmitterFrameStats(liveParticleCount: 64,
                                      maxParticleCount: 64,
                                      liveParticleLimit: 64,
                                      continuousSpawnedCount: 8,
                                      requestedSpawnCount: 12,
                                      spawnBudgetConsumedCount: 12,
                                      capacityLimitedSpawnCount: 4),
        ])

        let summary = makeDeveloperParticleDiagnosticSummary(
            stats: stats,
            eventReport: .empty,
            scalability: .default,
            renderSummary: ParticleRenderSummary(particleCount: 64,
                                                 cpuRenderInstanceCount: 64,
                                                 batchCount: 1,
                                                 cpuBatchCount: 1),
            renderStats: .init()
        )

        #expect(summary.severity == .critical)
        #expect(summary.status == "Particle capacity saturated")
        #expect(summary.primarySignal.contains("4"))
        #expect(summary.recommendation.contains("Raise max particles"))
    }

    @Test("spawn-budget drops are reported separately from capacity saturation")
    func spawnBudgetDropsAreDistinct() {
        let stats = ParticleFrameStatsResource(emitterStats: [
            ParticleEmitterFrameStats(liveParticleCount: 3,
                                      maxParticleCount: 100,
                                      liveParticleLimit: 100,
                                      continuousSpawnedCount: 3,
                                      requestedSpawnCount: 10,
                                      spawnBudgetLimit: 3,
                                      spawnBudgetConsumedCount: 3,
                                      spawnBudgetLimitedCount: 7),
        ])

        let summary = makeDeveloperParticleDiagnosticSummary(
            stats: stats,
            eventReport: .empty,
            scalability: .default,
            renderSummary: ParticleRenderSummary(particleCount: 3,
                                                 cpuRenderInstanceCount: 3,
                                                 batchCount: 1,
                                                 cpuBatchCount: 1),
            renderStats: .init()
        )

        #expect(summary.severity == .warning)
        #expect(summary.status == "Spawn budget throttling")
        #expect(summary.primarySignal.contains("7"))
        #expect(summary.recommendation.contains("Max Spawn / Frame"))
    }

    @Test("GPU event readback overflow takes priority over spawn diagnostics")
    func gpuReadbackOverflowIsCritical() {
        let stats = ParticleFrameStatsResource(emitterStats: [
            ParticleEmitterFrameStats(liveParticleCount: 16,
                                      maxParticleCount: 64,
                                      liveParticleLimit: 64,
                                      continuousSpawnedCount: 4),
        ])
        let eventReport = ParticleSimulationEventApplyReport(
            appliedEventCount: 8,
            totalReadbackEventCount: 12,
            droppedReadbackEventCount: 4,
            subEmitterSpawnedCount: 2
        )

        let summary = makeDeveloperParticleDiagnosticSummary(
            stats: stats,
            eventReport: eventReport,
            scalability: .default,
            renderSummary: ParticleRenderSummary(particleCount: 16,
                                                 cpuRenderInstanceCount: 16,
                                                 batchCount: 1,
                                                 cpuBatchCount: 1),
            renderStats: .init()
        )

        #expect(summary.severity == .critical)
        #expect(summary.status == "GPU event readback overflow")
        #expect(summary.primarySignal.contains("4"))
    }

    @Test("healthy GPU particles report the GPU path and useful follow-up signals")
    func healthyGPUParticlesReportGPUPath() {
        let stats = ParticleFrameStatsResource(emitterStats: [
            ParticleEmitterFrameStats(liveParticleCount: 512,
                                      maxParticleCount: 2_048,
                                      liveParticleLimit: 2_048,
                                      continuousSpawnedCount: 64,
                                      requestedSpawnCount: 64),
        ])
        let renderSummary = ParticleRenderSummary(particleCount: 512,
                                                  cpuRenderInstanceCount: 0,
                                                  gpuRenderInstanceCount: 512,
                                                  batchCount: 2,
                                                  cpuBatchCount: 0,
                                                  gpuBatchCount: 2)
        let renderStats = RenderFrameStats(gpuParticleSimulationDispatchWorkgroups: 8,
                                           gpuParticleSortDispatchWorkgroups: 4,
                                           gpuParticleInstanceDispatchWorkgroups: 2,
                                           gpuParticleCullDispatchWorkgroups: 1)

        let summary = makeDeveloperParticleDiagnosticSummary(
            stats: stats,
            eventReport: .empty,
            scalability: .default,
            renderSummary: renderSummary,
            renderStats: renderStats
        )

        #expect(summary.severity == .nominal)
        #expect(summary.status == "GPU particle path active")
        #expect(summary.primarySignal.contains("512"))
        #expect(summary.details.contains("GPU workgroups 15"))
    }

    @Test("emitter hotspots prioritize drops and merge event feedback")
    func emitterHotspotsPrioritizeDropsAndMergeEventFeedback() {
        let noisyButHealthy = ParticleEmitterFrameStats(liveParticleCount: 40,
                                                        maxParticleCount: 200,
                                                        liveParticleLimit: 200,
                                                        continuousSpawnedCount: 40,
                                                        requestedSpawnCount: 40)
        let budgetThrottled = ParticleEmitterFrameStats(liveParticleCount: 8,
                                                        maxParticleCount: 200,
                                                        liveParticleLimit: 200,
                                                        continuousSpawnedCount: 4,
                                                        requestedSpawnCount: 12,
                                                        spawnBudgetLimit: 4,
                                                        spawnBudgetConsumedCount: 4,
                                                        spawnBudgetLimitedCount: 8)
        let eventStats = ParticleEmitterFrameStats(liveParticleCount: 8,
                                                   maxParticleCount: 200,
                                                   liveParticleLimit: 200,
                                                   subEmitterSpawnedCount: 1,
                                                   requestedSpawnCount: 3,
                                                   capacityLimitedSpawnCount: 2)
        let stats = ParticleFrameStatsResource(
            emitterStats: [noisyButHealthy, budgetThrottled],
            emitterStatsByEntity: [10: noisyButHealthy, 20: budgetThrottled]
        )
        let eventReport = ParticleSimulationEventApplyReport(
            requestedSpawnCount: 3,
            spawnBudgetConsumedCount: 3,
            capacityLimitedSpawnCount: 2,
            emitterStatsByEntity: [20: eventStats]
        )

        let hotspots = makeDeveloperParticleEmitterHotspots(stats: stats,
                                                            eventReport: eventReport)

        #expect(hotspots.map(\.entityID) == [20, 10])
        #expect(hotspots[0].severity == .critical)
        #expect(hotspots[0].reason == "Capacity drops")
        #expect(hotspots[0].requestedSpawnCount == 15)
        #expect(hotspots[0].droppedSpawnCount == 10)
        #expect(hotspots[1].severity == .info)
    }

    @Test("emitter hotspots respect the requested limit")
    func emitterHotspotsRespectLimit() {
        let stats = ParticleFrameStatsResource(
            emitterStats: [
                ParticleEmitterFrameStats(liveParticleCount: 1, maxParticleCount: 10, requestedSpawnCount: 1),
                ParticleEmitterFrameStats(liveParticleCount: 2, maxParticleCount: 10, requestedSpawnCount: 2),
                ParticleEmitterFrameStats(liveParticleCount: 3, maxParticleCount: 10, requestedSpawnCount: 3),
            ],
            emitterStatsByEntity: [
                1: ParticleEmitterFrameStats(liveParticleCount: 1, maxParticleCount: 10, requestedSpawnCount: 1),
                2: ParticleEmitterFrameStats(liveParticleCount: 2, maxParticleCount: 10, requestedSpawnCount: 2),
                3: ParticleEmitterFrameStats(liveParticleCount: 3, maxParticleCount: 10, requestedSpawnCount: 3),
            ]
        )

        let hotspots = makeDeveloperParticleEmitterHotspots(stats: stats,
                                                            eventReport: .empty,
                                                            limit: 2)

        #expect(hotspots.map(\.entityID) == [3, 2])
    }

    @Test("frame trend summary reports recent pacing and peak work")
    func frameTrendSummaryReportsRecentPacingAndPeakWork() {
        let history = [
            EditorFrameStatsHistorySample(
                sampleIndex: 1,
                frameIndex: 10,
                stats: EditorFrameStats(frameSeconds: 0.040,
                                        simulationSeconds: 0.006,
                                        renderSubmitSeconds: 0.004,
                                        drawCallCount: 10,
                                        passCount: 1)
            ),
            EditorFrameStatsHistorySample(
                sampleIndex: 2,
                frameIndex: 20,
                stats: EditorFrameStats(frameSeconds: 0.020,
                                        inputSeconds: 0.004,
                                        renderSubmitSeconds: 0.006,
                                        gpuPresentSeconds: 0.006,
                                        drawCallCount: 30,
                                        passCount: 3,
                                        renderBundleCount: 2)
            ),
            EditorFrameStatsHistorySample(
                sampleIndex: 3,
                frameIndex: 30,
                stats: EditorFrameStats(frameSeconds: 0.030,
                                        simulationSeconds: 0.010,
                                        renderSubmitSeconds: 0.010,
                                        gpuPresentSeconds: 0.005,
                                        drawCallCount: 20,
                                        passCount: 2,
                                        renderBundleCount: 1)
            ),
        ]

        let summary = makeDeveloperFrameTrendSummary(history: history)

        #expect(summary?.sampleCount == 3)
        #expect(summary?.firstSampleIndex == 1)
        #expect(summary?.lastSampleIndex == 3)
        #expect(abs((summary?.averageWorkMs ?? 0) - 17) < 0.001)
        #expect(abs((summary?.p95WorkMs ?? 0) - 25) < 0.001)
        #expect(summary?.peakWorkSampleIndex == 3)
        #expect(summary?.pacingDominatedSamples == 1)
        #expect(summary?.maxDrawCallCount == 30)
        #expect(summary?.maxPassCount == 3)
        #expect(summary?.maxRenderBundleCount == 2)
    }

    @Test("empty frame trend history has no summary")
    func emptyFrameTrendHistoryHasNoSummary() {
        #expect(makeDeveloperFrameTrendSummary(history: []) == nil)
    }
}
