import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct DeveloperToolsPanel: View {
    let app: EditorApplication

    @State private var selectedTab: DeveloperToolTab = .performance

    var body: some View {
        StoreScope(app.store) { store in
            let timingRevision = store.frameTimingRevision
            let frameStats = store.state.frameStats
            let frameStatsHistory = store.frameStatsHistory
            let renderStats: RenderFrameStats = selectedTab == .render
                ? app.currentRenderStats()
                : .init()

            TabView(selection: $selectedTab, tabs: [
                TabItem(L("Performance"), id: DeveloperToolTab.performance) {
                    PerformanceDiagnosticsView(stats: frameStats,
                                               history: frameStatsHistory,
                                               timingRevision: timingRevision)
                },
                TabItem(L("Render Stats"), id: DeveloperToolTab.render) {
                    RenderDiagnosticsView(frameStats: frameStats,
                                          renderStats: renderStats)
                },
                TabItem(L("Runtime"), id: DeveloperToolTab.runtime) {
                    RuntimeDiagnosticsView(store: store,
                                           timingRevision: timingRevision)
                },
                TabItem("Particles", id: DeveloperToolTab.particles) {
                    ParticleDiagnosticsTabView(app: app,
                                               store: store)
                },
                TabItem(L("Console"), id: DeveloperToolTab.console) {
                    ConsoleDiagnosticsView(store: store)
                },
            ])
            .frame(minHeight: 160)
        }
    }
}

private enum DeveloperToolTab: Hashable {
    case performance
    case render
    case runtime
    case particles
    case console
}

struct DeveloperFrameTrendSummary: Equatable {
    var sampleCount: Int
    var firstSampleIndex: UInt64
    var lastSampleIndex: UInt64
    var averageObservedFPS: Double
    var averageWorkFPS: Double
    var averageWorkMs: Double
    var p95WorkMs: Double
    var maxWorkMs: Double
    var averagePacingGapMs: Double
    var maxPacingGapMs: Double
    var pacingDominatedSamples: Int
    var peakWorkSampleIndex: UInt64
    var maxDrawCallCount: Int
    var maxPassCount: Int
    var maxRenderBundleCount: Int
}

func makeDeveloperFrameTrendSummary(
    history: [EditorFrameStatsHistorySample]
) -> DeveloperFrameTrendSummary? {
    guard !history.isEmpty else { return nil }

    var observedFPSTotal = 0.0
    var workFPSTotal = 0.0
    var workMsTotal = 0.0
    var pacingGapMsTotal = 0.0
    var maxPacingGapMs = 0.0
    var pacingDominatedSamples = 0
    var maxDrawCallCount = 0
    var maxPassCount = 0
    var maxRenderBundleCount = 0
    var peakWorkSample = history[0]
    var workMsValues: [Double] = []
    workMsValues.reserveCapacity(history.count)

    for sample in history {
        let stats = sample.stats
        observedFPSTotal += stats.fps
        workFPSTotal += stats.workFPS
        workMsTotal += stats.workMs
        pacingGapMsTotal += stats.pacingGapMs
        maxPacingGapMs = max(maxPacingGapMs, stats.pacingGapMs)
        if stats.isFramePacingDominated {
            pacingDominatedSamples += 1
        }
        if stats.workMs > peakWorkSample.stats.workMs {
            peakWorkSample = sample
        }
        maxDrawCallCount = max(maxDrawCallCount, stats.drawCallCount)
        maxPassCount = max(maxPassCount, stats.passCount)
        maxRenderBundleCount = max(maxRenderBundleCount, stats.renderBundleCount)
        workMsValues.append(stats.workMs)
    }

    let count = Double(history.count)
    return DeveloperFrameTrendSummary(
        sampleCount: history.count,
        firstSampleIndex: history[0].sampleIndex,
        lastSampleIndex: history[history.count - 1].sampleIndex,
        averageObservedFPS: observedFPSTotal / count,
        averageWorkFPS: workFPSTotal / count,
        averageWorkMs: workMsTotal / count,
        p95WorkMs: percentile(workMsValues, fraction: 0.95),
        maxWorkMs: peakWorkSample.stats.workMs,
        averagePacingGapMs: pacingGapMsTotal / count,
        maxPacingGapMs: maxPacingGapMs,
        pacingDominatedSamples: pacingDominatedSamples,
        peakWorkSampleIndex: peakWorkSample.sampleIndex,
        maxDrawCallCount: maxDrawCallCount,
        maxPassCount: maxPassCount,
        maxRenderBundleCount: maxRenderBundleCount
    )
}

private struct PerformanceDiagnosticsView: View {
    let stats: EditorFrameStats
    let history: [EditorFrameStatsHistorySample]
    let timingRevision: UInt64

