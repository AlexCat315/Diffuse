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
        let emitter = ParticleEmitter(maxParticles: 0,
                                      simulationBackend: .gpuRequired)
        let issue = ParticleModuleIssue(moduleID: "gpuSimulation",
                                        severity: .error,
                                        code: "gpuRequiredButUnsupported",
                                        message: "GPU simulation is required but unsupported: no particle capacity.")

        let summary = makeDeveloperParticleAuthoringDiagnosticSummary(
            gpuPlan: emitter.gpuSimulationPlan,
            moduleIssues: [issue]
        )

        #expect(summary.severity == .critical)
        #expect(summary.status == "Authoring blocked")
        #expect(summary.primarySignal == "1 module error")
        #expect(summary.recommendation.contains("blocked GPU-required"))
        #expect(summary.details.contains { $0.contains("gpuSimulation [error]") })
        #expect(summary.details.contains { $0.contains("Unsupported no capacity") })
    }

    @Test("authoring diagnostics explain GPU fallback reasons")
    func authoringDiagnosticsExplainGPUFallbackReasons() {
        let emitter = ParticleEmitter(maxParticles: 0,
                                      simulationBackend: .gpuIfSupported)

        let summary = makeDeveloperParticleAuthoringDiagnosticSummary(
            gpuPlan: emitter.gpuSimulationPlan,
            moduleIssues: []
        )

        #expect(summary.severity == .warning)
        #expect(summary.status == "GPU fallback to CPU")
        #expect(summary.primarySignal == "Unsupported: no capacity")
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

    @Test("trace creates frame samples and spike markers from frame history")
    func traceCreatesFrameTrackAndSpikeMarker() {
        let history = [
            EditorFrameStatsHistorySample(
                sampleIndex: 1,
                frameIndex: 11,
                stats: EditorFrameStats(frameSeconds: 1.0 / 60.0,
                                        simulationSeconds: 0.002,
                                        renderSubmitSeconds: 0.002)
            ),
            EditorFrameStatsHistorySample(
                sampleIndex: 2,
                frameIndex: 12,
                stats: EditorFrameStats(frameSeconds: 0.040,
                                        simulationSeconds: 0.020,
                                        renderSubmitSeconds: 0.010)
            ),
        ]

        let trace = makeDeveloperTrace(
            frameStats: history[1].stats,
            frameHistory: history,
            particleHistory: [],
            renderStats: .init(),
            issues: [],
            consoleEntries: []
        )

        #expect(trace.samples.map(\.sampleIndex) == [1, 2])
        let spike = trace.events.first { $0.id == "frame.2" }
        #expect(spike?.track == .frame)
        #expect(spike?.severity == .warning)
        #expect(spike?.target.tab == .frame)
        #expect(trace.samples.last?.issueIDs.contains("frame.2") == true)
    }

    @Test("trace promotes console errors above warnings")
    func tracePromotesConsoleErrorsAboveWarnings() {
        let stats = EditorFrameStats(frameSeconds: 1.0 / 60.0,
                                     simulationSeconds: 0.001)

        let trace = makeDeveloperTrace(
            frameStats: stats,
            frameHistory: [
                EditorFrameStatsHistorySample(sampleIndex: 7,
                                              frameIndex: 70,
                                              stats: stats),
            ],
            particleHistory: [],
            renderStats: .init(),
            issues: [],
            consoleEntries: [
                EditorConsoleEntry(id: 1,
                                   severity: .warning,
                                   message: "Shader variant missing"),
                EditorConsoleEntry(id: 2,
                                   severity: .error,
                                   message: "Pipeline creation failed"),
            ]
        )

        let console = trace.events.first { $0.track == .console }
        #expect(console?.severity == .critical)
        #expect(console?.primarySignal == "1 error")
        #expect(console?.target.tab == .console)
        #expect(trace.samples.last?.consoleSeverity == .critical)
    }

    @Test("trace creates particle markers from drop summaries")
    func traceCreatesParticleDropMarkers() {
        let stats = EditorFrameStats(frameSeconds: 1.0 / 60.0,
                                     simulationSeconds: 0.001)
        let particleHistory = [
            particleSample(index: 4,
                           live: 90,
                           limit: 100,
                           requested: 40,
                           spawned: 20,
                           dropped: 20,
                           budgetDrops: 20,
                           cpuRender: 20),
        ]

        let trace = makeDeveloperTrace(
            frameStats: stats,
            frameHistory: [
                EditorFrameStatsHistorySample(sampleIndex: 4,
                                              frameIndex: 40,
                                              stats: stats),
            ],
            particleHistory: particleHistory,
            renderStats: .init(),
            issues: [],
            consoleEntries: []
        )

        let event = trace.events.first { $0.track == .particles }
        #expect(event?.severity == .warning)
        #expect(event?.title == "Particle spawn drops")
        #expect(event?.primarySignal == "40 dropped spawns")
        #expect(event?.target.tab == .particles)
        #expect(trace.samples.first?.particleDroppedCount == 40)
    }

    @Test("trace projects render pass cost onto the render pass track")
    func traceProjectsRenderPassCost() {
        let stats = EditorFrameStats(frameSeconds: 1.0 / 60.0,
                                     simulationSeconds: 0.001)
        let renderStats = RenderFrameStats(
            passDrawCallCounts: [.basePass: 2, .particles: 4],
            activePasses: [.basePass, .particles],
            passEncodeNS: [.basePass: 2_000_000, .particles: 18_000_000]
        )

        let trace = makeDeveloperTrace(
            frameStats: stats,
            frameHistory: [
                EditorFrameStatsHistorySample(sampleIndex: 9,
                                              frameIndex: 90,
                                              stats: stats),
            ],
            particleHistory: [],
            renderStats: renderStats,
            issues: [],
            consoleEntries: []
        )

        #expect(trace.renderPasses.first?.name == RenderPassKind.particles.rawValue)
        let event = trace.events.first { $0.track == .renderPass }
        #expect(event?.severity == .critical)
        #expect(event?.target.tab == .render)
        #expect(event?.sampleIndex == 9)
    }

    @Test("trace preserves issue targets for drilldown routing")
    func tracePreservesIssueTargetsForRouting() {
        let stats = EditorFrameStats(frameSeconds: 1.0 / 60.0,
                                     simulationSeconds: 0.001)
        let issue = DeveloperDiagnosticIssue(
            id: "particles.test",
            severity: .warning,
            scope: .particles,
            title: "Particle budget",
            primarySignal: "10 dropped spawns",
            evidence: ["Requested 20, spawned 10"],
            recommendation: "Open particle diagnostics.",
            target: DeveloperDiagnosticTarget(tab: .particles,
                                              frameSampleIndex: 13,
                                              label: "Open Particles")
        )

        let trace = makeDeveloperTrace(
            frameStats: stats,
            frameHistory: [
                EditorFrameStatsHistorySample(sampleIndex: 13,
                                              frameIndex: 130,
                                              stats: stats),
            ],
            particleHistory: [],
            renderStats: .init(),
            issues: [issue],
            consoleEntries: []
        )

        let event = trace.events.first { $0.id == "issue.particles.test" }
        #expect(event?.track == .particles)
        #expect(event?.target.tab == .particles)
        #expect(event?.target.frameSampleIndex == 13)
        #expect(event?.target.label == "Open Particles")
    }

    @Test("trace event filters combine query track and severity")
    func traceEventFiltersCombineQueryTrackAndSeverity() {
        let stats = EditorFrameStats(frameSeconds: 1.0 / 60.0,
                                     simulationSeconds: 0.001)
        let renderStats = RenderFrameStats(
            passDrawCallCounts: [.basePass: 2, .particles: 4],
            activePasses: [.basePass, .particles],
            passEncodeNS: [.basePass: 2_000_000, .particles: 18_000_000]
        )

        let trace = makeDeveloperTrace(
            frameStats: stats,
            frameHistory: [
                EditorFrameStatsHistorySample(sampleIndex: 20,
                                              frameIndex: 200,
                                              stats: stats),
            ],
            particleHistory: [],
            renderStats: renderStats,
            issues: [],
            consoleEntries: [
                EditorConsoleEntry(id: 1,
                                   severity: .warning,
                                   message: "Shader variant missing"),
            ]
        )

        let renderOnly = developerTraceVisibleEvents(trace: trace,
                                                     query: "pass",
                                                     trackFilter: .renderPass,
                                                     severityFilter: .critical)
        #expect(renderOnly.count == 1)
        #expect(renderOnly.first?.track == .renderPass)

        let consoleOnly = developerTraceVisibleEvents(trace: trace,
                                                      query: "shader",
                                                      trackFilter: .console,
                                                      severityFilter: .warning)
        #expect(consoleOnly.count == 1)
        #expect(consoleOnly.first?.track == .console)

        let noMatch = developerTraceVisibleEvents(trace: trace,
                                                  query: "shader",
                                                  trackFilter: .renderPass,
                                                  severityFilter: .warning)
        #expect(noMatch.isEmpty)
    }

    @Test("monitor snapshots expose current values ranges and threshold state")
    func monitorSnapshotsExposeCurrentValuesRangesAndThresholdState() {
        let fast = EditorFrameStats(frameSeconds: 1.0 / 60.0,
                                    simulationSeconds: 0.002,
                                    renderPrepareSeconds: 0.002,
                                    gpuPresentSeconds: 0.002)
        let slow = EditorFrameStats(frameSeconds: 0.045,
                                    simulationSeconds: 0.018,
                                    renderPrepareSeconds: 0.006,
                                    renderSubmitSeconds: 0.004,
                                    gpuPresentSeconds: 0.012)
        let trace = makeDeveloperTrace(
            frameStats: slow,
            frameHistory: [
                EditorFrameStatsHistorySample(sampleIndex: 1,
                                              frameIndex: 10,
                                              stats: fast),
                EditorFrameStatsHistorySample(sampleIndex: 2,
                                              frameIndex: 11,
                                              stats: slow),
            ],
            particleHistory: [
                EditorParticleDiagnosticsSample(sampleIndex: 2,
                                                frameIndex: 11,
                                                simulatedDeltaTime: 0.016,
                                                emitterCount: 1,
                                                activeEmitterCount: 1,
                                                liveParticleCount: 80,
                                                liveParticleLimit: 100,
                                                requestedSpawnCount: 90,
                                                spawnedParticleCount: 80,
                                                droppedSpawnCount: 10,
                                                capacityLimitedSpawnCount: 0,
                                                spawnBudgetLimitedCount: 10,
                                                spawnBudgetConsumedCount: 80,
                                                spawnBudgetLimit: 80,
                                                eventRequestedSpawnCount: 0,
                                                eventDroppedSpawnCount: 0,
                                                droppedReadbackEventCount: 0,
                                                cpuRenderInstanceCount: 80,
                                                gpuRenderInstanceCount: 0,
                                                cpuBatchCount: 1,
                                                gpuBatchCount: 0,
                                                gpuSimulationParticleCount: 0,
                                                gpuWorkgroupCount: 0,
                                                gpuSortItemCount: 0,
                                                gpuSortPaddedItemCount: 0),
            ],
            renderStats: RenderFrameStats(
                passDrawCallCounts: [.basePass: 2],
                activePasses: [.basePass],
                passEncodeNS: [.basePass: 3_000_000]
            ),
            issues: [],
            consoleEntries: [
                EditorConsoleEntry(id: 1,
                                   severity: .warning,
                                   message: "Shader warning"),
            ]
        )

        let snapshots = makeDeveloperMonitorSnapshots(trace: trace)
        let frame = snapshots.first { $0.track == .frame }
        let gpu = snapshots.first { $0.track == .gpuPresent }
        let particles = snapshots.first { $0.track == .particles }
        let render = snapshots.first { $0.track == .renderPass }
        let console = snapshots.first { $0.track == .console }

        #expect(frame?.currentLabel == "40.0ms")
        #expect(frame?.isOverLimit == true)
        #expect(gpu?.currentLabel == "12.0ms")
        #expect(gpu?.isOverLimit == true)
        #expect(particles?.currentLabel == "20 drops")
        #expect(particles?.values.last == 80)
        #expect(render?.currentValue == 3)
        #expect(render?.isOverLimit == true)
        #expect(console?.currentLabel == "Warning")
        #expect(console?.isOverLimit == true)
    }

    @Test("performance monitors are built from runtime sources without trace snapshots")
    func performanceMonitorsUseRuntimeSourcesWithoutTraceSnapshots() {
        let fast = EditorFrameStats(frameSeconds: 1.0 / 60.0,
                                    simulationSeconds: 0.002,
                                    renderPrepareSeconds: 0.002,
                                    gpuPresentSeconds: 0.002,
                                    drawCallCount: 8,
                                    passCount: 2,
                                    renderBundleCount: 1)
        let slow = EditorFrameStats(frameSeconds: 0.045,
                                    simulationSeconds: 0.018,
                                    renderPrepareSeconds: 0.006,
                                    renderSubmitSeconds: 0.004,
                                    gpuPresentSeconds: 0.012,
                                    drawCallCount: 42,
                                    passCount: 5,
                                    renderBundleCount: 3)

        let monitors = makeDeveloperPerformanceMonitors(
            frameStats: slow,
            frameHistory: [
                EditorFrameStatsHistorySample(sampleIndex: 1,
                                              frameIndex: 10,
                                              stats: fast),
                EditorFrameStatsHistorySample(sampleIndex: 2,
                                              frameIndex: 11,
                                              stats: slow),
            ],
            particleHistory: [
                EditorParticleDiagnosticsSample(sampleIndex: 2,
                                                frameIndex: 11,
                                                simulatedDeltaTime: 0.016,
                                                emitterCount: 1,
                                                activeEmitterCount: 1,
                                                liveParticleCount: 80,
                                                liveParticleLimit: 100,
                                                requestedSpawnCount: 90,
                                                spawnedParticleCount: 70,
                                                droppedSpawnCount: 10,
                                                capacityLimitedSpawnCount: 0,
                                                spawnBudgetLimitedCount: 10,
                                                spawnBudgetConsumedCount: 80,
                                                spawnBudgetLimit: 80,
                                                eventRequestedSpawnCount: 0,
                                                eventDroppedSpawnCount: 0,
                                                droppedReadbackEventCount: 0,
                                                cpuRenderInstanceCount: 70,
                                                gpuRenderInstanceCount: 8,
                                                cpuBatchCount: 1,
                                                gpuBatchCount: 1,
                                                gpuSimulationParticleCount: 64,
                                                gpuWorkgroupCount: 4,
                                                gpuSortItemCount: 0,
                                                gpuSortPaddedItemCount: 0),
            ],
            renderStats: RenderFrameStats(cpuEncodeNS: 3_000_000),
            consoleEntries: [
                EditorConsoleEntry(id: 1,
                                   severity: .error,
                                   message: "Pipeline creation failed"),
                EditorConsoleEntry(id: 2,
                                   severity: .warning,
                                   message: "Shader warning"),
            ]
        )

        let frameWork = monitors.first { $0.id == .frameWorkMs }
        let drawCalls = monitors.first { $0.id == .renderDrawCalls }
        let particleDrops = monitors.first { $0.id == .particlesSpawnDrops }
        let consoleErrors = monitors.first { $0.id == .consoleErrors }

        #expect(frameWork?.sampleIndices == [1, 2])
        #expect(frameWork?.currentValue == 40)
        #expect(frameWork?.status == .critical)
        #expect(drawCalls?.currentValue == 42)
        #expect(particleDrops?.currentValue == 20)
        #expect(particleDrops?.status == .warning)
        #expect(consoleErrors?.currentValue == 1)
        #expect(consoleErrors?.status == .critical)
    }

    @Test("trace issue filters honor target track and severity")
    func traceIssueFiltersHonorTargetTrackAndSeverity() {
        let issue = DeveloperDiagnosticIssue(
            id: "console.warning",
            severity: .warning,
            scope: .console,
            title: "Console warnings",
            primarySignal: "1 warning recorded",
            evidence: ["Shader variant missing"],
            recommendation: "Open console.",
            target: DeveloperDiagnosticTarget(tab: .console,
                                              frameSampleIndex: nil,
                                              label: "Open Console")
        )
        let stats = EditorFrameStats(frameSeconds: 1.0 / 60.0,
                                     simulationSeconds: 0.001)
        let trace = makeDeveloperTrace(
            frameStats: stats,
            frameHistory: [
                EditorFrameStatsHistorySample(sampleIndex: 30,
                                              frameIndex: 300,
                                              stats: stats),
            ],
            particleHistory: [],
            renderStats: .init(),
            issues: [issue],
            consoleEntries: []
        )

        let warnings = developerTraceVisibleIssues(trace: trace,
                                                   query: "shader",
                                                   trackFilter: .console,
                                                   severityFilter: .warning)
        #expect(warnings.map(\.id) == ["console.warning"])

        let critical = developerTraceVisibleIssues(trace: trace,
                                                   query: "shader",
                                                   trackFilter: .console,
                                                   severityFilter: .critical)
        #expect(critical.isEmpty)
    }

    @Test("trace sample events are sorted by severity for property context")
    func traceSampleEventsSortBySeverityForPropertyContext() {
        let stats = EditorFrameStats(frameSeconds: 0.040,
                                     simulationSeconds: 0.020,
                                     renderSubmitSeconds: 0.010)
        let renderStats = RenderFrameStats(
            passDrawCallCounts: [.basePass: 2, .particles: 4],
            activePasses: [.basePass, .particles],
            passEncodeNS: [.basePass: 2_000_000, .particles: 18_000_000]
        )

        let trace = makeDeveloperTrace(
            frameStats: stats,
            frameHistory: [
                EditorFrameStatsHistorySample(sampleIndex: 40,
                                              frameIndex: 400,
                                              stats: stats),
            ],
            particleHistory: [],
            renderStats: renderStats,
            issues: [],
            consoleEntries: [
                EditorConsoleEntry(id: 1,
                                   severity: .warning,
                                   message: "Shader variant missing"),
            ]
        )

        let events = developerTraceSampleEvents(trace: trace,
                                                sampleIndex: 40)
        #expect(events.first?.severity == .critical)
        #expect(events.contains { $0.track == .frame })
        #expect(events.contains { $0.track == .console })
        #expect(developerTraceSampleEvents(trace: trace,
                                           sampleIndex: 40,
                                           excluding: events.first?.id).count == events.count - 1)
    }

    @Test("trace event sort modes order rows predictably")
    func traceEventSortModesOrderRowsPredictably() {
        let target = DeveloperDiagnosticTarget(tab: .frame,
                                               frameSampleIndex: nil,
                                               label: "Open")
        let trace = DeveloperTraceSnapshot(
            mode: .live,
            samples: [],
            events: [
                DeveloperTraceEvent(id: "console.warning",
                                    track: .console,
                                    sampleIndex: 30,
                                    severity: .warning,
                                    scope: .console,
                                    title: "Console warning",
                                    primarySignal: "warning",
                                    evidence: [],
                                    recommendation: "Open console",
                                    target: target),
                DeveloperTraceEvent(id: "render.critical",
                                    track: .renderPass,
                                    sampleIndex: 20,
                                    severity: .critical,
                                    scope: .render,
                                    title: "Render critical",
                                    primarySignal: "render",
                                    evidence: [],
                                    recommendation: "Open render",
                                    target: target),
                DeveloperTraceEvent(id: "frame.warning",
                                    track: .frame,
                                    sampleIndex: 40,
                                    severity: .warning,
                                    scope: .frame,
                                    title: "Frame warning",
                                    primarySignal: "frame",
                                    evidence: [],
                                    recommendation: "Open frame",
                                    target: target),
                DeveloperTraceEvent(id: "particles.critical",
                                    track: .particles,
                                    sampleIndex: 10,
                                    severity: .critical,
                                    scope: .particles,
                                    title: "Particle critical",
                                    primarySignal: "particles",
                                    evidence: [],
                                    recommendation: "Open particles",
                                    target: target),
            ],
            renderPasses: [],
            issues: []
        )

        #expect(developerTraceVisibleEvents(trace: trace,
                                           query: "",
                                           trackFilter: nil,
                                           severityFilter: .all,
                                           sortOrder: .newest).map(\.id).first == "frame.warning")
        #expect(Array(developerTraceVisibleEvents(trace: trace,
                                                 query: "",
                                                 trackFilter: nil,
                                                 severityFilter: .all,
                                                 sortOrder: .severity).map(\.id).prefix(2)) == [
            "render.critical",
            "particles.critical",
        ])
        #expect(developerTraceVisibleEvents(trace: trace,
                                           query: "",
                                           trackFilter: nil,
                                           severityFilter: .all,
                                           sortOrder: .track).map(\.id).first == "console.warning")
    }

    @Test("trace adjacent event navigation clamps to visible rows")
    func traceAdjacentEventNavigationClampsToVisibleRows() {
        let target = DeveloperDiagnosticTarget(tab: .frame,
                                               frameSampleIndex: nil,
                                               label: "Open")
        let events = [
            DeveloperTraceEvent(id: "a",
                                track: .frame,
                                sampleIndex: 1,
                                severity: .warning,
                                scope: .frame,
                                title: "A",
                                primarySignal: "A",
                                evidence: [],
                                recommendation: "A",
                                target: target),
            DeveloperTraceEvent(id: "b",
                                track: .renderPass,
                                sampleIndex: 2,
                                severity: .critical,
                                scope: .render,
                                title: "B",
                                primarySignal: "B",
                                evidence: [],
                                recommendation: "B",
                                target: target),
            DeveloperTraceEvent(id: "c",
                                track: .console,
                                sampleIndex: 3,
                                severity: .warning,
                                scope: .console,
                                title: "C",
                                primarySignal: "C",
                                evidence: [],
                                recommendation: "C",
                                target: target),
        ]

        #expect(developerTraceAdjacentEventID(events: events,
                                             selectedEventID: nil,
                                             direction: .next) == "a")
        #expect(developerTraceAdjacentEventID(events: events,
                                             selectedEventID: "a",
                                             direction: .previous) == "a")
        #expect(developerTraceAdjacentEventID(events: events,
                                             selectedEventID: "a",
                                             direction: .next) == "b")
        #expect(developerTraceAdjacentEventID(events: events,
                                             selectedEventID: "c",
                                             direction: .next) == "c")
        #expect(developerTraceAdjacentEventID(events: events,
                                             selectedEventID: "missing",
                                             direction: .next) == "a")
        #expect(developerTraceAdjacentEventID(events: [],
                                             selectedEventID: "a",
                                             direction: .next) == nil)
    }

    @Test("trace investigation summary identifies hot sample and focus event")
    func traceInvestigationSummaryIdentifiesHotSampleAndFocusEvent() {
        let target = DeveloperDiagnosticTarget(tab: .frame,
                                               frameSampleIndex: nil,
                                               label: "Open")
        let events = [
            DeveloperTraceEvent(id: "warning.1",
                                track: .frame,
                                sampleIndex: 10,
                                severity: .warning,
                                scope: .frame,
                                title: "Frame warning",
                                primarySignal: "Frame",
                                evidence: [],
                                recommendation: "Open frame",
                                target: target),
            DeveloperTraceEvent(id: "critical.1",
                                track: .renderPass,
                                sampleIndex: 20,
                                severity: .critical,
                                scope: .render,
                                title: "Render critical",
                                primarySignal: "Render",
                                evidence: [],
                                recommendation: "Open render",
                                target: target),
            DeveloperTraceEvent(id: "warning.2",
                                track: .console,
                                sampleIndex: 20,
                                severity: .warning,
                                scope: .console,
                                title: "Console warning",
                                primarySignal: "Console",
                                evidence: [],
                                recommendation: "Open console",
                                target: target),
            DeveloperTraceEvent(id: "info.1",
                                track: .particles,
                                sampleIndex: 20,
                                severity: .info,
                                scope: .particles,
                                title: "Particle info",
                                primarySignal: "Particles",
                                evidence: [],
                                recommendation: "Open particles",
                                target: target),
        ]

        let summary = makeDeveloperTraceInvestigationSummary(events: events)

        #expect(summary.visibleEventCount == 4)
        #expect(summary.criticalCount == 1)
        #expect(summary.warningCount == 2)
        #expect(summary.hotSampleIndex == 20)
        #expect(summary.hotSampleEventCount == 3)
        #expect(summary.focusEventID == "critical.1")
    }

    @Test("trace investigation summary handles empty visible events")
    func traceInvestigationSummaryHandlesEmptyVisibleEvents() {
        let summary = makeDeveloperTraceInvestigationSummary(events: [])

        #expect(summary.visibleEventCount == 0)
        #expect(summary.criticalCount == 0)
        #expect(summary.warningCount == 0)
        #expect(summary.hotSampleIndex == nil)
        #expect(summary.hotSampleEventCount == 0)
        #expect(summary.focusEventID == nil)
    }

    @Test("trace sample investigation ranks lead marker and deduplicates jump targets")
    func traceSampleInvestigationRanksLeadMarkerAndDeduplicatesJumpTargets() {
        let frameTarget = DeveloperDiagnosticTarget(tab: .frame,
                                                    frameSampleIndex: 20,
                                                    label: "Open Frame")
        let renderTarget = DeveloperDiagnosticTarget(tab: .render,
                                                     frameSampleIndex: nil,
                                                     label: "Open Render")
        let trace = DeveloperTraceSnapshot(
            mode: .live,
            samples: [],
            events: [
                DeveloperTraceEvent(id: "frame.warning",
                                    track: .frame,
                                    sampleIndex: 20,
                                    severity: .warning,
                                    scope: .frame,
                                    title: "Frame warning",
                                    primarySignal: "Frame",
                                    evidence: [],
                                    recommendation: "Open frame",
                                    target: frameTarget),
                DeveloperTraceEvent(id: "render.critical",
                                    track: .renderPass,
                                    sampleIndex: 20,
                                    severity: .critical,
                                    scope: .render,
                                    title: "Render critical",
                                    primarySignal: "Render",
                                    evidence: [],
                                    recommendation: "Open render",
                                    target: renderTarget),
                DeveloperTraceEvent(id: "frame.issue",
                                    track: .frame,
                                    sampleIndex: 20,
                                    severity: .warning,
                                    scope: .frame,
                                    title: "Frame issue",
                                    primarySignal: "Frame",
                                    evidence: [],
                                    recommendation: "Open frame",
                                    target: frameTarget),
                DeveloperTraceEvent(id: "console.other",
                                    track: .console,
                                    sampleIndex: 21,
                                    severity: .critical,
                                    scope: .console,
                                    title: "Other sample",
                                    primarySignal: "Console",
                                    evidence: [],
                                    recommendation: "Open console",
                                    target: DeveloperDiagnosticTarget(tab: .console,
                                                                      frameSampleIndex: nil,
                                                                      label: "Open Console")),
            ],
            renderPasses: [],
            issues: []
        )

        let investigation = makeDeveloperTraceSampleInvestigation(trace: trace,
                                                                  sampleIndex: 20)

        #expect(investigation.sampleIndex == 20)
        #expect(investigation.leadEventID == "render.critical")
        #expect(investigation.eventCount == 3)
        #expect(investigation.criticalCount == 1)
        #expect(investigation.warningCount == 2)
        #expect(investigation.tracks == [.renderPass, .frame])
        #expect(investigation.drilldownTargets == [renderTarget, frameTarget])
    }

    @Test("trace sample context compares neighboring samples")
    func traceSampleContextComparesNeighboringSamples() {
        let target = DeveloperDiagnosticTarget(tab: .frame,
                                               frameSampleIndex: nil,
                                               label: "Open")
        let trace = DeveloperTraceSnapshot(
            mode: .live,
            samples: [
                DeveloperTraceSample(sampleIndex: 10,
                                     frameIndex: 100,
                                     frameStats: EditorFrameStats(frameSeconds: 0.010,
                                                                  renderSubmitSeconds: 0.010),
                                     particleLiveCount: 0,
                                     particleDroppedCount: 0,
                                     consoleSeverity: nil,
                                     issueIDs: []),
                DeveloperTraceSample(sampleIndex: 20,
                                     frameIndex: 200,
                                     frameStats: EditorFrameStats(frameSeconds: 0.040,
                                                                  renderSubmitSeconds: 0.040),
                                     particleLiveCount: 0,
                                     particleDroppedCount: 0,
                                     consoleSeverity: nil,
                                     issueIDs: []),
                DeveloperTraceSample(sampleIndex: 30,
                                     frameIndex: 300,
                                     frameStats: EditorFrameStats(frameSeconds: 0.025,
                                                                  renderSubmitSeconds: 0.025),
                                     particleLiveCount: 0,
                                     particleDroppedCount: 0,
                                     consoleSeverity: nil,
                                     issueIDs: []),
            ],
            events: [
                DeveloperTraceEvent(id: "previous.warning",
                                    track: .frame,
                                    sampleIndex: 10,
                                    severity: .warning,
                                    scope: .frame,
                                    title: "Previous",
                                    primarySignal: "Previous",
                                    evidence: [],
                                    recommendation: "Previous",
                                    target: target),
                DeveloperTraceEvent(id: "selected.critical",
                                    track: .renderPass,
                                    sampleIndex: 20,
                                    severity: .critical,
                                    scope: .render,
                                    title: "Selected",
                                    primarySignal: "Selected",
                                    evidence: [],
                                    recommendation: "Selected",
                                    target: target),
                DeveloperTraceEvent(id: "selected.warning",
                                    track: .console,
                                    sampleIndex: 20,
                                    severity: .warning,
                                    scope: .console,
                                    title: "Selected warning",
                                    primarySignal: "Selected",
                                    evidence: [],
                                    recommendation: "Selected",
                                    target: target),
            ],
            renderPasses: [],
            issues: []
        )

        let context = makeDeveloperTraceSampleContext(trace: trace,
                                                      sampleIndex: 20)

        #expect(context?.previous?.sampleIndex == 10)
        #expect(context?.previous?.workMs == 10)
        #expect(context?.previous?.workDeltaFromSelectedMs == -30)
        #expect(context?.previous?.eventCount == 1)
        #expect(context?.previous?.highestSeverity == .warning)
        #expect(context?.selected.sampleIndex == 20)
        #expect(context?.selected.workMs == 40)
        #expect(context?.selected.workDeltaFromSelectedMs == 0)
        #expect(context?.selected.eventCount == 2)
        #expect(context?.selected.highestSeverity == .critical)
        #expect(context?.next?.sampleIndex == 30)
        #expect(context?.next?.workMs == 25)
        #expect(context?.next?.eventCount == 0)
        #expect(context?.next?.highestSeverity == .nominal)
        #expect(makeDeveloperTraceSampleContext(trace: trace,
                                               sampleIndex: 999) == nil)
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
