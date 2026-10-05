import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct DeveloperToolsPanel: View {
    let app: EditorApplication

    @State private var selectedTab: DeveloperToolTab = .profiler
    @State private var selectedFrameSampleIndex: UInt64?
    @State private var selectedPerformanceMonitorSampleIndex: UInt64?
    @State private var selectedPerformanceMonitorIDs: Set<DeveloperPerformanceMonitorID> = DeveloperPerformanceMonitorID.defaultSelection

    var body: some View {
        StoreScope(app.store) { store in
            let timingRevision = store.frameTimingRevision
            let frameStats = store.frameStats
            let frameStatsHistory = store.frameStatsHistory
            let needsRenderSnapshot = selectedTab == .profiler
                || selectedTab == .monitors
                || selectedTab == .render
                || selectedTab == .particles
                || selectedTab == .debugger
                || selectedTab == .trace
            let needsParticleSnapshot = selectedTab == .profiler
                || selectedTab == .monitors
                || selectedTab == .particles
                || selectedTab == .trace
            let renderStats: RenderFrameStats = needsRenderSnapshot
                ? app.currentRenderStats()
                : .init()
            let particleStats = needsParticleSnapshot
                ? app.currentParticleFrameStats()
                : ParticleFrameStatsResource.empty
            let particleEventReport = needsParticleSnapshot
                ? app.currentParticleSimulationEventApplyReport()
                : ParticleSimulationEventApplyReport.empty
            let particleScalability = needsParticleSnapshot
                ? app.currentParticleScalabilityState()
                : ParticleScalabilityStateResource.default
            let particleRenderSummary = needsParticleSnapshot
                ? app.currentRenderScene().particleSummary
                : ParticleRenderSummary()
            let selectedGPUSimulationPlan = needsParticleSnapshot
                ? app.scene.currentParticleGPUSimulationPlan(for: store.selectedEntityID)
                : nil
            let selectedModuleIssues = needsParticleSnapshot
                ? app.scene.currentParticleModuleValidationIssues(for: store.selectedEntityID)
                : []
            let particleSummary = needsParticleSnapshot
                ? makeDeveloperParticleDiagnosticSummary(stats: particleStats,
                                                         eventReport: particleEventReport,
                                                         scalability: particleScalability,
                                                         renderSummary: particleRenderSummary,
                                                         renderStats: renderStats)
                : nil
            let particleAuthoringSummary = needsParticleSnapshot
                ? makeDeveloperParticleAuthoringDiagnosticSummary(
                    gpuPlan: selectedGPUSimulationPlan,
                    moduleIssues: selectedModuleIssues
                )
                : nil
            let particleHotspots = needsParticleSnapshot
                ? makeDeveloperParticleEmitterHotspots(stats: particleStats,
                                                       eventReport: particleEventReport)
                : []
            let diagnostics = makeDeveloperWorkbenchIssues(
                frameStats: frameStats,
                frameHistory: frameStatsHistory,
                renderStats: renderStats,
                particleSummary: particleSummary,
                particleAuthoringSummary: particleAuthoringSummary,
                particleHotspots: particleHotspots,
                selectedEntityID: store.selectedEntityID,
                consoleEntries: store.consoleEntries
            )
            let performanceMonitors = selectedTab == .monitors
                ? makeDeveloperPerformanceMonitors(
                    frameStats: frameStats,
                    frameHistory: frameStatsHistory,
                    particleHistory: store.particleDiagnosticsHistory,
                    renderStats: renderStats,
                    consoleEntries: store.consoleEntries,
                    maxSamples: 180
                )
                : []
            let trace = selectedTab == .trace
                ? makeDeveloperTrace(frameStats: frameStats,
                                     frameHistory: frameStatsHistory,
                                     particleHistory: store.particleDiagnosticsHistory,
                                     renderStats: renderStats,
                                     issues: diagnostics,
                                     consoleEntries: store.consoleEntries,
                                     maxSamples: 120)
                : DeveloperTraceSnapshot(mode: .live,
                                         samples: [],
                                         events: [],
                                         renderPasses: [],
                                         issues: [])

            TabView(selection: $selectedTab, tabs: [
                TabItem("Profiler", id: DeveloperToolTab.profiler) {
                    DeveloperProfilerWorkbenchView(
                        frameStats: frameStats,
                        history: frameStatsHistory,
                        renderStats: renderStats,
                        particleHistory: store.particleDiagnosticsHistory,
                        issues: diagnostics.filter { $0.target.tab == .frame || $0.target.tab == .render },
                        selectedSampleIndex: $selectedFrameSampleIndex,
                        onOpenTarget: openDiagnosticTarget
                    )
                },
                TabItem("Monitors", id: DeveloperToolTab.monitors) {
                    DeveloperPerformanceMonitorsView(monitors: performanceMonitors,
                                                     selectedMonitorIDs: $selectedPerformanceMonitorIDs,
                                                     selectedSampleIndex: $selectedPerformanceMonitorSampleIndex)
                },
                TabItem("Render", id: DeveloperToolTab.render) {
                    RenderFrameDebuggerView(frameStats: frameStats,
                                            renderStats: renderStats,
                                            issues: diagnostics.filter { $0.target.tab == .render },
                                            onOpenTarget: openDiagnosticTarget)
                },
                TabItem("Particles", id: DeveloperToolTab.particles) {
                    ParticleDiagnosticsTabView(app: app,
                                               store: store)
                },
                TabItem("Debugger", id: DeveloperToolTab.debugger) {
                    DeveloperDebuggerWorkbenchView(store: store,
                                                   timingRevision: timingRevision,
                                                   frameStats: frameStats,
                                                   renderStats: renderStats)
                },
                TabItem("Trace", id: DeveloperToolTab.trace) {
                    DeveloperTraceWorkbenchView(liveTrace: trace,
                                                onOpenTarget: openDiagnosticTarget)
                },
            ])
            .frame(minHeight: 160)
        }
    }

    private func openDiagnosticTarget(_ target: DeveloperDiagnosticTarget) {
        selectedTab = developerToolTabDestination(for: target.tab)
        if let frameSampleIndex = target.frameSampleIndex {
            selectedFrameSampleIndex = frameSampleIndex
        }
    }
}

enum DeveloperToolTab: Hashable {
    case profiler
    case monitors
    case frame
    case render
    case state
    case particles
    case console
    case debugger
    case trace
}

func developerToolTabDestination(for target: DeveloperToolTab) -> DeveloperToolTab {
    switch target {
    case .frame:
        return .profiler
    case .console, .state:
        return .debugger
    default:
        return target
    }
}