    var body: some View {
        let trend = makeDeveloperFrameTrendSummary(history: history)
        ScrollView(.vertical) {
            if stats.isFramePacingDominated {
                FramePacingNotice(stats: stats)
                    .padding(horizontal: 12, vertical: 10)
            }

            Row(alignment: .top, spacing: 12) {
                StatGroup(title: L("Frame")) {
                    StatRow(label: "Observed FPS", value: formatFPS(stats.fps))
                    StatRow(label: "Tick Gap", value: formatMs(stats.frameMs))
                    StatRow(label: "Work", value: formatMs(stats.workMs))
                    StatRow(label: "Work FPS", value: formatFPS(stats.workFPS))
                    StatRow(label: "Pacing Gap", value: formatMs(stats.pacingGapMs))
                    StatRow(label: "Sample", value: "#\(timingRevision)")
                }
                .flex(1, shrink: 1)

                StatGroup(title: "CPU") {
                    StatRow(label: "Input", value: formatMs(stats.inputSeconds * 1000))
                    StatRow(label: "Simulation", value: formatMs(stats.simulationSeconds * 1000))
                    StatRow(label: "Render Prep", value: formatMs(stats.renderPrepareSeconds * 1000))
                    StatRow(label: "Render Submit", value: formatMs(stats.renderSubmitSeconds * 1000))
                    StatRow(label: "Total", value: formatMs(cpuMs(stats)))
                }
                .flex(1, shrink: 1)

                StatGroup(title: "GPU") {
                    StatRow(label: "Present", value: formatMs(stats.gpuPresentSeconds * 1000))
                    StatRow(label: "Draw Calls", value: "\(stats.drawCallCount)")
                    StatRow(label: "Passes", value: "\(stats.passCount)")
                    StatRow(label: "Bundles", value: "\(stats.renderBundleCount)")
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 12, vertical: 10)

            Divider()

            if let trend {
                Row(alignment: .top, spacing: 12) {
                    StatGroup(title: "Recent Trend") {
                        StatRow(label: "Samples", value: "\(trend.sampleCount)")
                        StatRow(label: "Window", value: "#\(trend.firstSampleIndex)-#\(trend.lastSampleIndex)")
                        StatRow(label: "Avg Observed FPS", value: formatFPS(trend.averageObservedFPS))
                        StatRow(label: "Avg Work FPS", value: formatFPS(trend.averageWorkFPS))
                        StatRow(label: "Avg Work", value: formatMs(trend.averageWorkMs))
                    }
                    .flex(1, shrink: 1)

                    StatGroup(title: "Stability") {
                        StatRow(label: "Pacing Samples", value: "\(trend.pacingDominatedSamples)/\(trend.sampleCount)")
                        StatRow(label: "Pacing Share", value: formatPercent(trend.pacingDominatedSamples,
                                                                             trend.sampleCount))
                        StatRow(label: "Avg Gap", value: formatMs(trend.averagePacingGapMs))
                        StatRow(label: "Max Gap", value: formatMs(trend.maxPacingGapMs))
                        StatRow(label: "P95 Work", value: formatMs(trend.p95WorkMs))
                    }
                    .flex(1, shrink: 1)

                    StatGroup(title: "Peak Load") {
                        StatRow(label: "Peak Sample", value: "#\(trend.peakWorkSampleIndex)")
                        StatRow(label: "Max Work", value: formatMs(trend.maxWorkMs))
                        StatRow(label: "Max Draw Calls", value: "\(trend.maxDrawCallCount)")
                        StatRow(label: "Max Passes", value: "\(trend.maxPassCount)")
                        StatRow(label: "Max Bundles", value: "\(trend.maxRenderBundleCount)")
                    }
                    .flex(1, shrink: 1)
                }
                .padding(horizontal: 12, vertical: 10)

                Divider()
            }

            Row(alignment: .top, spacing: 12) {
                StatGroup(title: "Budget") {
                    StatRow(label: "Work @60 FPS", value: budgetStatus(frameMs: stats.workMs, targetMs: 16.7))
                    StatRow(label: "Work @30 FPS", value: budgetStatus(frameMs: stats.workMs, targetMs: 33.3))
                    StatRow(label: "Work Headroom @60", value: formatSignedMs(16.7 - stats.workMs))
                    StatRow(label: "Pacing Gap", value: formatMs(stats.pacingGapMs))
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Bottleneck") {
                    StatRow(label: "Likely", value: bottleneck(stats))
                    StatRow(label: "CPU Total", value: formatMs(cpuMs(stats)))
                    StatRow(label: "GPU Present", value: formatMs(stats.gpuPresentSeconds * 1000))
                    StatRow(label: "Work", value: formatMs(stats.workMs))
                    StatRow(label: "Pacing Gap", value: formatMs(stats.pacingGapMs))
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Render Summary") {
                    StatRow(label: "Draw / Pass", value: averageDrawsPerPass(stats))
                    StatRow(label: "Draw Calls", value: "\(stats.drawCallCount)")
                    StatRow(label: "Passes", value: "\(stats.passCount)")
                    StatRow(label: "Bundles", value: "\(stats.renderBundleCount)")
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 12, vertical: 10)
        }
    }
}

private struct RenderDiagnosticsView: View {
    let frameStats: EditorFrameStats
    let renderStats: RenderFrameStats

    var body: some View {
        ScrollView(.vertical) {
            Row(alignment: .top, spacing: 12) {
                StatGroup(title: L("Render")) {
                    StatRow(label: "Frame", value: renderStats.frameIndex >= 0 ? "\(renderStats.frameIndex)" : "--")
                    StatRow(label: "Settings Gen", value: "\(renderStats.settingsGeneration)")
                    StatRow(label: "Passes", value: "\(renderStats.passCount)")
                    StatRow(label: "Draw Calls", value: "\(renderStats.drawCallCount)")
                    StatRow(label: "Bundles", value: "\(renderStats.renderBundleCount)")
                    StatRow(label: "Bundle Jobs", value: "\(renderStats.renderBundleParallelJobs)")
                }
                .flex(1, shrink: 1)

                StatGroup(title: "CPU Encode") {
                    StatRow(label: "Prepare", value: formatNs(renderStats.cpuPrepareNS))
                    StatRow(label: "Encode", value: formatNs(renderStats.cpuEncodeNS))
                    StatRow(label: "Submit", value: formatNs(renderStats.cpuSubmitNS))
                    StatRow(label: "Total", value: formatNs(renderStats.cpuFrameTotalNS))
                    StatRow(label: "Present", value: formatMs(frameStats.gpuPresentSeconds * 1000))
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Shadow") {
                    StatRow(label: "Lights", value: "\(renderStats.shadowedLightCount)")
                    StatRow(label: "Tiles", value: "\(renderStats.shadowTileCount)")
                    StatRow(label: "Cascades", value: "\(renderStats.shadowCascadeCount)")
                    StatRow(label: "Map", value: renderStats.shadowMapResolution > 0 ? "\(renderStats.shadowMapResolution)" : "--")
                    StatRow(label: "Atlas", value: renderStats.shadowAtlasResolution > 0 ? "\(renderStats.shadowAtlasResolution)" : "--")
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 12, vertical: 10)

            Divider()

            Row(alignment: .top, spacing: 12) {
                StatGroup(title: "Active Passes") {
                    if renderStats.activePasses.isEmpty {
                        StatRow(label: "Passes", value: "--")
                    } else {
                        StatWrappedValue(label: "Passes",
                                         value: renderStats.activePasses.map(\.rawValue).joined(separator: ", "))
                    }
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Pass Draw Calls") {
                    if renderStats.passDrawCallCounts.isEmpty {
                        StatRow(label: "Passes", value: "--")
                    } else {
                        for entry in renderStats.passDrawCallCounts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                            StatRow(label: entry.key.rawValue, value: "\(entry.value)")
                        }
                    }
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 12, vertical: 10)

            Row(alignment: .top, spacing: 12) {
                StatGroup(title: "Pass Encode") {
                    if renderStats.passEncodeNS.isEmpty {
                        StatRow(label: "Passes", value: "--")
                    } else {
                        for entry in renderStats.passEncodeNS.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                            StatRow(label: entry.key.rawValue, value: formatNs(entry.value))
                        }
                    }
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 12, vertical: 10)
        }
    }
}

private struct RuntimeDiagnosticsView: View {
    let store: EditorStore
    let timingRevision: UInt64

    var body: some View {
        ScrollView(.vertical) {
            Row(alignment: .top, spacing: 12) {
                StatGroup(title: L("Editor")) {
                    StatRow(label: L("Status"), value: store.connected ? L("Connected") : L("Offline"))
                    StatRow(label: L("Revision"), value: "\(store.sceneRevision)")
                    StatRow(label: "Frame Index", value: "\(store.frameIndex)")
                    StatRow(label: "Timing Sample", value: "#\(timingRevision)")
                }
                .flex(1, shrink: 1)

                StatGroup(title: L("Viewport")) {
                    StatRow(label: "Realtime", value: store.viewportRealtimeEnabled ? L("On") : L("Off"))
                    StatRow(label: "Render Scale", value: "\(store.viewportRenderScalePercent)%")
                    StatRow(label: "Shading", value: String(describing: store.viewportShadingMode))
                    StatRow(label: "Shadows", value: store.viewportShadowsEnabled ? L("On") : L("Off"))
                }
                .flex(1, shrink: 1)

                StatGroup(title: L("Selection")) {
                    if let selected = store.selectedEntityID {
                        StatRow(label: "Primary", value: "\(selected)")
                    } else {
                        StatRow(label: "Primary", value: "--")
                    }
                    StatRow(label: "Count", value: "\(store.selectedEntityIDs.count)")
                    StatRow(label: "Playback", value: String(describing: store.playbackState))
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 12, vertical: 10)
        }
    }
}

enum DeveloperParticleDiagnosticSeverity: String, Equatable {
    case idle = "Idle"
    case nominal = "Nominal"
    case info = "Info"
    case warning = "Warning"
    case critical = "Critical"
}

struct DeveloperParticleDiagnosticSummary: Equatable {
    var severity: DeveloperParticleDiagnosticSeverity
    var status: String
    var primarySignal: String
    var recommendation: String
    var details: [String]
}

struct DeveloperParticleEmitterLabel: Equatable {
    var entityID: UInt64
    var name: String
    var kind: String
    var path: String
}

struct DeveloperParticleEmitterHotspot: Equatable {
    var entityID: UInt64
    var severity: DeveloperParticleDiagnosticSeverity
    var reason: String
    var primarySignal: String
    var recommendation: String
    var details: [String]
    var score: Int
    var liveParticleCount: Int
    var requestedSpawnCount: Int
    var spawnedParticleCount: Int
    var droppedSpawnCount: Int
    var capacityLimitedSpawnCount: Int
    var spawnBudgetLimitedCount: Int
    var eventDroppedSpawnCount: Int
    var liveBudgetText: String
    var spawnBudgetText: String
}

func makeDeveloperParticleEmitterLabels(roots: [EditorSceneNode]) -> [UInt64: DeveloperParticleEmitterLabel] {
    var labels: [UInt64: DeveloperParticleEmitterLabel] = [:]

    func visit(_ node: EditorSceneNode, parentPath: String?) {
        let path = parentPath.map { "\($0) / \(node.name)" } ?? node.name
        labels[node.id] = DeveloperParticleEmitterLabel(
            entityID: node.id,
            name: node.name,
            kind: node.kind,
            path: path
        )
        for child in node.children {
            visit(child, parentPath: path)
        }
    }

    for root in roots {
        visit(root, parentPath: nil)
    }
    return labels
}

func makeDeveloperParticleAuthoringDiagnosticSummary(
    gpuPlan: ParticleGPUSimulationPlan?,
    moduleIssues: [ParticleModuleIssue]
) -> DeveloperParticleDiagnosticSummary {
    let sortedIssues = moduleIssues.sorted(by: developerParticleModuleIssuePrecedes)
    let errorCount = sortedIssues.filter { $0.severity == .error }.count
    let warningCount = sortedIssues.filter { $0.severity == .warning }.count
    let infoCount = sortedIssues.filter { $0.severity == .info }.count
    let issueDetails = developerParticleModuleIssueDetails(sortedIssues)
    let gpuDetails = developerParticleGPUPlanDetails(gpuPlan)

    if errorCount > 0 {
        return DeveloperParticleDiagnosticSummary(
            severity: .critical,
            status: "Authoring blocked",
            primarySignal: "\(errorCount) module \(errorCount == 1 ? "error" : "errors")",
            recommendation: "Fix module errors before profiling runtime pressure; blocked GPU-required emitters cannot execute as authored.",
            details: issueDetails + gpuDetails
        )
    }

    if let gpuPlan, gpuPlan.status == .requiredButUnsupported {
        return DeveloperParticleDiagnosticSummary(
            severity: .critical,
            status: "GPU simulation blocked",
            primarySignal: "Unsupported: \(developerParticleGPUUnsupportedReasonList(gpuPlan.unsupportedReasons))",
            recommendation: "Remove unsupported modules or switch the backend to GPU If Supported/CPU before relying on this effect.",
            details: gpuDetails
        )
    }

    if warningCount > 0 {
        return DeveloperParticleDiagnosticSummary(
            severity: .warning,
            status: "Authoring warnings",
            primarySignal: "\(warningCount) module \(warningCount == 1 ? "warning" : "warnings")",
            recommendation: "Resolve warnings before chasing frame-time regressions; they often explain CPU fallback or clamped behavior.",
            details: issueDetails + gpuDetails
        )
    }

    if let gpuPlan {
        switch gpuPlan.status {
        case .disabled:
            return DeveloperParticleDiagnosticSummary(
                severity: .nominal,
                status: "CPU simulation selected",
                primarySignal: "Backend CPU",
                recommendation: "Keep CPU for low-volume emitters; move high-volume compatible effects to GPU If Supported.",
                details: gpuDetails
            )
        case .supported:
            return DeveloperParticleDiagnosticSummary(
                severity: .nominal,
                status: "GPU simulation ready",
                primarySignal: "Dispatch \(gpuPlan.dispatchWorkgroups)x\(gpuPlan.workgroupSize) for \(gpuPlan.particleCapacity) capacity",
                recommendation: "Track GPU workgroup split, sort padding, and readback drops as effect complexity grows.",
                details: gpuDetails
            )
        case .fallbackToCPU:
            return DeveloperParticleDiagnosticSummary(
                severity: .warning,
                status: "GPU fallback to CPU",
                primarySignal: "Unsupported: \(developerParticleGPUUnsupportedReasonList(gpuPlan.unsupportedReasons))",
                recommendation: "Remove unsupported features from this emitter or accept CPU simulation for this effect.",
                details: gpuDetails
            )
        case .requiredButUnsupported:
            return DeveloperParticleDiagnosticSummary(
                severity: .critical,
                status: "GPU simulation blocked",
                primarySignal: "Unsupported: \(developerParticleGPUUnsupportedReasonList(gpuPlan.unsupportedReasons))",
                recommendation: "Remove unsupported modules or switch the backend to GPU If Supported/CPU before relying on this effect.",
                details: gpuDetails
            )
        }
    }

    if infoCount > 0 {
        return DeveloperParticleDiagnosticSummary(
            severity: .info,
            status: "Authoring notes",
            primarySignal: "\(infoCount) module \(infoCount == 1 ? "note" : "notes")",
            recommendation: "Review module notes when tuning the selected particle emitter.",
            details: issueDetails
        )
    }

    return DeveloperParticleDiagnosticSummary(
        severity: .idle,
        status: "No selected particle emitter",
        primarySignal: "No GPU plan or module issues",
        recommendation: "Select a particle emitter to inspect authored backend and module health.",
        details: []
    )
}

func developerParticleGPUUnsupportedReasonList(_ reasons: [ParticleGPUSimulationUnsupportedReason]) -> String {
    guard !reasons.isEmpty else { return "none" }
    return reasons.map(developerParticleGPUUnsupportedReasonLabel).joined(separator: ", ")
}

func developerParticleGPUUnsupportedReasonLabel(_ reason: ParticleGPUSimulationUnsupportedReason) -> String {
    switch reason {
    case .backendCPU:
        return "CPU backend"
    case .noParticleCapacity:
        return "no capacity"
    case .eventSubEmitters:
        return "sub-emitters"
    case .distanceEmission:
        return "distance emission"
    case .noise:
        return "noise"
    case .forceFields:
        return "force fields"
    case .collisions:
        return "collisions"
    case .angularVelocity:
        return "angular velocity"
    }
}

private func developerParticleGPUPlanDetails(_ plan: ParticleGPUSimulationPlan?) -> [String] {
    guard let plan else { return [] }
    var details = [
        "GPU plan \(developerParticleGPUPlanStatusLabel(plan.status))",
        "Capacity \(plan.particleCapacity), dispatch \(plan.dispatchWorkgroups)x\(plan.workgroupSize)",
    ]
    if !plan.unsupportedReasons.isEmpty {
        details.append("Unsupported \(developerParticleGPUUnsupportedReasonList(plan.unsupportedReasons))")
    }
    return details
}

private func developerParticleGPUPlanStatusLabel(_ status: ParticleGPUSimulationPlanStatus) -> String {
    switch status {
    case .disabled:
        return "CPU"
    case .supported:
        return "Ready"
    case .fallbackToCPU:
        return "Fallback"
    case .requiredButUnsupported:
        return "Blocked"
    }
}

private func developerParticleModuleIssueDetails(_ issues: [ParticleModuleIssue],
                                                 limit: Int = 4) -> [String] {
    guard !issues.isEmpty else { return [] }
    let clippedLimit = max(0, limit)
    var details = issues.prefix(clippedLimit).map { issue in
        "\(issue.moduleID) [\(issue.severity.rawValue)]: \(issue.message)"
    }
    if issues.count > clippedLimit {
        details.append("\(issues.count - clippedLimit) more module issues")
    }
    return details
}

private func developerParticleModuleIssuePrecedes(_ lhs: ParticleModuleIssue,
                                                  _ rhs: ParticleModuleIssue) -> Bool {
    let lhsRank = developerParticleModuleIssueSeverityRank(lhs.severity)
    let rhsRank = developerParticleModuleIssueSeverityRank(rhs.severity)
    if lhsRank != rhsRank { return lhsRank > rhsRank }
    if lhs.moduleID != rhs.moduleID { return lhs.moduleID < rhs.moduleID }
    return lhs.code < rhs.code
}

private func developerParticleModuleIssueSeverityRank(_ severity: ParticleModuleIssueSeverity) -> Int {
    switch severity {
    case .error:
        return 3
    case .warning:
        return 2
    case .info:
        return 1
    }
}

struct DeveloperParticleTrendSummary: Equatable {
    var sampleCount: Int
    var firstSampleIndex: UInt64
    var lastSampleIndex: UInt64
    var averageLiveParticleCount: Double
    var maxLiveParticleCount: Int
    var peakLiveSampleIndex: UInt64
    var liveBudgetPressureSamples: Int
    var totalRequestedSpawnCount: Int
    var totalSpawnedParticleCount: Int
    var totalDroppedSpawnCount: Int
    var totalCapacityLimitedSpawnCount: Int
    var totalSpawnBudgetLimitedCount: Int
    var totalEventDroppedSpawnCount: Int
    var totalDroppedReadbackEventCount: Int
    var peakDropSampleIndex: UInt64
    var maxDroppedSpawnCount: Int
    var maxRequestedSpawnCount: Int
    var peakSpawnRequestSampleIndex: UInt64
    var maxCPURenderInstanceCount: Int
    var maxGPURenderInstanceCount: Int
    var maxGPUSimulationParticleCount: Int
    var maxGPUWorkgroupCount: Int
    var maxSortPaddingOverhead: Double
}

func makeDeveloperParticleTrendSummary(
    history: [EditorParticleDiagnosticsSample]
) -> DeveloperParticleTrendSummary? {
    guard !history.isEmpty else { return nil }

    var liveTotal = 0
    var liveBudgetPressureSamples = 0
    var totalRequested = 0
    var totalSpawned = 0
    var totalDropped = 0
    var totalCapacityDropped = 0
    var totalBudgetDropped = 0
    var totalEventDropped = 0
    var totalReadbackDropped = 0
    var peakLiveSample = history[0]
    var peakDropSample = history[0]
    var peakRequestSample = history[0]
    var maxCPURenderInstanceCount = 0
    var maxGPURenderInstanceCount = 0
    var maxGPUSimulationParticleCount = 0
    var maxGPUWorkgroupCount = 0
    var maxSortPaddingOverhead = 0.0

    for sample in history {
        liveTotal += sample.liveParticleCount
        if sample.liveParticleLimit > 0
            && Double(sample.liveParticleCount) / Double(sample.liveParticleLimit) >= 0.9 {
            liveBudgetPressureSamples += 1
        }
        totalRequested += sample.requestedSpawnCount
        totalSpawned += sample.spawnedParticleCount
        totalDropped += sample.droppedSpawnCount
        totalCapacityDropped += sample.capacityLimitedSpawnCount
        totalBudgetDropped += sample.spawnBudgetLimitedCount
        totalEventDropped += sample.eventDroppedSpawnCount
        totalReadbackDropped += sample.droppedReadbackEventCount
        if sample.liveParticleCount > peakLiveSample.liveParticleCount {
            peakLiveSample = sample
        }
        if sample.droppedSpawnCount > peakDropSample.droppedSpawnCount {
            peakDropSample = sample
        }
        if sample.requestedSpawnCount > peakRequestSample.requestedSpawnCount {
            peakRequestSample = sample
        }
        maxCPURenderInstanceCount = max(maxCPURenderInstanceCount, sample.cpuRenderInstanceCount)
        maxGPURenderInstanceCount = max(maxGPURenderInstanceCount, sample.gpuRenderInstanceCount)
        maxGPUSimulationParticleCount = max(maxGPUSimulationParticleCount, sample.gpuSimulationParticleCount)
        maxGPUWorkgroupCount = max(maxGPUWorkgroupCount, sample.gpuWorkgroupCount)
        maxSortPaddingOverhead = max(maxSortPaddingOverhead, particleSortPaddingOverhead(sample))
    }

    return DeveloperParticleTrendSummary(
        sampleCount: history.count,
        firstSampleIndex: history[0].sampleIndex,
        lastSampleIndex: history[history.count - 1].sampleIndex,
        averageLiveParticleCount: Double(liveTotal) / Double(history.count),
        maxLiveParticleCount: peakLiveSample.liveParticleCount,
        peakLiveSampleIndex: peakLiveSample.sampleIndex,
        liveBudgetPressureSamples: liveBudgetPressureSamples,
        totalRequestedSpawnCount: totalRequested,
        totalSpawnedParticleCount: totalSpawned,
        totalDroppedSpawnCount: totalDropped,
        totalCapacityLimitedSpawnCount: totalCapacityDropped,
        totalSpawnBudgetLimitedCount: totalBudgetDropped,
        totalEventDroppedSpawnCount: totalEventDropped,
        totalDroppedReadbackEventCount: totalReadbackDropped,
        peakDropSampleIndex: peakDropSample.sampleIndex,
        maxDroppedSpawnCount: peakDropSample.droppedSpawnCount,
        maxRequestedSpawnCount: peakRequestSample.requestedSpawnCount,
        peakSpawnRequestSampleIndex: peakRequestSample.sampleIndex,
        maxCPURenderInstanceCount: maxCPURenderInstanceCount,
        maxGPURenderInstanceCount: maxGPURenderInstanceCount,
        maxGPUSimulationParticleCount: maxGPUSimulationParticleCount,
        maxGPUWorkgroupCount: maxGPUWorkgroupCount,
        maxSortPaddingOverhead: maxSortPaddingOverhead
    )
}

func makeDeveloperParticleEmitterHotspots(stats: ParticleFrameStatsResource,
                                          eventReport: ParticleSimulationEventApplyReport,
                                          limit: Int = 8) -> [DeveloperParticleEmitterHotspot] {
    let entityIDs = Set(stats.emitterStatsByEntity.keys)
        .union(eventReport.emitterStatsByEntity.keys)
    let hotspots = entityIDs.compactMap { entityID -> DeveloperParticleEmitterHotspot? in
        return makeDeveloperParticleEmitterHotspot(entityID: entityID,
                                                   frameStats: stats.emitterStats(for: entityID),
                                                   eventStats: eventReport.emitterStats(for: entityID))
    }
    return hotspots
        .sorted {
            let lhsSeverity = particleDiagnosticSeverityRank($0.severity)
            let rhsSeverity = particleDiagnosticSeverityRank($1.severity)
            if lhsSeverity != rhsSeverity { return lhsSeverity > rhsSeverity }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.entityID < $1.entityID
        }
        .prefix(max(0, limit))
        .map { $0 }
}

private func particleDiagnosticSeverityRank(_ severity: DeveloperParticleDiagnosticSeverity) -> Int {
    switch severity {
    case .critical: 4
    case .warning: 3
    case .info: 2
    case .nominal: 1
    case .idle: 0
    }
}

func makeDeveloperParticleEmitterHotspot(entityID: UInt64,
                                         frameStats: ParticleEmitterFrameStats?,
                                         eventStats: ParticleEmitterFrameStats? = nil) -> DeveloperParticleEmitterHotspot {
    guard let baseStats = frameStats ?? eventStats else {
        return DeveloperParticleEmitterHotspot(
            entityID: entityID,
            severity: .idle,
            reason: "Idle",
            primarySignal: "No particle frame or event stats",
            recommendation: "Select an active particle emitter or play the scene to collect runtime diagnostics.",
            details: [],
            score: 0,
            liveParticleCount: 0,
            requestedSpawnCount: 0,
            spawnedParticleCount: 0,
            droppedSpawnCount: 0,
            capacityLimitedSpawnCount: 0,
            spawnBudgetLimitedCount: 0,
            eventDroppedSpawnCount: 0,
            liveBudgetText: formatBudget(0, 0),
            spawnBudgetText: formatBudget(0, 0)
        )
    }
    let eventDrops = eventStats?.droppedSpawnCount ?? 0
    let frameDrops = frameStats?.droppedSpawnCount ?? 0
    let capacityDrops = (frameStats?.capacityLimitedSpawnCount ?? 0) + (eventStats?.capacityLimitedSpawnCount ?? 0)
    let budgetDrops = (frameStats?.spawnBudgetLimitedCount ?? 0) + (eventStats?.spawnBudgetLimitedCount ?? 0)
    let totalDrops = frameDrops + eventDrops
    let requested = (frameStats?.requestedSpawnCount ?? 0) + (eventStats?.requestedSpawnCount ?? 0)
    let spawned = (frameStats?.spawnedParticleCount ?? 0) + (eventStats?.spawnedParticleCount ?? 0)
    let liveCount = frameStats?.liveParticleCount ?? baseStats.liveParticleCount
    let livePressure = frameStats?.liveParticleBudgetUtilization ?? baseStats.liveParticleBudgetUtilization
    let livePressureScore = Int((livePressure * 10_000).rounded())
    let liveBudgetText = formatBudget(liveCount, baseStats.liveParticleBudgetLimit)
    let spawnBudgetText = formatBudget(
        (frameStats?.spawnBudgetConsumedCount ?? 0) + (eventStats?.spawnBudgetConsumedCount ?? 0),
        baseStats.spawnBudgetLimit
    )
    let score = totalDrops * 1_000_000
        + livePressureScore
        + requested * 100
        + liveCount

    let severity: DeveloperParticleDiagnosticSeverity
    let reason: String
    let primarySignal: String
    let recommendation: String
    let details: [String]
    if capacityDrops > 0 {
        severity = .critical
        reason = "Capacity drops"
        primarySignal = "\(capacityDrops) capacity-limited spawns"
        recommendation = "Raise this emitter's max particles/effective budget or lower lifetime and high-rate spawn sources."
        details = [
            "Live \(liveBudgetText)",
            "Frame drops \(frameDrops), event drops \(eventDrops)",
        ]
    } else if budgetDrops > 0 {
        severity = .warning
        reason = "Spawn budget drops"
        primarySignal = "\(budgetDrops) spawn-budget drops"
        recommendation = "Raise Max Spawn / Frame for this emitter or reduce burst, distance, and sub-emitter rates."
        details = [
            "Spawn budget \(spawnBudgetText)",
            "Requested \(requested), accepted \(spawned)",
        ]
    } else if livePressure >= 0.9 {
        severity = .warning
        reason = "Live budget"
        primarySignal = "\(formatPercent(liveCount, baseStats.liveParticleBudgetLimit)) live budget used"
        recommendation = "Reduce lifetime or spawn rate before this emitter starts dropping new particles."
        details = [
            "Live \(liveBudgetText)",
            "Requested \(requested), accepted \(spawned)",
        ]
    } else if requested > 0 {
        severity = .info
        reason = "High spawn requests"
        primarySignal = "\(requested) spawn requests"
        recommendation = "Audit emission curves, bursts, and distance emission if this emitter becomes a frame hotspot."
        details = [
            "Accepted \(spawned)",
            "Live \(liveBudgetText)",
        ]
    } else if liveCount > 0 {
        severity = .nominal
        reason = "Live particles"
        primarySignal = "\(liveCount) live particles"
        recommendation = "Emitter is active without spawn pressure in the latest frame."
        details = [
            "Live \(liveBudgetText)",
            "Spawn budget \(spawnBudgetText)",
        ]
    } else {
        severity = .idle
        reason = "Idle"
        primarySignal = "No live particles or spawn requests"
        recommendation = "Emitter has no particle workload in the latest frame."
        details = [
            "Live \(liveBudgetText)",
            "Spawn budget \(spawnBudgetText)",
        ]
    }

    return DeveloperParticleEmitterHotspot(
        entityID: entityID,
        severity: severity,
        reason: reason,
        primarySignal: primarySignal,
        recommendation: recommendation,
        details: details,
        score: score,
        liveParticleCount: liveCount,
        requestedSpawnCount: requested,
        spawnedParticleCount: spawned,
        droppedSpawnCount: totalDrops,
        capacityLimitedSpawnCount: capacityDrops,
        spawnBudgetLimitedCount: budgetDrops,
        eventDroppedSpawnCount: eventDrops,
        liveBudgetText: liveBudgetText,
        spawnBudgetText: spawnBudgetText
    )
}

func makeDeveloperParticleDiagnosticSummary(stats: ParticleFrameStatsResource,
                                            eventReport: ParticleSimulationEventApplyReport,
                                            scalability: ParticleScalabilityStateResource,
                                            renderSummary: ParticleRenderSummary,
                                            renderStats: RenderFrameStats) -> DeveloperParticleDiagnosticSummary {
    let frameCapacityDrops = stats.capacityLimitedSpawnCount
    let eventCapacityDrops = eventReport.capacityLimitedSpawnCount
    let frameBudgetDrops = stats.spawnBudgetLimitedCount
    let eventBudgetDrops = eventReport.spawnBudgetLimitedCount
    let hasCapacityDrops = frameCapacityDrops > 0 || eventCapacityDrops > 0
    let hasBudgetDrops = frameBudgetDrops > 0 || eventBudgetDrops > 0
    let hasReadbackDrops = eventReport.droppedReadbackEventCount > 0
    let livePressure = stats.liveParticleBudgetUtilization

    if hasReadbackDrops {
        return DeveloperParticleDiagnosticSummary(
            severity: .critical,
            status: "GPU event readback overflow",
            primarySignal: "\(eventReport.droppedReadbackEventCount) dropped readback events",
            recommendation: "Reduce event-heavy GPU particles or raise the GPU event readback capacity.",
            details: [
                "Readback \(eventReport.appliedEventCount)/\(eventReport.totalReadbackEventCount) events applied",
                "Sub-emitter spawns \(eventReport.subEmitterSpawnedCount)",
            ]
        )
    }

    if hasCapacityDrops {
        return DeveloperParticleDiagnosticSummary(
            severity: .critical,
            status: "Particle capacity saturated",
            primarySignal: "\(frameCapacityDrops + eventCapacityDrops) capacity-limited spawns",
            recommendation: "Raise max particles/effective budget or reduce lifetime and high-rate spawn sources.",
            details: [
                "Live \(stats.liveParticleCount)/\(stats.liveParticleBudgetLimit)",
                "Frame drops \(stats.droppedSpawnCount), event drops \(eventReport.droppedSpawnCount)",
            ]
        )
    }

    if hasBudgetDrops {
        return DeveloperParticleDiagnosticSummary(
            severity: .warning,
            status: "Spawn budget throttling",
            primarySignal: "\(frameBudgetDrops + eventBudgetDrops) budget-limited spawns",
            recommendation: "Raise Max Spawn / Frame for bursty emitters or reduce burst, distance, and sub-emitter rates.",
            details: [
                "Frame budget \(formatBudget(stats.spawnBudgetConsumedCount, stats.spawnBudgetLimit))",
                "Event budget \(formatBudget(eventReport.spawnBudgetConsumedCount, eventReport.spawnBudgetLimit))",
            ]
        )
    }

    if livePressure >= 0.9 {
        return DeveloperParticleDiagnosticSummary(
            severity: .warning,
            status: "Live particle budget near full",
            primarySignal: "\(formatPercent(stats.liveParticleCount, stats.liveParticleBudgetLimit)) live budget used",
            recommendation: "Reduce lifetime/spawn rates or raise the live-particle scalability budget before drops start.",
            details: [
                "Live \(stats.liveParticleCount)/\(stats.liveParticleBudgetLimit)",
                "Scalability \(scalability.reason.rawValue) @ \(formatScale(scalability.pressure))",
            ]
        )
    }

    let sortPaddingOverhead = particleSortPaddingOverhead(renderStats)
    if sortPaddingOverhead >= 0.5 && renderStats.gpuParticleSortItemCount >= 512 {
        return DeveloperParticleDiagnosticSummary(
            severity: .warning,
            status: "GPU sort padding overhead",
            primarySignal: "\(formatPercent(renderStats.gpuParticleSortPaddedItemCount - renderStats.gpuParticleSortItemCount, renderStats.gpuParticleSortPaddedItemCount)) padding",
            recommendation: "Reduce sorted GPU particles or split effects so sort passes work on tighter batches.",
            details: [
                "Sort items \(renderStats.gpuParticleSortItemCount)",
                "Sort workgroups \(renderStats.gpuParticleSortDispatchWorkgroups)",
            ]
        )
    }

    if renderSummary.renderBudgetSkippedSourceParticleCount > 0 {
        return DeveloperParticleDiagnosticSummary(
            severity: .info,
            status: "Particle render budget limiting",
            primarySignal: "\(renderSummary.renderBudgetSkippedSourceParticleCount) source particles skipped before render",
            recommendation: "Tune Max Rendered Particles and render LOD so simulation cost and visual density stay balanced.",
            details: [
                "Source \(renderSummary.sourceParticleCount), submitted \(renderSummary.submittedSourceParticleCount)",
                "Render instances \(renderSummary.particleCount)",
            ]
        )
    }

    let averageBatchSize = particleAverageBatchSize(renderSummary)
    if renderSummary.batchCount >= 8 && averageBatchSize < 4 {
        return DeveloperParticleDiagnosticSummary(
            severity: .info,
            status: "Particle batches fragmented",
            primarySignal: "\(renderSummary.batchCount) batches for \(renderSummary.particleCount) particles",
            recommendation: "Align blend mode, texture, and sort priority across related emitters to improve batching.",
            details: [
                "Average \(formatDecimal(averageBatchSize)) particles/batch",
                "Textures \(renderSummary.uniqueTextureCount), CPU/GPU \(renderSummary.cpuBatchCount)/\(renderSummary.gpuBatchCount)",
            ]
        )
    }

    if stats.activeEmitterCount == 0 && renderSummary.particleCount == 0 {
        return DeveloperParticleDiagnosticSummary(
            severity: .idle,
            status: "No active particle workload",
            primarySignal: "No live particles or submitted batches",
            recommendation: "Select or enable a particle emitter to inspect runtime behavior.",
            details: [
                "Emitters \(stats.emitterCount)",
                "Frame sample \(formatMs(Double(stats.simulatedDeltaTime) * 1000))",
            ]
        )
    }

    if renderSummary.gpuRenderInstanceCount > 0 {
        return DeveloperParticleDiagnosticSummary(
            severity: .nominal,
            status: "GPU particle path active",
            primarySignal: "\(renderSummary.gpuRenderInstanceCount) GPU render instances",
            recommendation: "Watch sort padding, readback drops, and GPU workgroup split as effect complexity grows.",
            details: [
                "GPU batches \(renderSummary.gpuBatchCount)",
                "GPU workgroups \(gpuParticleWorkgroupTotal(renderStats))",
            ]
        )
    }

    return DeveloperParticleDiagnosticSummary(
        severity: .nominal,
        status: "CPU particle path active",
        primarySignal: "\(renderSummary.cpuRenderInstanceCount) CPU render instances",
        recommendation: "Move high-volume compatible emitters to GPU simulation when CPU particles become a bottleneck.",
        details: [
            "CPU batches \(renderSummary.cpuBatchCount)",
            "Live particles \(stats.liveParticleCount)",
        ]
    )
}

private struct ParticleDiagnosticsTabView: View {
    let app: EditorApplication
    let store: EditorStore

    var body: some View {
        ParticleDiagnosticsView(
            stats: app.currentParticleFrameStats(),
            eventReport: app.currentParticleSimulationEventApplyReport(),
            scalability: app.currentParticleScalabilityState(),
            renderSummary: app.currentRenderScene().particleSummary,
            renderStats: app.currentRenderStats(),
            history: store.particleDiagnosticsHistory,
            selectedEntityID: store.selectedEntityID,
            emitterLabels: makeDeveloperParticleEmitterLabels(roots: app.scene.roots),
            selectedGPUSimulationPlan: app.scene.currentParticleGPUSimulationPlan(for: store.selectedEntityID),
            selectedModuleValidationIssues: app.scene.currentParticleModuleValidationIssues(for: store.selectedEntityID)
        )
    }
}

private struct ParticleDiagnosticsView: View {
    let stats: ParticleFrameStatsResource
    let eventReport: ParticleSimulationEventApplyReport
    let scalability: ParticleScalabilityStateResource
    let renderSummary: ParticleRenderSummary
    let renderStats: RenderFrameStats
    let history: [EditorParticleDiagnosticsSample]
    let selectedEntityID: UInt64?
    let emitterLabels: [UInt64: DeveloperParticleEmitterLabel]
    let selectedGPUSimulationPlan: ParticleGPUSimulationPlan?
    let selectedModuleValidationIssues: [ParticleModuleIssue]

    var body: some View {
        let summary = makeDeveloperParticleDiagnosticSummary(stats: stats,
                                                             eventReport: eventReport,
                                                             scalability: scalability,
                                                             renderSummary: renderSummary,
                                                             renderStats: renderStats)
        let trend = makeDeveloperParticleTrendSummary(history: history)
        let authoringSummary = makeDeveloperParticleAuthoringDiagnosticSummary(
            gpuPlan: selectedGPUSimulationPlan,
            moduleIssues: selectedModuleValidationIssues
        )
        let hotspots = makeDeveloperParticleEmitterHotspots(stats: stats,
                                                            eventReport: eventReport)
        let selectedHotspot = selectedEntityID.flatMap { entityID -> DeveloperParticleEmitterHotspot? in
            let frameStats = stats.emitterStats(for: entityID)
            let eventStats = eventReport.emitterStats(for: entityID)
            guard frameStats != nil || eventStats != nil else {
                return nil
            }
            return makeDeveloperParticleEmitterHotspot(entityID: entityID,
                                                       frameStats: frameStats,
                                                       eventStats: eventStats)
        }
        ScrollView(.vertical) {
            ParticleHealthOverview(summary: summary,
                                   stats: stats,
                                   eventReport: eventReport,
                                   renderSummary: renderSummary)
                .padding(horizontal: 12, vertical: 10)

            Divider()

            if let trend {
                ParticleTrendOverview(trend: trend)
                    .padding(horizontal: 12, vertical: 10)

                Divider()
            }

            ParticleEmitterHotspotsView(hotspots: hotspots,
                                        selectedHotspot: selectedHotspot,
                                        selectedEntityID: selectedEntityID,
                                        emitterLabels: emitterLabels,
                                        authoringSummary: authoringSummary)
                .padding(horizontal: 12, vertical: 10)

            Divider()

            Row(alignment: .top, spacing: 12) {
                StatGroup(title: "Emitters") {
                    StatRow(label: "Total", value: "\(stats.emitterCount)")
                    StatRow(label: "Active", value: "\(stats.activeEmitterCount)")
                    StatRow(label: "Sim Step", value: formatMs(Double(stats.simulatedDeltaTime) * 1000))
                    StatRow(label: "Live", value: "\(stats.liveParticleCount)")
                    StatRow(label: "Configured Cap", value: "\(stats.maxParticleCount)")
                    StatRow(label: "Effective Cap", value: "\(stats.liveParticleLimit)")
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Spawned") {
                    StatRow(label: "Requested", value: "\(stats.requestedSpawnCount)")
                    StatRow(label: "Total", value: "\(stats.spawnedParticleCount)")
                    StatRow(label: "Continuous", value: "\(stats.continuousSpawnedCount)")
                    StatRow(label: "Burst", value: "\(stats.burstSpawnedCount)")
                    StatRow(label: "Distance", value: "\(stats.distanceSpawnedCount)")
                    StatRow(label: "Sub-Emitter", value: "\(stats.subEmitterSpawnedCount)")
                    StatRow(label: "Total Drops", value: "\(stats.droppedSpawnCount)")
                    StatRow(label: "Capacity Drops", value: "\(stats.capacityLimitedSpawnCount)")
                    StatRow(label: "Spawn Budget Drops", value: "\(stats.spawnBudgetLimitedCount)")
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Lifecycle") {
                    StatRow(label: "Expired", value: "\(stats.expiredParticleCount)")
                    StatRow(label: "Collisions", value: "\(stats.collisionCount)")
                    StatRow(label: "Live / Config", value: formatPercent(stats.liveParticleCount,
                                                                          stats.maxParticleCount))
                    StatRow(label: "Live / Effective", value: formatPercent(stats.liveParticleCount,
                                                                             stats.liveParticleLimit))
                    StatRow(label: "Spawn Budget", value: formatBudget(stats.spawnBudgetConsumedCount,
                                                                        stats.spawnBudgetLimit))
                    StatRow(label: "Spawn Budget Use", value: formatPercent(stats.spawnBudgetConsumedCount,
                                                                             stats.spawnBudgetLimit))
                    StatRow(label: "Drop Rate", value: formatPercent(stats.droppedSpawnCount,
                                                                      stats.spawnedParticleCount
                                                                        + stats.droppedSpawnCount))
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 12, vertical: 10)

            Divider()

            Row(alignment: .top, spacing: 12) {
                StatGroup(title: "Scalability Signals") {
                    StatRow(label: "Applied Scale", value: formatScale(scalability.appliedScale))
                    StatRow(label: "Pressure", value: formatScale(scalability.pressure))
                    StatRow(label: "Reason", value: scalability.reason.rawValue)
                    StatRow(label: "At Effective Cap", value: stats.liveParticleLimit > 0
                            && stats.liveParticleCount >= stats.liveParticleLimit ? "YES" : "NO")
                    StatRow(label: "Spawn Pressure", value: stats.droppedSpawnCount > 0 ? "YES" : "NO")
                    StatRow(label: "Event Activity", value: stats.subEmitterSpawnedCount > 0
                            || stats.collisionCount > 0 ? "YES" : "NO")
                    StatRow(label: "Idle", value: stats.activeEmitterCount == 0 ? "YES" : "NO")
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Event Feedback") {
                    StatRow(label: "Emitters", value: "\(eventReport.appliedEmitterCount)/\(eventReport.requestedEmitterCount)")
                    StatRow(label: "Events", value: "\(eventReport.appliedEventCount)/\(eventReport.eventCount)")
                    StatRow(label: "GPU Readback", value: "\(eventReport.totalReadbackEventCount)")
                    StatRow(label: "Dropped Events", value: "\(eventReport.droppedReadbackEventCount)")
                    StatRow(label: "Deaths", value: "\(eventReport.deathEventCount)")
                    StatRow(label: "Collisions", value: "\(eventReport.collisionEventCount)")
                    StatRow(label: "Spawn Requests", value: "\(eventReport.requestedSpawnCount)")
                    StatRow(label: "Spawn Budget", value: formatBudget(eventReport.spawnBudgetConsumedCount,
                                                                        eventReport.spawnBudgetLimit))
                    StatRow(label: "Sub-Emitter Spawns", value: "\(eventReport.subEmitterSpawnedCount)")
                    StatRow(label: "Total Drops", value: "\(eventReport.droppedSpawnCount)")
                    StatRow(label: "Capacity Drops", value: "\(eventReport.capacityLimitedSpawnCount)")
                    StatRow(label: "Spawn Budget Drops", value: "\(eventReport.spawnBudgetLimitedCount)")
                    StatRow(label: "Missing Emitters", value: "\(eventReport.missingEmitterCount)")
                    StatRow(label: "Empty Buckets", value: "\(eventReport.emptyEventEmitterCount)")
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Render Batches") {
                    StatRow(label: "Submitted", value: "\(renderSummary.particleCount)")
                    StatRow(label: "Source", value: "\(renderSummary.sourceParticleCount)")
                    StatRow(label: "Submitted Source", value: "\(renderSummary.submittedSourceParticleCount)")
                    StatRow(label: "Render Skips", value: "\(renderSummary.renderBudgetSkippedSourceParticleCount)")
                    StatRow(label: "CPU Submitted", value: "\(renderSummary.cpuRenderInstanceCount)")
                    StatRow(label: "GPU Submitted", value: "\(renderSummary.gpuRenderInstanceCount)")
                    StatRow(label: "Batches", value: "\(renderSummary.batchCount)")
                    StatRow(label: "CPU Batches", value: "\(renderSummary.cpuBatchCount)")
                    StatRow(label: "GPU Batches", value: "\(renderSummary.gpuBatchCount)")
                    StatRow(label: "Alpha", value: "\(renderSummary.alphaCount)")
                    StatRow(label: "Additive", value: "\(renderSummary.additiveCount)")
                    StatRow(label: "Textured", value: "\(renderSummary.texturedCount)")
                    StatRow(label: "Unique Textures", value: "\(renderSummary.uniqueTextureCount)")
                }
                .flex(1, shrink: 1)

                StatGroup(title: "GPU Simulation") {
                    StatRow(label: "Batches", value: "\(renderStats.gpuParticleSimulationBatchCount)")
                    StatRow(label: "Particles", value: "\(renderStats.gpuParticleSimulationParticleCount)")
                    StatRow(label: "Sim Workgroups", value: "\(renderStats.gpuParticleSimulationDispatchWorkgroups)")
                    StatRow(label: "Render Instances", value: "\(renderStats.gpuParticleRenderInstanceCount)")
                    StatRow(label: "Instance Workgroups", value: "\(renderStats.gpuParticleInstanceDispatchWorkgroups)")
                    StatRow(label: "Indirect Draws", value: "\(renderStats.gpuParticleIndirectDrawCount)")
                    StatRow(label: "Cull Batches", value: "\(renderStats.gpuParticleCullBatchCount)")
                    StatRow(label: "Cull Candidates", value: "\(renderStats.gpuParticleCullCandidateCount)")
                    StatRow(label: "Cull Workgroups", value: "\(renderStats.gpuParticleCullDispatchWorkgroups)")
                    StatRow(label: "Encode", value: formatNs(renderStats.gpuParticleSimulationEncodeNS))
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 12, vertical: 10)

            Row(alignment: .top, spacing: 12) {
                StatGroup(title: "GPU Sort") {
                    StatRow(label: "Passes", value: "\(renderStats.gpuParticleSortPassCount)")
                    StatRow(label: "Items", value: "\(renderStats.gpuParticleSortItemCount)")
                    StatRow(label: "Padded Items", value: "\(renderStats.gpuParticleSortPaddedItemCount)")
                    StatRow(label: "Padding Overhead", value: formatPercent(
                        renderStats.gpuParticleSortPaddedItemCount - renderStats.gpuParticleSortItemCount,
                        renderStats.gpuParticleSortPaddedItemCount
                    ))
                    StatRow(label: "Workgroups", value: "\(renderStats.gpuParticleSortDispatchWorkgroups)")
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Frame Balance") {
                    StatRow(label: "Spawned - Expired",
                            value: "\(stats.spawnedParticleCount - stats.expiredParticleCount)")
                    StatRow(label: "Event Spawn Share", value: formatPercent(stats.subEmitterSpawnedCount,
                                                                              stats.spawnedParticleCount))
                    StatRow(label: "Distance Spawn Share", value: formatPercent(stats.distanceSpawnedCount,
                                                                                 stats.spawnedParticleCount))
                    StatRow(label: "Burst Spawn Share", value: formatPercent(stats.burstSpawnedCount,
                                                                              stats.spawnedParticleCount))
                }
                .flex(1, shrink: 1)

                StatGroup(title: "GPU Work Split") {
                    StatRow(label: "Total", value: "\(gpuParticleWorkgroupTotal(renderStats))")
                    StatRow(label: "Sim", value: formatPercent(
                        renderStats.gpuParticleSimulationDispatchWorkgroups,
                        gpuParticleWorkgroupTotal(renderStats)
                    ))
                    StatRow(label: "Sort", value: formatPercent(
                        renderStats.gpuParticleSortDispatchWorkgroups,
                        gpuParticleWorkgroupTotal(renderStats)
                    ))
                    StatRow(label: "Instance", value: formatPercent(
                        renderStats.gpuParticleInstanceDispatchWorkgroups,
                        gpuParticleWorkgroupTotal(renderStats)
                    ))
                    StatRow(label: "Cull", value: formatPercent(
                        renderStats.gpuParticleCullDispatchWorkgroups,
                        gpuParticleWorkgroupTotal(renderStats)
                    ))
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 12, vertical: 10)
        }
    }
}

private struct ParticleHealthOverview: View {
    let summary: DeveloperParticleDiagnosticSummary
    let stats: ParticleFrameStatsResource
    let eventReport: ParticleSimulationEventApplyReport
    let renderSummary: ParticleRenderSummary

    var body: some View {
        Row(alignment: .top, spacing: 12) {
            StatGroup(title: "Particle Health") {
                StatRow(label: "Status", value: summary.status)
                ParticleSeverityRow(severity: summary.severity)
                StatWrappedValue(label: "Signal", value: summary.primarySignal)
                StatWrappedValue(label: "Action", value: summary.recommendation)
            }
            .flex(1.25, shrink: 1)

            StatGroup(title: "Spawn Throughput") {
                StatRow(label: "Requests", value: "\(stats.requestedSpawnCount)")
                StatRow(label: "Accepted", value: "\(stats.spawnedParticleCount)")
                StatRow(label: "Drop Rate", value: formatPercent(stats.droppedSpawnCount,
                                                                  stats.spawnedParticleCount
                                                                    + stats.droppedSpawnCount))
                StatRow(label: "Budget", value: formatBudget(stats.spawnBudgetConsumedCount,
                                                              stats.spawnBudgetLimit))
                StatRow(label: "Event Requests", value: "\(eventReport.requestedSpawnCount)")
                StatRow(label: "Event Drops", value: "\(eventReport.droppedSpawnCount)")
            }
            .flex(1, shrink: 1)

            StatGroup(title: "Render Path") {
                StatRow(label: "Submitted", value: "\(renderSummary.particleCount)")
                StatRow(label: "CPU / GPU", value: "\(renderSummary.cpuRenderInstanceCount)/\(renderSummary.gpuRenderInstanceCount)")
                StatRow(label: "Batches", value: "\(renderSummary.batchCount)")
                StatRow(label: "Avg / Batch", value: formatDecimal(particleAverageBatchSize(renderSummary)))
                StatRow(label: "Textures", value: "\(renderSummary.uniqueTextureCount)")
                if summary.details.isEmpty {
                    StatRow(label: "Detail", value: "--")
                } else {
                    StatWrappedValue(label: "Detail", value: summary.details.joined(separator: " | "))
                }
            }
            .flex(1, shrink: 1)
        }
    }
}

private struct ParticleTrendOverview: View {
    let trend: DeveloperParticleTrendSummary

    var body: some View {
        Row(alignment: .top, spacing: 12) {
            StatGroup(title: "Particle Trend") {
                StatRow(label: "Samples", value: "\(trend.sampleCount)")
                StatRow(label: "Window", value: "#\(trend.firstSampleIndex)-#\(trend.lastSampleIndex)")
                StatRow(label: "Avg Live", value: formatDecimal(trend.averageLiveParticleCount))
                StatRow(label: "Max Live", value: "\(trend.maxLiveParticleCount)")
                StatRow(label: "Peak Live Sample", value: "#\(trend.peakLiveSampleIndex)")
                StatRow(label: "Live Pressure", value: "\(trend.liveBudgetPressureSamples)/\(trend.sampleCount)")
            }
            .flex(1, shrink: 1)

            StatGroup(title: "Spawn Trend") {
                StatRow(label: "Requests", value: "\(trend.totalRequestedSpawnCount)")
                StatRow(label: "Accepted", value: "\(trend.totalSpawnedParticleCount)")
                StatRow(label: "Drops", value: "\(trend.totalDroppedSpawnCount)")
                StatRow(label: "Capacity Drops", value: "\(trend.totalCapacityLimitedSpawnCount)")
                StatRow(label: "Budget Drops", value: "\(trend.totalSpawnBudgetLimitedCount)")
                StatRow(label: "Peak Drop", value: "#\(trend.peakDropSampleIndex) / \(trend.maxDroppedSpawnCount)")
                StatRow(label: "Peak Request", value: "#\(trend.peakSpawnRequestSampleIndex) / \(trend.maxRequestedSpawnCount)")
            }
            .flex(1, shrink: 1)

            StatGroup(title: "GPU / Events") {
                StatRow(label: "Event Drops", value: "\(trend.totalEventDroppedSpawnCount)")
                StatRow(label: "Readback Drops", value: "\(trend.totalDroppedReadbackEventCount)")
                StatRow(label: "Max CPU Render", value: "\(trend.maxCPURenderInstanceCount)")
                StatRow(label: "Max GPU Render", value: "\(trend.maxGPURenderInstanceCount)")
                StatRow(label: "Max GPU Sim", value: "\(trend.maxGPUSimulationParticleCount)")
                StatRow(label: "Max GPU Workgroups", value: "\(trend.maxGPUWorkgroupCount)")
                StatRow(label: "Max Sort Padding", value: formatPercentFraction(trend.maxSortPaddingOverhead))
            }
            .flex(1, shrink: 1)
        }
    }
}

private struct ParticleEmitterHotspotsView: View {
    let hotspots: [DeveloperParticleEmitterHotspot]
    let selectedHotspot: DeveloperParticleEmitterHotspot?
    let selectedEntityID: UInt64?
    let emitterLabels: [UInt64: DeveloperParticleEmitterLabel]
    let authoringSummary: DeveloperParticleDiagnosticSummary

    var body: some View {
        Row(alignment: .top, spacing: 12) {
            StatGroup(title: "Selected Emitter") {
                if let selectedHotspot {
                    ParticleEmitterHotspotDetail(hotspot: selectedHotspot,
                                                 label: emitterLabels[selectedHotspot.entityID])
                } else if let selectedEntityID {
                    if let label = emitterLabels[selectedEntityID] {
                        StatRow(label: "Entity", value: label.name)
                        StatRow(label: "ID", value: "#\(selectedEntityID)")
                        StatWrappedValue(label: "Path", value: label.path)
                    } else {
                        StatRow(label: "Entity", value: "#\(selectedEntityID)")
                    }
                    StatWrappedValue(label: "Status",
                                     value: "Selected entity has no particle runtime stats in the latest frame.")
                } else {
                    StatWrappedValue(label: "Status",
                                     value: "Select a particle emitter to inspect per-emitter runtime pressure.")
                }
                if selectedEntityID != nil {
                    ParticleAuthoringDiagnosticRows(summary: authoringSummary)
                }
            }
            .flex(1, shrink: 1)

            StatGroup(title: "Emitter Hotspots") {
                if hotspots.isEmpty {
                    StatWrappedValue(label: "Hotspots",
                                     value: "No particle emitters reported runtime activity in the latest frame.")
                } else {
                    for hotspot in hotspots {
                        ParticleEmitterHotspotRow(hotspot: hotspot,
                                                  label: emitterLabels[hotspot.entityID],
                                                  isSelected: hotspot.entityID == selectedEntityID)
                    }
                }
            }
            .flex(1.4, shrink: 1)
        }
    }
}

private struct ParticleAuthoringDiagnosticRows: View {
    let summary: DeveloperParticleDiagnosticSummary

    var body: some View {
        StatRow(label: "Authoring", value: summary.status)
        ParticleSeverityRow(severity: summary.severity)
        StatWrappedValue(label: "Author Signal", value: summary.primarySignal)
        StatWrappedValue(label: "Author Action", value: summary.recommendation)
        if !summary.details.isEmpty {
            StatWrappedValue(label: "Author Details", value: summary.details.joined(separator: " | "))
        }
    }
}

private struct ParticleEmitterHotspotDetail: View {
    let hotspot: DeveloperParticleEmitterHotspot
    let label: DeveloperParticleEmitterLabel?

    var body: some View {
        if let label {
            StatRow(label: "Entity", value: label.name)
            StatRow(label: "Kind", value: label.kind)
            StatRow(label: "ID", value: "#\(hotspot.entityID)")
            StatWrappedValue(label: "Path", value: label.path)
        } else {
            StatRow(label: "Entity", value: "#\(hotspot.entityID)")
        }
        StatRow(label: "Reason", value: hotspot.reason)
        StatWrappedValue(label: "Signal", value: hotspot.primarySignal)
        StatWrappedValue(label: "Action", value: hotspot.recommendation)
        if !hotspot.details.isEmpty {
            StatWrappedValue(label: "Details", value: hotspot.details.joined(separator: " | "))
        }
        StatRow(label: "Live", value: hotspot.liveBudgetText)
        StatRow(label: "Requests", value: "\(hotspot.requestedSpawnCount)")
        StatRow(label: "Accepted", value: "\(hotspot.spawnedParticleCount)")
        StatRow(label: "Drops", value: "\(hotspot.droppedSpawnCount)")
        StatRow(label: "Capacity Drops", value: "\(hotspot.capacityLimitedSpawnCount)")
        StatRow(label: "Budget Drops", value: "\(hotspot.spawnBudgetLimitedCount)")
        StatRow(label: "Spawn Budget", value: hotspot.spawnBudgetText)
    }
}

private struct ParticleEmitterHotspotRow: View {
    let hotspot: DeveloperParticleEmitterHotspot
    let label: DeveloperParticleEmitterLabel?
    let isSelected: Bool

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Text(isSelected ? "*" : "")
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.accent)
                .frame(width: 8)

            Text(label?.name ?? "#\(hotspot.entityID)")
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(.onSurface)
                .frame(width: 112)

            Text(hotspot.severity.rawValue)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(particleSeverityForeground(hotspot.severity))
                .padding(horizontal: 6, vertical: 2)
                .background(particleSeverityBackground(hotspot.severity))
                .cornerRadius(4)

            Text(hotspot.reason)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurface)
                .flex(1, shrink: 1)

            Text(hotspot.primarySignal)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1)

            Text("#\(hotspot.entityID)")
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 8, vertical: 3)
    }
}

private struct ParticleSeverityRow: View {
    let severity: DeveloperParticleDiagnosticSeverity

    var body: some View {
        Row(alignment: .center, spacing: 0) {
            Text("Severity")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1)

            Text(severity.rawValue)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(particleSeverityForeground(severity))
                .padding(horizontal: 7, vertical: 2)
                .background(particleSeverityBackground(severity))
                .cornerRadius(4)
        }
        .padding(horizontal: 8, vertical: 2)
    }
}

private struct ConsoleDiagnosticsView: View {
    let store: EditorStore

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Row(alignment: .center, spacing: 8) {
                Text(L("Console"))
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text("\(store.consoleEntries.count)")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)

