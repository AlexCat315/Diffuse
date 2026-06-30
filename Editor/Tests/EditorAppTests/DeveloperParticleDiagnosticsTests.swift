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

    @Test("render budget skips are reported as particle tuning diagnostics")
    func renderBudgetSkipsAreReportedAsTuningDiagnostics() {
        let stats = ParticleFrameStatsResource(emitterStats: [
            ParticleEmitterFrameStats(liveParticleCount: 8,
                                      maxParticleCount: 16,
                                      liveParticleLimit: 16),
        ])
        let renderSummary = ParticleRenderSummary(particleCount: 5,
                                                  sourceParticleCount: 8,
                                                  submittedSourceParticleCount: 5,
                                                  cpuRenderInstanceCount: 5,
                                                  batchCount: 1,
                                                  cpuBatchCount: 1)

        let summary = makeDeveloperParticleDiagnosticSummary(
            stats: stats,
            eventReport: .empty,
            scalability: .default,
            renderSummary: renderSummary,
            renderStats: .init()
        )

        #expect(summary.severity == .info)
        #expect(summary.status == "Particle render budget limiting")
        #expect(summary.primarySignal == "3 source particles skipped before render")
        #expect(summary.recommendation.contains("Max Rendered Particles"))
        #expect(summary.details.contains("Source 8, submitted 5"))
    }

    @Test("emitter labels preserve hierarchy paths")
    func emitterLabelsPreserveHierarchyPaths() {
        let roots = [
            EditorSceneNode(id: 1,
                            name: "World",
                            kind: "Scene",
                            children: [
                                EditorSceneNode(id: 2,
                                                name: "FX Rig",
                                                kind: "Entity",
                                                children: [
                                                    EditorSceneNode(id: 3,
                                                                    name: "Muzzle Sparks",
                                                                    kind: "Particle Emitter",
                                                                    children: []),
                                                ]),
                            ]),
        ]

        let labels = makeDeveloperParticleEmitterLabels(roots: roots)

        #expect(labels[1]?.path == "World")
        #expect(labels[2]?.path == "World / FX Rig")
        #expect(labels[3]?.name == "Muzzle Sparks")
        #expect(labels[3]?.kind == "Particle Emitter")
        #expect(labels[3]?.path == "World / FX Rig / Muzzle Sparks")
    }

    @Test("authoring diagnostics report GPU-required blockers")
    func authoringDiagnosticsReportGPURequiredBlockers() {
        let emitter = ParticleEmitter(distanceEmissionRate: 12,
                                      maxParticles: 256,
                                      simulationBackend: .gpuRequired)
        let issue = ParticleModuleIssue(moduleID: "gpuSimulation",
                                        severity: .error,
                                        code: "gpuRequiredButUnsupported",
                                        message: "GPU simulation is required but unsupported: distance emission.")

        let summary = makeDeveloperParticleAuthoringDiagnosticSummary(
            gpuPlan: emitter.gpuSimulationPlan,
            moduleIssues: [issue]
        )

        #expect(summary.severity == .critical)
        #expect(summary.status == "Authoring blocked")
        #expect(summary.primarySignal == "1 module error")
        #expect(summary.recommendation.contains("blocked GPU-required"))
        #expect(summary.details.contains { $0.contains("gpuSimulation [error]") })
        #expect(summary.details.contains { $0.contains("Unsupported distance emission") })
    }

    @Test("authoring diagnostics explain GPU fallback reasons")
    func authoringDiagnosticsExplainGPUFallbackReasons() {
        let emitter = ParticleEmitter(distanceEmissionRate: 8,
                                      maxParticles: 128,
                                      simulationBackend: .gpuIfSupported)

        let summary = makeDeveloperParticleAuthoringDiagnosticSummary(
            gpuPlan: emitter.gpuSimulationPlan,
            moduleIssues: []
        )

        #expect(summary.severity == .warning)
        #expect(summary.status == "GPU fallback to CPU")
        #expect(summary.primarySignal == "Unsupported: distance emission")
        #expect(summary.recommendation.contains("Remove unsupported features"))
        #expect(summary.details.contains("GPU plan Fallback"))
    }

    @Test("authoring diagnostics summarize ready GPU dispatch")
    func authoringDiagnosticsSummarizeReadyGPUDispatch() {
        let emitter = ParticleEmitter(maxParticles: 512,
                                      simulationBackend: .gpuIfSupported,
                                      gpuSimulationWorkgroupSize: 128)

        let summary = makeDeveloperParticleAuthoringDiagnosticSummary(
            gpuPlan: emitter.gpuSimulationPlan,
            moduleIssues: []
        )

        #expect(summary.severity == .nominal)
        #expect(summary.status == "GPU simulation ready")
        #expect(summary.primarySignal == "Dispatch 4x128 for 512 capacity")
        #expect(summary.details.contains("GPU plan Ready"))
        #expect(summary.details.contains("Capacity 512, dispatch 4x128"))
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
        #expect(hotspots[0].primarySignal == "2 capacity-limited spawns")
        #expect(hotspots[0].recommendation.contains("max particles"))
        #expect(hotspots[0].details.contains("Frame drops 8, event drops 2"))
        #expect(hotspots[0].requestedSpawnCount == 15)
        #expect(hotspots[0].droppedSpawnCount == 10)
        #expect(hotspots[1].severity == .info)
        #expect(hotspots[1].primarySignal == "40 spawn requests")
        #expect(hotspots[1].recommendation.contains("emission curves"))
    }

    @Test("emitter hotspot explains live-budget pressure")
    func emitterHotspotExplainsLiveBudgetPressure() {
        let stats = ParticleEmitterFrameStats(liveParticleCount: 95,
                                              maxParticleCount: 100,
                                              liveParticleLimit: 100,
                                              requestedSpawnCount: 0,
                                              spawnBudgetLimit: 20,
                                              spawnBudgetConsumedCount: 0)

        let hotspot = makeDeveloperParticleEmitterHotspot(entityID: 42,
                                                          frameStats: stats)

        #expect(hotspot.severity == .warning)
        #expect(hotspot.reason == "Live budget")
        #expect(hotspot.primarySignal == "95% live budget used")
        #expect(hotspot.recommendation.contains("Reduce lifetime"))
        #expect(hotspot.details.contains("Live 95/100"))
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

    @Test("emitter hotspots sort severity before raw pressure score")
    func emitterHotspotsSortSeverityBeforeRawPressureScore() {
        let highRequestInfo = ParticleEmitterFrameStats(liveParticleCount: 10,
                                                        maxParticleCount: 1_000,
                                                        liveParticleLimit: 1_000,
                                                        continuousSpawnedCount: 50_000,
                                                        requestedSpawnCount: 50_000,
                                                        spawnBudgetConsumedCount: 50_000)
        let budgetWarning = ParticleEmitterFrameStats(liveParticleCount: 4,
                                                      maxParticleCount: 1_000,
                                                      liveParticleLimit: 1_000,
                                                      requestedSpawnCount: 8,
                                                      spawnBudgetLimit: 4,
                                                      spawnBudgetConsumedCount: 4,
                                                      spawnBudgetLimitedCount: 4)
        let capacityCritical = ParticleEmitterFrameStats(liveParticleCount: 4,
                                                        maxParticleCount: 4,
                                                        liveParticleLimit: 4,
                                                        requestedSpawnCount: 5,
                                                        capacityLimitedSpawnCount: 1)
        let stats = ParticleFrameStatsResource(
            emitterStats: [highRequestInfo, budgetWarning, capacityCritical],
            emitterStatsByEntity: [
                1: highRequestInfo,
                2: budgetWarning,
                3: capacityCritical,
            ]
        )

        let hotspots = makeDeveloperParticleEmitterHotspots(stats: stats,
                                                            eventReport: .empty)

        #expect(hotspots.map { $0.entityID } == [3, 2, 1])
        #expect(hotspots.map { $0.severity } == [
            DeveloperParticleDiagnosticSeverity.critical,
            DeveloperParticleDiagnosticSeverity.warning,
            DeveloperParticleDiagnosticSeverity.info,
        ])
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

    @Test("particle trend summary reports sustained pressure and GPU peaks")
    func particleTrendSummaryReportsPressureAndGPUPeaks() {
        let history = [
            particleSample(index: 1,
                           live: 50,
                           limit: 100,
                           requested: 10,
                           spawned: 10,
                           dropped: 0,
                           gpuRender: 20,
                           gpuWorkgroups: 2,
                           sortItems: 32,
                           sortPaddedItems: 64),
            particleSample(index: 2,
                           live: 95,
                           limit: 100,
                           requested: 80,
                           spawned: 60,
                           dropped: 20,
                           capacityDrops: 5,
                           budgetDrops: 15,
                           eventDrops: 3,
                           readbackDrops: 1,
                           cpuRender: 12,
                           gpuRender: 140,
                           gpuSimParticles: 180,
                           gpuWorkgroups: 9,
                           sortItems: 64,
                           sortPaddedItems: 128),
            particleSample(index: 3,
                           live: 90,
                           limit: 100,
                           requested: 30,
                           spawned: 20,
                           dropped: 10,
                           budgetDrops: 10,
                           gpuRender: 80,
                           gpuWorkgroups: 4,
                           sortItems: 96,
                           sortPaddedItems: 128),
        ]

        let summary = makeDeveloperParticleTrendSummary(history: history)

        #expect(summary?.sampleCount == 3)
        #expect(summary?.firstSampleIndex == 1)
        #expect(summary?.lastSampleIndex == 3)
        #expect(abs((summary?.averageLiveParticleCount ?? 0) - 78.333) < 0.01)
        #expect(summary?.maxLiveParticleCount == 95)
        #expect(summary?.peakLiveSampleIndex == 2)
        #expect(summary?.liveBudgetPressureSamples == 2)
        #expect(summary?.totalRequestedSpawnCount == 120)
        #expect(summary?.totalSpawnedParticleCount == 90)
        #expect(summary?.totalDroppedSpawnCount == 30)
        #expect(summary?.totalCapacityLimitedSpawnCount == 5)
        #expect(summary?.totalSpawnBudgetLimitedCount == 25)
        #expect(summary?.totalEventDroppedSpawnCount == 3)
        #expect(summary?.totalDroppedReadbackEventCount == 1)
        #expect(summary?.peakDropSampleIndex == 2)
        #expect(summary?.maxDroppedSpawnCount == 20)
        #expect(summary?.peakSpawnRequestSampleIndex == 2)
        #expect(summary?.maxRequestedSpawnCount == 80)
        #expect(summary?.maxCPURenderInstanceCount == 12)
        #expect(summary?.maxGPURenderInstanceCount == 140)
        #expect(summary?.maxGPUSimulationParticleCount == 180)
        #expect(summary?.maxGPUWorkgroupCount == 9)
        #expect(abs((summary?.maxSortPaddingOverhead ?? 0) - 0.5) < 0.001)
    }

    @Test("empty particle trend history has no summary")
    func emptyParticleTrendHistoryHasNoSummary() {
        #expect(makeDeveloperParticleTrendSummary(history: []) == nil)
    }

    @Test("workbench diagnostics promote console errors ahead of frame warnings")
    func workbenchDiagnosticsPrioritizeCriticalConsoleErrors() {
        let issues = makeDeveloperWorkbenchIssues(
            frameStats: EditorFrameStats(frameSeconds: 0.100,
                                         simulationSeconds: 0.001),
            frameHistory: [],
            renderStats: .init(),
            particleSummary: nil,
            particleAuthoringSummary: nil,
            particleHotspots: [],
            selectedEntityID: nil,
            consoleEntries: [
                EditorConsoleEntry(id: 1,
                                   severity: .error,
                                   message: "Renderer failed to create test resource"),
            ]
        )

        #expect(issues.first?.scope == .console)
        #expect(issues.first?.severity == .critical)
        #expect(issues.contains { $0.id == "frame.pacing" })
    }

    @Test("workbench diagnostics convert particle health summaries into actionable issues")
    func workbenchDiagnosticsSurfaceParticleHealth() {
        let summary = DeveloperParticleDiagnosticSummary(
            severity: .warning,
            status: "Spawn budget throttling",
            primarySignal: "12 budget-limited spawns",
            recommendation: "Raise Max Spawn / Frame for bursty emitters.",
            details: ["Frame budget 24/24"]
        )

        let issues = makeDeveloperWorkbenchIssues(
            frameStats: EditorFrameStats(frameSeconds: 1.0 / 60.0,
                                         simulationSeconds: 0.001),
            frameHistory: [],
            renderStats: .init(),
            particleSummary: summary,
            particleAuthoringSummary: nil,
            particleHotspots: [],
            selectedEntityID: nil,
            consoleEntries: []
        )

        let issue = issues.first { $0.scope == .particles }
        #expect(issue?.severity == .warning)
        #expect(issue?.title == "Spawn budget throttling")
        #expect(issue?.target.tab == .particles)
        #expect(issue?.recommendation.contains("Max Spawn / Frame") == true)
    }

    @Test("render pass breakdown ranks the expensive pass first")
    func renderPassBreakdownRanksExpensivePassesFirst() {
        let renderStats = RenderFrameStats(
            passDrawCallCounts: [.basePass: 12, .particles: 3],
            activePasses: [.basePass, .particles],
            passEncodeNS: [.basePass: 1_000_000, .particles: 17_000_000]
        )

        let passes = makeDeveloperRenderPassBreakdown(renderStats: renderStats)

        #expect(passes.first?.name == RenderPassKind.particles.rawValue)
        #expect(passes.first?.encodeNS == 17_000_000)
        #expect(passes.first?.recommendation.contains("Inspect") == true)
    }

    private func particleSample(index: UInt64,
                                live: Int,
                                limit: Int,
                                requested: Int,
                                spawned: Int,
                                dropped: Int,
                                capacityDrops: Int = 0,
                                budgetDrops: Int = 0,
                                eventDrops: Int = 0,
                                readbackDrops: Int = 0,
                                cpuRender: Int = 0,
                                gpuRender: Int = 0,
                                gpuSimParticles: Int = 0,
                                gpuWorkgroups: Int = 0,
                                sortItems: Int = 0,
                                sortPaddedItems: Int = 0) -> EditorParticleDiagnosticsSample {
        EditorParticleDiagnosticsSample(sampleIndex: index,
                                        frameIndex: index * 10,
                                        simulatedDeltaTime: 1.0 / 60.0,
                                        emitterCount: 1,
                                        activeEmitterCount: live > 0 ? 1 : 0,
                                        liveParticleCount: live,
                                        liveParticleLimit: limit,
                                        requestedSpawnCount: requested,
                                        spawnedParticleCount: spawned,
                                        droppedSpawnCount: dropped,
                                        capacityLimitedSpawnCount: capacityDrops,
                                        spawnBudgetLimitedCount: budgetDrops,
                                        spawnBudgetConsumedCount: spawned,
                                        spawnBudgetLimit: 0,
                                        eventRequestedSpawnCount: eventDrops,
                                        eventDroppedSpawnCount: eventDrops,
                                        droppedReadbackEventCount: readbackDrops,
                                        cpuRenderInstanceCount: cpuRender,
                                        gpuRenderInstanceCount: gpuRender,
                                        cpuBatchCount: cpuRender > 0 ? 1 : 0,
                                        gpuBatchCount: gpuRender > 0 ? 1 : 0,
                                        gpuSimulationParticleCount: gpuSimParticles,
                                        gpuWorkgroupCount: gpuWorkgroups,
                                        gpuSortItemCount: sortItems,
                                        gpuSortPaddedItemCount: sortPaddedItems)
    }
}