                Spacer(minLength: 0)

                Button(action: { store.dispatch(.clearConsole) }) {
                    Text(L("Clear"))
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(horizontal: 12, vertical: 8)

            Divider()

            ScrollView(.vertical) {
                Column(alignment: .leading, spacing: 4) {
                    if store.consoleEntries.isEmpty {
                        DeveloperConsoleRow(entry: EditorConsoleEntry(id: 0,
                                                                       severity: .info,
                                                                       message: L("No console messages")))
                    } else {
                        for entry in store.consoleEntries.suffix(120) {
                            DeveloperConsoleRow(entry: entry)
                        }
                    }
                }
                .padding(horizontal: 12, vertical: 8)
            }
            .flex(1, shrink: 1)
        }
    }
}

private struct DeveloperConsoleRow: View {
    let entry: EditorConsoleEntry

    var body: some View {
        Row(alignment: .top, spacing: 8) {
            Text(severityLabel)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(severityColor)
                .frame(width: 44)

            Column(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(messageColor)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .lineLimit(2)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }
            .flex(1, shrink: 1)
        }
    }

    private var severityLabel: String {
        switch entry.severity {
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERR"
        }
    }

    private var severityColor: SemanticColorRef {
        switch entry.severity {
        case .info: return .onSurfaceMuted
        case .warning: return .warning
        case .error: return .error
        }
    }

    private var messageColor: SemanticColorRef {
        switch entry.severity {
        case .info: return .onSurfaceMuted
        case .warning: return .warning
        case .error: return .error
        }
    }
}

private struct StatGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Row(alignment: .center, spacing: 6) {
                Box { EmptyView() }
                    .frame(width: 3, height: 16)
                    .background(.accent)
                    .cornerRadius(2)
                Text(title)
                    .lineLimit(1)
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                    .flex(1, shrink: 1)
            }
            .padding(horizontal: 10, vertical: 7)

            Column(alignment: .leading, spacing: 0) {
                content
            }
            .padding(horizontal: 4, vertical: 6)
        }
        .background(.surfaceSunken)
        .cornerRadius(6)
        .border(.border, width: 1)
    }
}

private struct FramePacingNotice: View {
    let stats: EditorFrameStats

    var body: some View {
        Row(alignment: .center, spacing: 10) {
            Box { EmptyView() }
                .frame(width: 8, height: 8)
                .background(.warning)
                .cornerRadius(4)

            Column(alignment: .leading, spacing: 2) {
                Text("Frame pacing gap")
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text("Observed \(formatMs(stats.frameMs)) tick gap; actual work is \(formatMs(stats.workMs)), with \(formatMs(stats.pacingGapMs)) waiting/idle.")
                    .lineLimit(2)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .flex(1, shrink: 1)

            Text(bottleneck(stats))
                .font(.bodyStrong)
                .foregroundColor(.warning)
                .padding(horizontal: 8, vertical: 4)
                .background(.surface)
                .cornerRadius(4)
                .border(.warning.opacity(0.25), width: 1)
        }
        .padding(horizontal: 12, vertical: 10)
        .background(.surfaceSunken)
        .cornerRadius(6)
        .border(.warning.opacity(0.35), width: 1)
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        Row(alignment: .center, spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1)

            Text(value)
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(.onSurface)
        }
        .padding(horizontal: 8, vertical: 2)
    }
}

private struct StatWrappedValue: View {
    let label: String
    let value: String

    var body: some View {
        Column(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 8, vertical: 2)
            Text(value)
                .lineLimit(3)
                .font(.mono)
                .foregroundColor(.onSurface)
                .padding(horizontal: 8, vertical: 2)
        }
    }
}

private func formatFPS(_ fps: Double) -> String {
    if fps <= 0 { return "--" }
    if fps >= 1000 { return "---" }
    return String(format: "%.0f", fps)
}

private func formatMs(_ ms: Double) -> String {
    if ms <= 0 { return "--ms" }
    if ms < 10 { return String(format: "%.2fms", ms) }
    if ms < 100 { return String(format: "%.1fms", ms) }
    return String(format: "%.0fms", ms)
}

private func formatNs(_ ns: UInt64) -> String {
    if ns == 0 { return "--" }
    let ms = Double(ns) / 1_000_000.0
    if ms < 0.01 { return String(format: "%.3fms", ms) }
    if ms < 10 { return String(format: "%.2fms", ms) }
    if ms < 100 { return String(format: "%.1fms", ms) }
    return String(format: "%.0fms", ms)
}

private func formatSignedMs(_ ms: Double) -> String {
    guard ms.isFinite else { return "--ms" }
    if ms == 0 { return "0.00ms" }
    let prefix = ms > 0 ? "+" : "-"
    return "\(prefix)\(formatMs(abs(ms)))"
}

private func gpuParticleWorkgroupTotal(_ stats: RenderFrameStats) -> Int {
    stats.gpuParticleSimulationDispatchWorkgroups
        + stats.gpuParticleSortDispatchWorkgroups
        + stats.gpuParticleInstanceDispatchWorkgroups
        + stats.gpuParticleCullDispatchWorkgroups
}

func particleAverageBatchSize(_ summary: ParticleRenderSummary) -> Double {
    guard summary.batchCount > 0 else { return 0 }
    return Double(summary.particleCount) / Double(summary.batchCount)
}

func particleSortPaddingOverhead(_ stats: RenderFrameStats) -> Double {
    guard stats.gpuParticleSortPaddedItemCount > 0,
          stats.gpuParticleSortPaddedItemCount >= stats.gpuParticleSortItemCount
    else { return 0 }
    let padding = stats.gpuParticleSortPaddedItemCount - stats.gpuParticleSortItemCount
    return Double(padding) / Double(stats.gpuParticleSortPaddedItemCount)
}

func particleSortPaddingOverhead(_ sample: EditorParticleDiagnosticsSample) -> Double {
    guard sample.gpuSortPaddedItemCount > 0,
          sample.gpuSortPaddedItemCount >= sample.gpuSortItemCount
    else { return 0 }
    let padding = sample.gpuSortPaddedItemCount - sample.gpuSortItemCount
    return Double(padding) / Double(sample.gpuSortPaddedItemCount)
}

func percentile(_ values: [Double], fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let clampedFraction = min(max(fraction, 0), 1)
    let sortedValues = values.sorted()
    let rawIndex = clampedFraction * Double(sortedValues.count - 1)
    let index = Int(rawIndex.rounded(.up))
    return sortedValues[min(max(index, 0), sortedValues.count - 1)]
}

private func particleSeverityForeground(_ severity: DeveloperParticleDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
    case .idle:
        return .onSurfaceMuted
    case .nominal:
        return .success
    case .info:
        return .info
    case .warning:
        return .warning
    case .critical:
        return .error
    }
}

private func particleSeverityBackground(_ severity: DeveloperParticleDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
    case .idle:
        return .surface
    case .nominal:
        return .success.opacity(0.12)
    case .info:
        return .info.opacity(0.12)
    case .warning:
        return .warning.opacity(0.12)
    case .critical:
        return .error.opacity(0.12)
    }
}

private func formatPercent(_ numerator: Int, _ denominator: Int) -> String {
    guard denominator > 0 else { return "--" }
    let percent = Double(numerator) / Double(denominator) * 100
    if percent < 10 { return String(format: "%.1f%%", percent) }
    return String(format: "%.0f%%", percent)
}

private func formatPercentFraction(_ value: Double) -> String {
    guard value.isFinite else { return "--" }
    let percent = value * 100
    if percent < 10 { return String(format: "%.1f%%", percent) }
    return String(format: "%.0f%%", percent)
}

private func formatBudget(_ used: Int, _ limit: Int) -> String {
    limit > 0 ? "\(used)/\(limit)" : "\(used)/unlimited"
}

private func formatDecimal(_ value: Double) -> String {
    guard value.isFinite else { return "--" }
    if value >= 10 { return String(format: "%.0f", value) }
    return String(format: "%.1f", value)
}

private func formatScale(_ value: Float) -> String {
    guard value.isFinite else { return "--" }
    return String(format: "%.2f", value)
}

private func cpuMs(_ stats: EditorFrameStats) -> Double {
    stats.cpuWorkSeconds * 1000
}

private func budgetStatus(frameMs: Double, targetMs: Double) -> String {
    guard frameMs > 0 else { return "--" }
    if frameMs <= targetMs { return "OK" }
    return "+\(formatMs(frameMs - targetMs))"
}

private func bottleneck(_ stats: EditorFrameStats) -> String {
    let cpu = cpuMs(stats)
    let gpu = stats.gpuPresentSeconds * 1000
    guard stats.workMs > 0 else { return "--" }
    if cpu <= 0, gpu <= 0 { return "Frame pacing" }
    if stats.isFramePacingDominated {
        return "Frame pacing / idle"
    }
    if cpu > gpu * 1.25 { return "CPU" }
    if gpu > cpu * 1.25 { return "GPU / present" }
    return "Mixed"
}

private func averageDrawsPerPass(_ stats: EditorFrameStats) -> String {
    guard stats.passCount > 0 else { return "--" }
    let average = Double(stats.drawCallCount) / Double(stats.passCount)
    if average < 10 { return String(format: "%.1f", average) }
    return String(format: "%.0f", average)
}
