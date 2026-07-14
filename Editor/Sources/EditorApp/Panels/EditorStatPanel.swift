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
            let needsParticleSnapshot = selectedTab == .profiler
                || selectedTab == .monitors
                || selectedTab == .particles
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

            TabView(selection: $selectedTab, tabs: [
                TabItem("Profiler", id: DeveloperToolTab.profiler) {
                    DeveloperProfilerWorkbenchView(
                        frameStats: frameStats,
                        history: frameStatsHistory,
                        renderStats: renderStats,
                        particleHistory: store.particleDiagnosticsHistory,
                        issues: diagnostics.filter { $0.target.tab == .frame || $0.target.tab == .render },
                        selectedSampleIndex: $selectedFrameSampleIndex
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
                                            issues: diagnostics.filter { $0.target.tab == .render })
                },
                TabItem("Particles", id: DeveloperToolTab.particles) {
                    ParticleDiagnosticsTabView(app: app,
                                               store: store)
                },
                TabItem("Debugger", id: DeveloperToolTab.debugger) {
                    DeveloperDebuggerWorkbenchView(store: store,
                                                   timingRevision: timingRevision)
                },
            ])
            .frame(minHeight: 160)
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
}

private func developerToolTabDestination(for target: DeveloperToolTab) -> DeveloperToolTab {
    switch target {
    case .frame:
        return .profiler
    case .console, .state:
        return .debugger
    default:
        return target
    }
}

private struct DeveloperDebuggerWorkbenchView: View {
    let store: EditorStore
    let timingRevision: UInt64

    var body: some View {
        Row(alignment: .top, spacing: 0) {
            RuntimeDiagnosticsView(store: store,
                                   timingRevision: timingRevision)
                .flex(1, shrink: 1)

            Divider(axis: .vertical)
                .frame(width: 1)

            ConsoleDiagnosticsView(store: store)
                .flex(1.2, shrink: 1)
        }
        .background(.surface)
    }
}

enum DeveloperDiagnosticSeverity: String, Equatable {
    case nominal = "Nominal"
    case info = "Info"
    case warning = "Warning"
    case critical = "Critical"
}

enum DeveloperDiagnosticScope: String, Equatable {
    case frame = "Frame"
    case render = "Render"
    case particles = "Particles"
    case console = "Console"
    case state = "State"
}

struct DeveloperDiagnosticTarget: Equatable {
    var tab: DeveloperToolTab
    var frameSampleIndex: UInt64?
    var label: String
}

struct DeveloperDiagnosticIssue: Equatable {
    var id: String
    var severity: DeveloperDiagnosticSeverity
    var scope: DeveloperDiagnosticScope
    var title: String
    var primarySignal: String
    var evidence: [String]
    var recommendation: String
    var target: DeveloperDiagnosticTarget
}

struct DeveloperDiagnosticCounts: Equatable {
    var critical: Int
    var warning: Int
    var info: Int
    var nominal: Int
}

enum DeveloperTraceMode: String, Equatable {
    case live = "Live"
    case paused = "Paused"
    case captured = "Captured"
}

enum DeveloperTraceTrack: String, Equatable, Hashable, CaseIterable {
    case frame = "Frame"
    case cpu = "CPU"
    case gpuPresent = "GPU/Present"
    case renderPass = "Render Passes"
    case particles = "Particles"
    case console = "Console"
}

enum DeveloperTraceSeverityFilter: String, Equatable, CaseIterable {
    case all = "All"
    case problems = "Problems"
    case critical = "Errors"
    case warning = "Warnings"
}

enum DeveloperTraceEventSortOrder: String, Equatable, CaseIterable {
    case newest = "Newest"
    case severity = "Severity"
    case track = "Track"
}

enum DeveloperTraceNavigationDirection {
    case previous
    case next
}

struct DeveloperTraceSample: Equatable {
    var sampleIndex: UInt64
    var frameIndex: UInt64
    var frameStats: EditorFrameStats
    var particleLiveCount: Int
    var particleDroppedCount: Int
    var consoleSeverity: DeveloperDiagnosticSeverity?
    var issueIDs: [String]
}

struct DeveloperTraceEvent: Equatable {
    var id: String
    var track: DeveloperTraceTrack
    var sampleIndex: UInt64
    var severity: DeveloperDiagnosticSeverity
    var scope: DeveloperDiagnosticScope
    var title: String
    var primarySignal: String
    var evidence: [String]
    var recommendation: String
    var target: DeveloperDiagnosticTarget
}

struct DeveloperTraceSnapshot: Equatable {
    var mode: DeveloperTraceMode
    var samples: [DeveloperTraceSample]
    var events: [DeveloperTraceEvent]
    var renderPasses: [DeveloperRenderPassInspection]
    var issues: [DeveloperDiagnosticIssue]

    func withMode(_ nextMode: DeveloperTraceMode) -> DeveloperTraceSnapshot {
        var copy = self
        copy.mode = nextMode
        return copy
    }
}

struct DeveloperTraceInvestigationSummary: Equatable {
    var visibleEventCount: Int
    var criticalCount: Int
    var warningCount: Int
    var hotSampleIndex: UInt64?
    var hotSampleEventCount: Int
    var focusEventID: String?
}

struct DeveloperTraceSampleInvestigation: Equatable {
    var sampleIndex: UInt64
    var leadEventID: String?
    var eventCount: Int
    var criticalCount: Int
    var warningCount: Int
    var tracks: [DeveloperTraceTrack]
    var drilldownTargets: [DeveloperDiagnosticTarget]
}

enum DeveloperTraceSampleContextPosition: String, Equatable {
    case previous = "Previous"
    case selected = "Selected"
    case next = "Next"
}

struct DeveloperTraceSampleContextRow: Equatable {
    var position: DeveloperTraceSampleContextPosition
    var sampleIndex: UInt64
    var workMs: Double
    var workDeltaFromSelectedMs: Double
    var eventCount: Int
    var highestSeverity: DeveloperDiagnosticSeverity
}

struct DeveloperTraceSampleContext: Equatable {
    var previous: DeveloperTraceSampleContextRow?
    var selected: DeveloperTraceSampleContextRow
    var next: DeveloperTraceSampleContextRow?
}

private struct DeveloperTraceEventCellKey: Hashable {
    var track: DeveloperTraceTrack
    var sampleIndex: UInt64
}

struct DeveloperTraceEventIndex {
    private var eventsByCell: [DeveloperTraceEventCellKey: [DeveloperTraceEvent]]
    private var eventsBySample: [UInt64: [DeveloperTraceEvent]]

    init(trace: DeveloperTraceSnapshot) {
        var eventsByCell: [DeveloperTraceEventCellKey: [DeveloperTraceEvent]] = [:]
        var eventsBySample: [UInt64: [DeveloperTraceEvent]] = [:]
        for event in trace.events {
            eventsByCell[DeveloperTraceEventCellKey(track: event.track,
                                                    sampleIndex: event.sampleIndex),
                         default: []].append(event)
            eventsBySample[event.sampleIndex, default: []].append(event)
        }
        self.eventsByCell = eventsByCell
        self.eventsBySample = eventsBySample
    }

    func events(track: DeveloperTraceTrack, sampleIndex: UInt64) -> [DeveloperTraceEvent] {
        eventsByCell[DeveloperTraceEventCellKey(track: track, sampleIndex: sampleIndex)] ?? []
    }

    func events(sampleIndex: UInt64, excluding excludedEventID: String? = nil) -> [DeveloperTraceEvent] {
        let events = eventsBySample[sampleIndex] ?? []
        guard let excludedEventID else { return events }
        return events.filter { $0.id != excludedEventID }
    }
}

struct DeveloperMonitorSnapshot: Equatable {
    var track: DeveloperTraceTrack
    var title: String
    var currentValue: Float?
    var currentLabel: String
    var rangeLabel: String
    var sampleLabel: String
    var limit: Float?
    var isOverLimit: Bool
    var values: [Float]
}

func makeDeveloperDiagnosticCounts(_ issues: [DeveloperDiagnosticIssue]) -> DeveloperDiagnosticCounts {
    DeveloperDiagnosticCounts(
        critical: issues.filter { $0.severity == .critical }.count,
        warning: issues.filter { $0.severity == .warning }.count,
        info: issues.filter { $0.severity == .info }.count,
        nominal: issues.filter { $0.severity == .nominal }.count
    )
}

func makeDeveloperWorkbenchIssues(
    frameStats: EditorFrameStats,
    frameHistory: [EditorFrameStatsHistorySample],
    renderStats: RenderFrameStats,
    particleSummary: DeveloperParticleDiagnosticSummary?,
    particleAuthoringSummary: DeveloperParticleDiagnosticSummary?,
    particleHotspots: [DeveloperParticleEmitterHotspot],
    selectedEntityID: UInt64?,
    consoleEntries: [EditorConsoleEntry]
) -> [DeveloperDiagnosticIssue] {
    var issues: [DeveloperDiagnosticIssue] = []
    let latestSampleIndex = frameHistory.last?.sampleIndex

    if frameStats.isFramePacingDominated {
        issues.append(DeveloperDiagnosticIssue(
            id: "frame.pacing",
            severity: .warning,
            scope: .frame,
            title: "Frame pacing gap",
            primarySignal: "\(formatMs(frameStats.pacingGapMs)) waiting/idle in latest tick",
            evidence: [
                "Observed FPS \(formatFPS(frameStats.fps))",
                "Work FPS \(formatFPS(frameStats.workFPS))",
                "Work \(formatMs(frameStats.workMs))",
            ],
            recommendation: "Treat this as event-loop or viewport pacing first; rendering work is not the primary explanation until work time rises.",
            target: DeveloperDiagnosticTarget(tab: .frame,
                                              frameSampleIndex: latestSampleIndex,
                                              label: "Open Frame")
        ))
    } else if frameStats.workMs > 33.3 {
        issues.append(DeveloperDiagnosticIssue(
            id: "frame.work.30fps",
            severity: .critical,
            scope: .frame,
            title: "Frame work exceeds 30 FPS budget",
            primarySignal: "Work \(formatMs(frameStats.workMs))",
            evidence: [
                "CPU \(formatMs(cpuMs(frameStats)))",
                "GPU / present \(formatMs(frameStats.gpuPresentSeconds * 1000))",
                "Likely \(bottleneck(frameStats))",
            ],
            recommendation: "Inspect the selected frame breakdown before changing quality settings; the bottleneck label only points to the first layer.",
            target: DeveloperDiagnosticTarget(tab: .frame,
                                              frameSampleIndex: latestSampleIndex,
                                              label: "Open Frame")
        ))
    } else if frameStats.workMs > 16.7 {
        issues.append(DeveloperDiagnosticIssue(
            id: "frame.work.60fps",
            severity: .warning,
            scope: .frame,
            title: "Frame work exceeds 60 FPS budget",
            primarySignal: "Work \(formatMs(frameStats.workMs))",
            evidence: [
                "Headroom @60 \(formatSignedMs(16.7 - frameStats.workMs))",
                "Likely \(bottleneck(frameStats))",
            ],
            recommendation: "Use the frame timeline to find whether this is a one-frame spike or sustained frame pressure.",
            target: DeveloperDiagnosticTarget(tab: .frame,
                                              frameSampleIndex: latestSampleIndex,
                                              label: "Open Frame")
        ))
    }

    if let trend = makeDeveloperFrameTrendSummary(history: frameHistory),
       trend.sampleCount >= 8,
       trend.p95WorkMs > 16.7 {
        issues.append(DeveloperDiagnosticIssue(
            id: "frame.trend.p95",
            severity: trend.p95WorkMs > 33.3 ? .critical : .warning,
            scope: .frame,
            title: "Sustained frame-time pressure",
            primarySignal: "P95 work \(formatMs(trend.p95WorkMs)) over \(trend.sampleCount) samples",
            evidence: [
                "Average work \(formatMs(trend.averageWorkMs))",
                "Peak sample #\(trend.peakWorkSampleIndex)",
                "Pacing-dominated \(trend.pacingDominatedSamples)/\(trend.sampleCount)",
            ],
            recommendation: "Open the peak sample and compare it with the latest frame before tuning render or simulation settings.",
            target: DeveloperDiagnosticTarget(tab: .frame,
                                              frameSampleIndex: trend.peakWorkSampleIndex,
                                              label: "Open Peak Frame")
        ))
    }

    if renderStats.cpuEncodeNS > 16_700_000 {
        issues.append(DeveloperDiagnosticIssue(
            id: "render.encode",
            severity: renderStats.cpuEncodeNS > 33_300_000 ? .critical : .warning,
            scope: .render,
            title: "Render encode exceeds frame budget",
            primarySignal: "Encode \(formatNs(renderStats.cpuEncodeNS))",
            evidence: [
                "Draw calls \(renderStats.drawCallCount)",
                "Passes \(renderStats.passCount)",
                "Bundles \(renderStats.renderBundleCount)",
            ],
            recommendation: "Open the render debugger and inspect pass encode time before reducing scene content broadly.",
            target: DeveloperDiagnosticTarget(tab: .render,
                                              frameSampleIndex: nil,
                                              label: "Open Render")
        ))
    }

    let passBreakdown = makeDeveloperRenderPassBreakdown(renderStats: renderStats)
    if let slowPass = passBreakdown.first(where: { $0.encodeNS > 8_000_000 }) {
        issues.append(DeveloperDiagnosticIssue(
            id: "render.pass.\(slowPass.name)",
            severity: slowPass.encodeNS > 16_700_000 ? .critical : .warning,
            scope: .render,
            title: "\(slowPass.name) pass is expensive",
            primarySignal: "Encode \(formatNs(slowPass.encodeNS))",
            evidence: [
                "Draw calls \(slowPass.drawCallCount)",
                slowPass.signal,
            ],
            recommendation: slowPass.recommendation,
            target: DeveloperDiagnosticTarget(tab: .render,
                                              frameSampleIndex: nil,
                                              label: "Open Render")
        ))
    }

    if let particleSummary,
       particleSummary.severity != .nominal,
       particleSummary.severity != .idle {
        issues.append(DeveloperDiagnosticIssue(
            id: "particles.health.\(particleSummary.status)",
            severity: developerDiagnosticSeverity(from: particleSummary.severity),
            scope: .particles,
            title: particleSummary.status,
            primarySignal: particleSummary.primarySignal,
            evidence: particleSummary.details,
            recommendation: particleSummary.recommendation,
            target: DeveloperDiagnosticTarget(tab: .particles,
                                              frameSampleIndex: nil,
                                              label: "Open Particles")
        ))
    }

    if let particleAuthoringSummary,
       selectedEntityID != nil,
       particleAuthoringSummary.severity != .nominal,
       particleAuthoringSummary.severity != .idle {
        issues.append(DeveloperDiagnosticIssue(
            id: "particles.authoring.\(particleAuthoringSummary.status)",
            severity: developerDiagnosticSeverity(from: particleAuthoringSummary.severity),
            scope: .particles,
            title: particleAuthoringSummary.status,
            primarySignal: particleAuthoringSummary.primarySignal,
            evidence: particleAuthoringSummary.details,
            recommendation: particleAuthoringSummary.recommendation,
            target: DeveloperDiagnosticTarget(tab: .particles,
                                              frameSampleIndex: nil,
                                              label: "Open Particles")
        ))
    }

    if let hotspot = particleHotspots.first,
       hotspot.severity == .critical || hotspot.severity == .warning {
        issues.append(DeveloperDiagnosticIssue(
            id: "particles.hotspot.\(hotspot.entityID)",
            severity: developerDiagnosticSeverity(from: hotspot.severity),
            scope: .particles,
            title: "Emitter hotspot #\(hotspot.entityID)",
            primarySignal: hotspot.primarySignal,
            evidence: hotspot.details,
            recommendation: hotspot.recommendation,
            target: DeveloperDiagnosticTarget(tab: .particles,
                                              frameSampleIndex: nil,
                                              label: "Open Particles")
        ))
    }

    let errorCount = consoleEntries.filter { $0.severity == .error }.count
    let warningCount = consoleEntries.filter { $0.severity == .warning }.count
    if errorCount > 0 {
        issues.append(DeveloperDiagnosticIssue(
            id: "console.errors",
            severity: .critical,
            scope: .console,
            title: "Console errors",
            primarySignal: "\(errorCount) error\(errorCount == 1 ? "" : "s") recorded",
            evidence: consoleEntries.reversed().filter { $0.severity == .error }.prefix(3).map(\.message),
            recommendation: "Open the console and resolve the newest errors before interpreting downstream runtime symptoms.",
            target: DeveloperDiagnosticTarget(tab: .console,
                                              frameSampleIndex: nil,
                                              label: "Open Console")
        ))
    } else if warningCount > 0 {
        issues.append(DeveloperDiagnosticIssue(
            id: "console.warnings",
            severity: .warning,
            scope: .console,
            title: "Console warnings",
            primarySignal: "\(warningCount) warning\(warningCount == 1 ? "" : "s") recorded",
            evidence: consoleEntries.reversed().filter { $0.severity == .warning }.prefix(3).map(\.message),
            recommendation: "Review the newest warnings and correlate them with the active scene or selected entity.",
            target: DeveloperDiagnosticTarget(tab: .console,
                                              frameSampleIndex: nil,
                                              label: "Open Console")
        ))
    }

    if issues.isEmpty {
        issues.append(DeveloperDiagnosticIssue(
            id: "workbench.nominal",
            severity: .nominal,
            scope: .state,
            title: "No blocking diagnostics",
            primarySignal: "Latest frame, render, particles, and console signals are nominal",
            evidence: [
                "Work \(formatMs(frameStats.workMs))",
                "Draw calls \(frameStats.drawCallCount)",
                "Console entries \(consoleEntries.count)",
            ],
            recommendation: "Use Profiler and Monitors as the entry points, then drill into Render or Particles for subsystem-specific evidence.",
            target: DeveloperDiagnosticTarget(tab: .frame,
                                              frameSampleIndex: latestSampleIndex,
                                              label: "Open Frame")
        ))
    }

    return issues.sorted(by: developerDiagnosticIssuePrecedes)
}

private func developerDiagnosticSeverity(from severity: DeveloperParticleDiagnosticSeverity) -> DeveloperDiagnosticSeverity {
    switch severity {
    case .critical:
        return .critical
    case .warning:
        return .warning
    case .info:
        return .info
    case .nominal, .idle:
        return .nominal
    }
}

private func developerDiagnosticIssuePrecedes(_ lhs: DeveloperDiagnosticIssue,
                                              _ rhs: DeveloperDiagnosticIssue) -> Bool {
    let lhsRank = developerDiagnosticSeverityRank(lhs.severity)
    let rhsRank = developerDiagnosticSeverityRank(rhs.severity)
    if lhsRank != rhsRank { return lhsRank > rhsRank }
    if lhs.scope.rawValue != rhs.scope.rawValue { return lhs.scope.rawValue < rhs.scope.rawValue }
    return lhs.id < rhs.id
}

private func developerDiagnosticSeverityRank(_ severity: DeveloperDiagnosticSeverity) -> Int {
    switch severity {
    case .critical: 4
    case .warning: 3
    case .info: 2
    case .nominal: 1
    }
}

func makeDeveloperTrace(
    frameStats: EditorFrameStats,
    frameHistory: [EditorFrameStatsHistorySample],
    particleHistory: [EditorParticleDiagnosticsSample],
    renderStats: RenderFrameStats,
    issues: [DeveloperDiagnosticIssue],
    consoleEntries: [EditorConsoleEntry],
    mode: DeveloperTraceMode = .live,
    maxSamples: Int = 120
) -> DeveloperTraceSnapshot {
    let clippedFrameHistory = Array(frameHistory.suffix(max(1, maxSamples)))
    var samples: [DeveloperTraceSample]
    if clippedFrameHistory.isEmpty {
        samples = [
            DeveloperTraceSample(sampleIndex: 0,
                                 frameIndex: 0,
                                 frameStats: frameStats,
                                 particleLiveCount: 0,
                                 particleDroppedCount: 0,
                                 consoleSeverity: nil,
                                 issueIDs: []),
        ]
    } else {
        let particleSamplesByIndex = Dictionary(
            uniqueKeysWithValues: particleHistory.suffix(max(1, maxSamples)).map {
                ($0.sampleIndex, $0)
            }
        )
        samples = clippedFrameHistory.map { sample in
            let particleSample = particleSamplesByIndex[sample.sampleIndex]
            return DeveloperTraceSample(
                sampleIndex: sample.sampleIndex,
                frameIndex: sample.frameIndex,
                frameStats: sample.stats,
                particleLiveCount: particleSample?.liveParticleCount ?? 0,
                particleDroppedCount: particleSample.map(developerParticleTraceDropCount) ?? 0,
                consoleSeverity: nil,
                issueIDs: []
            )
        }
    }

    let latestSampleIndex = samples.last?.sampleIndex ?? 0
    if let consoleSeverity = developerTraceConsoleSeverity(consoleEntries) {
        samples[samples.count - 1].consoleSeverity = consoleSeverity
    }

    var events: [DeveloperTraceEvent] = []
    events.append(contentsOf: developerFrameTraceEvents(samples: samples))
    events.append(contentsOf: developerParticleTraceEvents(particleHistory: particleHistory,
                                                           latestSampleIndex: latestSampleIndex,
                                                           maxSamples: maxSamples))
    events.append(contentsOf: developerConsoleTraceEvents(consoleEntries: consoleEntries,
                                                          latestSampleIndex: latestSampleIndex))

    let renderPasses = makeDeveloperRenderPassBreakdown(renderStats: renderStats)
    events.append(contentsOf: developerRenderPassTraceEvents(renderPasses: renderPasses,
                                                             latestSampleIndex: latestSampleIndex))
    events.append(contentsOf: issues.map { issue in
        DeveloperTraceEvent(
            id: "issue.\(issue.id)",
            track: developerTraceTrack(for: issue.scope),
            sampleIndex: issue.target.frameSampleIndex ?? latestSampleIndex,
            severity: issue.severity,
            scope: issue.scope,
            title: issue.title,
            primarySignal: issue.primarySignal,
            evidence: issue.evidence,
            recommendation: issue.recommendation,
            target: issue.target
        )
    })

    let eventIDsBySample = Dictionary(grouping: events, by: \.sampleIndex)
        .mapValues { $0.map(\.id) }
    for index in samples.indices {
        samples[index].issueIDs = eventIDsBySample[samples[index].sampleIndex] ?? []
    }

    return DeveloperTraceSnapshot(
        mode: mode,
        samples: samples,
        events: events.sorted(by: developerTraceEventPrecedes),
        renderPasses: renderPasses,
        issues: issues
    )
}

private func developerFrameTraceEvents(samples: [DeveloperTraceSample]) -> [DeveloperTraceEvent] {
    samples.compactMap { sample in
        let stats = sample.frameStats
        let severity: DeveloperDiagnosticSeverity
        let title: String
        let signal: String
        let recommendation: String
        if stats.workMs > 33.3 {
            severity = .critical
            title = "Frame over 30 FPS budget"
            signal = "Work \(formatMs(stats.workMs))"
            recommendation = "Open the frame breakdown and compare CPU, GPU present, and pacing before tuning content."
        } else if stats.workMs > 16.7 {
            severity = .warning
            title = "Frame over 60 FPS budget"
            signal = "Work \(formatMs(stats.workMs))"
            recommendation = "Check whether this is a spike or sustained pressure across neighboring frames."
        } else if stats.isFramePacingDominated {
            severity = .warning
            title = "Frame pacing gap"
            signal = "\(formatMs(stats.pacingGapMs)) waiting/idle"
            recommendation = "Treat this as event-loop or viewport pacing before assuming render overload."
        } else {
            return nil
        }
        return DeveloperTraceEvent(
            id: "frame.\(sample.sampleIndex)",
            track: .frame,
            sampleIndex: sample.sampleIndex,
            severity: severity,
            scope: .frame,
            title: title,
            primarySignal: signal,
            evidence: [
                "Observed FPS \(formatFPS(stats.fps))",
                "Work FPS \(formatFPS(stats.workFPS))",
                "Pacing Gap \(formatMs(stats.pacingGapMs))",
            ],
            recommendation: recommendation,
            target: DeveloperDiagnosticTarget(tab: .frame,
                                              frameSampleIndex: sample.sampleIndex,
                                              label: "Open Frame")
        )
    }
}

private func developerParticleTraceEvents(particleHistory: [EditorParticleDiagnosticsSample],
                                          latestSampleIndex: UInt64,
                                          maxSamples: Int) -> [DeveloperTraceEvent] {
    particleHistory.suffix(max(1, maxSamples)).compactMap { sample in
        let dropCount = developerParticleTraceDropCount(sample)
        let nearLimit = sample.liveParticleLimit > 0
            && Double(sample.liveParticleCount) / Double(sample.liveParticleLimit) >= 0.9
        guard dropCount > 0 || sample.droppedReadbackEventCount > 0 || nearLimit else {
            return nil
        }
        let severity: DeveloperDiagnosticSeverity = sample.droppedReadbackEventCount > 0
            || sample.capacityLimitedSpawnCount > 0 ? .critical : .warning
        let title: String
        let signal: String
        if sample.droppedReadbackEventCount > 0 {
            title = "Particle readback overflow"
            signal = "\(sample.droppedReadbackEventCount) dropped readback events"
        } else if dropCount > 0 {
            title = "Particle spawn drops"
            signal = "\(dropCount) dropped spawns"
        } else {
            title = "Particle live budget pressure"
            signal = "\(formatPercent(sample.liveParticleCount, sample.liveParticleLimit)) live budget used"
        }
        return DeveloperTraceEvent(
            id: "particles.\(sample.sampleIndex)",
            track: .particles,
            sampleIndex: sample.sampleIndex == 0 ? latestSampleIndex : sample.sampleIndex,
            severity: severity,
            scope: .particles,
            title: title,
            primarySignal: signal,
            evidence: [
                "Live \(sample.liveParticleCount)/\(sample.liveParticleLimit)",
                "Requested \(sample.requestedSpawnCount), spawned \(sample.spawnedParticleCount)",
                "CPU/GPU render \(sample.cpuRenderInstanceCount)/\(sample.gpuRenderInstanceCount)",
            ],
            recommendation: "Open Particles to inspect emitter hotspots, budget drops, GPU fallback, and render skips.",
            target: DeveloperDiagnosticTarget(tab: .particles,
                                              frameSampleIndex: sample.sampleIndex,
                                              label: "Open Particles")
        )
    }
}

private func developerConsoleTraceEvents(consoleEntries: [EditorConsoleEntry],
                                         latestSampleIndex: UInt64) -> [DeveloperTraceEvent] {
    guard let severity = developerTraceConsoleSeverity(consoleEntries),
          severity == .critical || severity == .warning else {
        return []
    }
    let filtered = consoleEntries.reversed().filter {
        severity == .critical ? $0.severity == .error : $0.severity == .warning
    }
    let count = filtered.count
    let title = severity == .critical ? "Console errors" : "Console warnings"
    return [
        DeveloperTraceEvent(
            id: "console.latest.\(severity.rawValue)",
            track: .console,
            sampleIndex: latestSampleIndex,
            severity: severity,
            scope: .console,
            title: title,
            primarySignal: "\(count) \(severity == .critical ? "error" : "warning")\(count == 1 ? "" : "s")",
            evidence: filtered.prefix(3).map(\.message),
            recommendation: "Open Console and resolve the newest messages before interpreting downstream symptoms.",
            target: DeveloperDiagnosticTarget(tab: .console,
                                              frameSampleIndex: nil,
                                              label: "Open Console")
        ),
    ]
}

private func developerRenderPassTraceEvents(renderPasses: [DeveloperRenderPassInspection],
                                            latestSampleIndex: UInt64) -> [DeveloperTraceEvent] {
    renderPasses.filter { $0.encodeNS > 8_000_000 }.map { pass in
        let severity: DeveloperDiagnosticSeverity = pass.encodeNS > 16_700_000 ? .critical : .warning
        return DeveloperTraceEvent(
            id: "renderPass.\(pass.name)",
            track: .renderPass,
            sampleIndex: latestSampleIndex,
            severity: severity,
            scope: .render,
            title: "\(pass.name) pass cost",
            primarySignal: pass.signal,
            evidence: [
                "Encode \(formatNs(pass.encodeNS))",
                "Draw calls \(pass.drawCallCount)",
            ],
            recommendation: pass.recommendation,
            target: DeveloperDiagnosticTarget(tab: .render,
                                              frameSampleIndex: nil,
                                              label: "Open Render")
        )
    }
}

private func developerTraceConsoleSeverity(_ entries: [EditorConsoleEntry]) -> DeveloperDiagnosticSeverity? {
    if entries.contains(where: { $0.severity == .error }) {
        return .critical
    }
    if entries.contains(where: { $0.severity == .warning }) {
        return .warning
    }
    if entries.contains(where: { $0.severity == .info }) {
        return .info
    }
    return nil
}

private func developerTraceTrack(for scope: DeveloperDiagnosticScope) -> DeveloperTraceTrack {
    switch scope {
    case .frame:
        return .frame
    case .render:
        return .renderPass
    case .particles:
        return .particles
    case .console:
        return .console
    case .state:
        return .cpu
    }
}

private func developerTraceEventPrecedes(_ lhs: DeveloperTraceEvent,
                                         _ rhs: DeveloperTraceEvent) -> Bool {
    if lhs.sampleIndex != rhs.sampleIndex { return lhs.sampleIndex < rhs.sampleIndex }
    let lhsRank = developerDiagnosticSeverityRank(lhs.severity)
    let rhsRank = developerDiagnosticSeverityRank(rhs.severity)
    if lhsRank != rhsRank { return lhsRank > rhsRank }
    if lhs.track.rawValue != rhs.track.rawValue { return lhs.track.rawValue < rhs.track.rawValue }
    return lhs.id < rhs.id
}

private func developerParticleTraceDropCount(_ sample: EditorParticleDiagnosticsSample) -> Int {
    sample.droppedSpawnCount
        + sample.capacityLimitedSpawnCount
        + sample.spawnBudgetLimitedCount
        + sample.eventDroppedSpawnCount
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

struct DeveloperRenderPassInspection: Equatable {
    var name: String
    var drawCallCount: Int
    var encodeNS: UInt64
    var signal: String
    var recommendation: String
}

func makeDeveloperRenderPassBreakdown(renderStats: RenderFrameStats) -> [DeveloperRenderPassInspection] {
    var passNames: [RenderPassKind] = []
    for pass in renderStats.activePasses {
        if !passNames.contains(pass) {
            passNames.append(pass)
        }
    }
    for pass in renderStats.passDrawCallCounts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        if !passNames.contains(pass) {
            passNames.append(pass)
        }
    }
    for pass in renderStats.passEncodeNS.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        if !passNames.contains(pass) {
            passNames.append(pass)
        }
    }

    return passNames.map { pass in
        let draws = renderStats.passDrawCallCounts[pass] ?? 0
        let encodeNS = renderStats.passEncodeNS[pass] ?? 0
        return DeveloperRenderPassInspection(
            name: pass.rawValue,
            drawCallCount: draws,
            encodeNS: encodeNS,
            signal: developerRenderPassSignal(pass: pass,
                                              draws: draws,
                                              encodeNS: encodeNS,
                                              renderStats: renderStats),
            recommendation: developerRenderPassRecommendation(pass: pass,
                                                              draws: draws,
                                                              encodeNS: encodeNS,
                                                              renderStats: renderStats)
        )
    }
    .sorted {
        if $0.encodeNS != $1.encodeNS { return $0.encodeNS > $1.encodeNS }
        if $0.drawCallCount != $1.drawCallCount { return $0.drawCallCount > $1.drawCallCount }
        return $0.name < $1.name
    }
}

private func developerRenderPassSignal(pass: RenderPassKind,
                                       draws: Int,
                                       encodeNS: UInt64,
                                       renderStats: RenderFrameStats) -> String {
    if encodeNS > 0 {
        return "\(formatNs(encodeNS)) encode, \(draws) draws"
    }
    if draws > 0 {
        return "\(draws) draws"
    }
    if pass == .particles && renderStats.gpuParticleRenderInstanceCount > 0 {
        return "\(renderStats.gpuParticleRenderInstanceCount) GPU particle instances"
    }
    return "No measured work"
}

private func developerRenderPassRecommendation(pass: RenderPassKind,
                                               draws: Int,
                                               encodeNS: UInt64,
                                               renderStats: RenderFrameStats) -> String {
    if encodeNS > 16_700_000 {
        return "Inspect resources and draw submission in this pass before changing global viewport quality."
    }
    if pass == .particles && renderStats.gpuParticleSortPaddedItemCount > renderStats.gpuParticleSortItemCount {
        return "Check particle sort padding, GPU work split, and render-budget skips in the Particles tool."
    }
    if draws > 1_000 {
        return "Look for batching, instancing, or culling opportunities tied to this pass."
    }
    if draws == 0 {
        return "The pass is active but has no submitted draws; verify whether it is required for this frame."
    }
    return "Pass work is measurable; compare it against adjacent passes before tuning content."
}

private func developerSelectedTraceEvent(trace: DeveloperTraceSnapshot,
                                         selectedEventID: String?) -> DeveloperTraceEvent? {
    guard let selectedEventID else { return nil }
    return trace.events.first { $0.id == selectedEventID }
}

private func developerSelectedTraceSample(trace: DeveloperTraceSnapshot,
                                          selectedSampleIndex: UInt64?,
                                          selectedEvent: DeveloperTraceEvent?) -> DeveloperTraceSample? {
    let sampleIndex = selectedEvent?.sampleIndex ?? selectedSampleIndex
    guard let sampleIndex else { return trace.samples.last }
    return trace.samples.first { $0.sampleIndex == sampleIndex } ?? trace.samples.last
}

func developerTraceSampleEvents(trace: DeveloperTraceSnapshot,
                                sampleIndex: UInt64,
                                excluding excludedEventID: String? = nil) -> [DeveloperTraceEvent] {
    trace.events.filter {
        $0.sampleIndex == sampleIndex && $0.id != excludedEventID
    }
    .sorted {
        let lhsRank = developerDiagnosticSeverityRank($0.severity)
        let rhsRank = developerDiagnosticSeverityRank($1.severity)
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        if $0.track.rawValue != $1.track.rawValue { return $0.track.rawValue < $1.track.rawValue }
        return $0.id < $1.id
    }
}

private func developerTraceCellSeverity(track: DeveloperTraceTrack,
                                        sample: DeveloperTraceSample,
                                        events: [DeveloperTraceEvent]) -> DeveloperDiagnosticSeverity {
    if let event = events.max(by: {
        developerDiagnosticSeverityRank($0.severity) < developerDiagnosticSeverityRank($1.severity)
    }) {
        return event.severity
    }
    switch track {
    case .frame:
        if sample.frameStats.workMs > 33.3 { return .critical }
        if sample.frameStats.workMs > 16.7 || sample.frameStats.isFramePacingDominated { return .warning }
        return .nominal
    case .cpu:
        let cpu = cpuMs(sample.frameStats)
        if cpu > 20 { return .critical }
        if cpu > 10 { return .warning }
        return .nominal
    case .gpuPresent:
        let present = sample.frameStats.gpuPresentSeconds * 1000
        if present > 20 { return .critical }
        if present > 10 { return .warning }
        return .nominal
    case .renderPass:
        return .nominal
    case .particles:
        if sample.particleDroppedCount > 0 { return .warning }
        return .nominal
    case .console:
        return sample.consoleSeverity ?? .nominal
    }
}

private func developerTraceCellGlyph(track: DeveloperTraceTrack,
                                     sample: DeveloperTraceSample,
                                     events: [DeveloperTraceEvent]) -> String {
    if let event = events.max(by: {
        developerDiagnosticSeverityRank($0.severity) < developerDiagnosticSeverityRank($1.severity)
    }) {
        return developerTraceSeverityGlyph(event.severity)
    }
    switch track {
    case .frame:
        let glyph = frameBudgetGlyph(sample.frameStats)
        return glyph == "." ? "" : glyph
    case .cpu:
        return cpuMs(sample.frameStats) > 10 ? "C" : ""
    case .gpuPresent:
        return sample.frameStats.gpuPresentSeconds * 1000 > 10 ? "G" : ""
    case .renderPass:
        return ""
    case .particles:
        return sample.particleDroppedCount > 0 ? "P" : ""
    case .console:
        if let severity = sample.consoleSeverity {
            return developerTraceSeverityGlyph(severity)
        }
        return ""
    }
}

private func developerTraceCellBackground(track: DeveloperTraceTrack,
                                          sample: DeveloperTraceSample,
                                          severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    if severity != .nominal {
        return developerDiagnosticBackground(severity)
    }
    switch track {
    case .frame:
        if sample.frameStats.workMs > 8 { return .surfaceFloating }
        return .surfaceSunken
    case .cpu:
        if cpuMs(sample.frameStats) > 5 { return .surfaceFloating }
        return .surfaceSunken
    case .gpuPresent:
        if sample.frameStats.gpuPresentSeconds * 1000 > 5 { return .surfaceFloating }
        return .surfaceSunken
    case .renderPass, .particles, .console:
        return .surfaceSunken
    }
}

private func developerTraceCellForeground(_ severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    severity == .nominal ? .onSurfaceMuted : developerDiagnosticForeground(severity)
}

private func developerTraceCellBorder(_ severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    severity == .nominal ? .divider : developerDiagnosticBorder(severity)
}

private func developerTraceCellBorderWidth(severity: DeveloperDiagnosticSeverity,
                                           isSelected: Bool) -> Float {
    if isSelected { return 2 }
    return severity == .nominal ? 0 : 1
}

private func developerTraceSeverityGlyph(_ severity: DeveloperDiagnosticSeverity) -> String {
    switch severity {
    case .critical:
        return "!"
    case .warning:
        return "^"
    case .info:
        return "i"
    case .nominal:
        return ""
    }
}

private func developerTraceWindowLabel(_ samples: [DeveloperTraceSample]) -> String {
    guard let first = samples.first,
          let last = samples.last else {
        return "empty"
    }
    return "#\(first.sampleIndex)-#\(last.sampleIndex)"
}

func developerTraceVisibleEvents(trace: DeveloperTraceSnapshot,
                                 query: String,
                                 trackFilter: DeveloperTraceTrack?,
                                 severityFilter: DeveloperTraceSeverityFilter,
                                 sortOrder: DeveloperTraceEventSortOrder = .newest) -> [DeveloperTraceEvent] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let events = trace.events.filter {
        developerTraceEvent($0, matchesTrack: trackFilter)
            && developerTraceEvent($0, matchesSeverity: severityFilter)
            && (trimmed.isEmpty || developerTraceEvent($0, matches: trimmed))
    }
    return events.sorted {
        developerTraceEventPrecedes($0, $1, sortOrder: sortOrder)
    }
}

func developerTraceEventPrecedes(_ lhs: DeveloperTraceEvent,
                                 _ rhs: DeveloperTraceEvent,
                                 sortOrder: DeveloperTraceEventSortOrder) -> Bool {
    switch sortOrder {
    case .newest:
        if lhs.sampleIndex != rhs.sampleIndex { return lhs.sampleIndex > rhs.sampleIndex }
        let lhsRank = developerDiagnosticSeverityRank(lhs.severity)
        let rhsRank = developerDiagnosticSeverityRank(rhs.severity)
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        if lhs.track.rawValue != rhs.track.rawValue { return lhs.track.rawValue < rhs.track.rawValue }
        return lhs.id < rhs.id
    case .severity:
        let lhsRank = developerDiagnosticSeverityRank(lhs.severity)
        let rhsRank = developerDiagnosticSeverityRank(rhs.severity)
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        if lhs.sampleIndex != rhs.sampleIndex { return lhs.sampleIndex > rhs.sampleIndex }
        if lhs.track.rawValue != rhs.track.rawValue { return lhs.track.rawValue < rhs.track.rawValue }
        return lhs.id < rhs.id
    case .track:
        if lhs.track.rawValue != rhs.track.rawValue { return lhs.track.rawValue < rhs.track.rawValue }
        if lhs.sampleIndex != rhs.sampleIndex { return lhs.sampleIndex > rhs.sampleIndex }
        let lhsRank = developerDiagnosticSeverityRank(lhs.severity)
        let rhsRank = developerDiagnosticSeverityRank(rhs.severity)
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        return lhs.id < rhs.id
    }
}

func developerTraceAdjacentEventID(events: [DeveloperTraceEvent],
                                   selectedEventID: String?,
                                   direction: DeveloperTraceNavigationDirection) -> String? {
    guard !events.isEmpty else { return nil }
    guard let selectedEventID,
          let index = events.firstIndex(where: { $0.id == selectedEventID }) else {
        return events.first?.id
    }
    switch direction {
    case .previous:
        return events[max(0, index - 1)].id
    case .next:
        return events[min(events.count - 1, index + 1)].id
    }
}

func makeDeveloperTraceInvestigationSummary(events: [DeveloperTraceEvent]) -> DeveloperTraceInvestigationSummary {
    let criticalCount = events.filter { $0.severity == .critical }.count
    let warningCount = events.filter { $0.severity == .warning }.count
    let grouped = Dictionary(grouping: events, by: \.sampleIndex)
    let hotSample = grouped.max { lhs, rhs in
        if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
        return lhs.key < rhs.key
    }
    let focusEventID = events.first { $0.severity == .critical }?.id
        ?? events.first { $0.severity == .warning }?.id
        ?? events.first?.id
    return DeveloperTraceInvestigationSummary(
        visibleEventCount: events.count,
        criticalCount: criticalCount,
        warningCount: warningCount,
        hotSampleIndex: hotSample?.key,
        hotSampleEventCount: hotSample?.value.count ?? 0,
        focusEventID: focusEventID
    )
}

func makeDeveloperTraceSampleInvestigation(trace: DeveloperTraceSnapshot,
                                           sampleIndex: UInt64) -> DeveloperTraceSampleInvestigation {
    let events = developerTraceSampleEvents(trace: trace,
                                            sampleIndex: sampleIndex)
    let targets = developerTraceUniqueTargets(events)
    return DeveloperTraceSampleInvestigation(
        sampleIndex: sampleIndex,
        leadEventID: events.first?.id,
        eventCount: events.count,
        criticalCount: events.filter { $0.severity == .critical }.count,
        warningCount: events.filter { $0.severity == .warning }.count,
        tracks: developerTraceUniqueTracks(events),
        drilldownTargets: targets
    )
}

func makeDeveloperTraceSampleContext(trace: DeveloperTraceSnapshot,
                                     sampleIndex: UInt64) -> DeveloperTraceSampleContext? {
    guard let selectedIndex = trace.samples.firstIndex(where: { $0.sampleIndex == sampleIndex }) else {
        return nil
    }
    let selectedSample = trace.samples[selectedIndex]
    let selectedWorkMs = selectedSample.frameStats.workMs
    return DeveloperTraceSampleContext(
        previous: selectedIndex > trace.samples.startIndex
            ? developerTraceSampleContextRow(position: .previous,
                                             sample: trace.samples[trace.samples.index(before: selectedIndex)],
                                             selectedWorkMs: selectedWorkMs,
                                             trace: trace)
            : nil,
        selected: developerTraceSampleContextRow(position: .selected,
                                                 sample: selectedSample,
                                                 selectedWorkMs: selectedWorkMs,
                                                 trace: trace),
        next: selectedIndex < trace.samples.index(before: trace.samples.endIndex)
            ? developerTraceSampleContextRow(position: .next,
                                             sample: trace.samples[trace.samples.index(after: selectedIndex)],
                                             selectedWorkMs: selectedWorkMs,
                                             trace: trace)
            : nil
    )
}

private func developerTraceSampleContextRow(position: DeveloperTraceSampleContextPosition,
                                            sample: DeveloperTraceSample,
                                            selectedWorkMs: Double,
                                            trace: DeveloperTraceSnapshot) -> DeveloperTraceSampleContextRow {
    let events = developerTraceSampleEvents(trace: trace,
                                            sampleIndex: sample.sampleIndex)
    return DeveloperTraceSampleContextRow(
        position: position,
        sampleIndex: sample.sampleIndex,
        workMs: sample.frameStats.workMs,
        workDeltaFromSelectedMs: sample.frameStats.workMs - selectedWorkMs,
        eventCount: events.count,
        highestSeverity: developerTraceHighestSeverity(events)
    )
}

private func developerTraceUniqueTracks(_ events: [DeveloperTraceEvent]) -> [DeveloperTraceTrack] {
    var tracks: [DeveloperTraceTrack] = []
    for event in events where !tracks.contains(event.track) {
        tracks.append(event.track)
    }
    return tracks
}

private func developerTraceUniqueTargets(_ events: [DeveloperTraceEvent]) -> [DeveloperDiagnosticTarget] {
    var targets: [DeveloperDiagnosticTarget] = []
    for event in events where !targets.contains(event.target) {
        targets.append(event.target)
    }
    return targets
}

func developerTraceVisibleIssues(trace: DeveloperTraceSnapshot,
                                 query: String,
                                 trackFilter: DeveloperTraceTrack?,
                                 severityFilter: DeveloperTraceSeverityFilter) -> [DeveloperDiagnosticIssue] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return trace.issues.filter { issue in
        developerTraceIssue(issue, matchesTrack: trackFilter)
            && developerTraceIssue(issue, matchesSeverity: severityFilter)
            && (trimmed.isEmpty || developerTraceIssue(issue, matches: trimmed))
    }
}

private func developerTraceVisibleTracks(trackFilter: DeveloperTraceTrack?) -> [DeveloperTraceTrack] {
    if let trackFilter { return [trackFilter] }
    return DeveloperTraceTrack.allCases
}

private func developerTraceEvent(_ event: DeveloperTraceEvent,
                                 matches query: String) -> Bool {
    event.title.localizedCaseInsensitiveContains(query)
        || event.primarySignal.localizedCaseInsensitiveContains(query)
        || event.track.rawValue.localizedCaseInsensitiveContains(query)
        || event.scope.rawValue.localizedCaseInsensitiveContains(query)
        || event.evidence.contains { $0.localizedCaseInsensitiveContains(query) }
        || event.recommendation.localizedCaseInsensitiveContains(query)
}

private func developerTraceEvent(_ event: DeveloperTraceEvent,
                                 matchesTrack trackFilter: DeveloperTraceTrack?) -> Bool {
    guard let trackFilter else { return true }
    return event.track == trackFilter
}

private func developerTraceEvent(_ event: DeveloperTraceEvent,
                                 matchesSeverity filter: DeveloperTraceSeverityFilter) -> Bool {
    switch filter {
    case .all:
        return true
    case .problems:
        return event.severity == .critical || event.severity == .warning
    case .critical:
        return event.severity == .critical
    case .warning:
        return event.severity == .warning
    }
}

private func developerTraceIssue(_ issue: DeveloperDiagnosticIssue,
                                 matches query: String) -> Bool {
    issue.title.localizedCaseInsensitiveContains(query)
        || issue.primarySignal.localizedCaseInsensitiveContains(query)
        || issue.scope.rawValue.localizedCaseInsensitiveContains(query)
        || issue.evidence.contains { $0.localizedCaseInsensitiveContains(query) }
        || issue.recommendation.localizedCaseInsensitiveContains(query)
}

private func developerTraceIssue(_ issue: DeveloperDiagnosticIssue,
                                 matchesTrack trackFilter: DeveloperTraceTrack?) -> Bool {
    guard let trackFilter else { return true }
    return developerTraceTrack(for: issue.scope) == trackFilter
}

private func developerTraceIssue(_ issue: DeveloperDiagnosticIssue,
                                 matchesSeverity filter: DeveloperTraceSeverityFilter) -> Bool {
    switch filter {
    case .all:
        return true
    case .problems:
        return issue.severity == .critical || issue.severity == .warning
    case .critical:
        return issue.severity == .critical
    case .warning:
        return issue.severity == .warning
    }
}

private func developerTraceTrackIcon(_ track: DeveloperTraceTrack) -> String {
    switch track {
    case .frame:
        return "F"
    case .cpu:
        return "C"
    case .gpuPresent:
        return "G"
    case .renderPass:
        return "R"
    case .particles:
        return "P"
    case .console:
        return ">"
    }
}

private func developerTraceHighestSeverity(_ events: [DeveloperTraceEvent]) -> DeveloperDiagnosticSeverity {
    events.max {
        developerDiagnosticSeverityRank($0.severity) < developerDiagnosticSeverityRank($1.severity)
    }?.severity ?? .nominal
}

private func developerTraceRulerLabel(sample: DeveloperTraceSample,
                                      offset: Int,
                                      count: Int) -> String {
    if offset == 0 || offset == count - 1 || offset % 10 == 0 {
        return "\(sample.sampleIndex)"
    }
    return "|"
}

private func developerTraceRulerLabels(_ samples: [DeveloperTraceSample]) -> [String] {
    samples.enumerated().map { offset, sample in
        developerTraceRulerLabel(sample: sample,
                                 offset: offset,
                                 count: samples.count)
    }
}

private func developerTraceRulerText(_ samples: [DeveloperTraceSample]) -> String {
    developerTraceRulerLabels(samples)
        .map { $0.count > 2 ? String($0.suffix(2)) : $0 }
        .map { $0.padding(toLength: 2, withPad: " ", startingAt: 0) }
        .joined(separator: " ")
}

private func developerTraceRulerWidth(_ samples: [DeveloperTraceSample]) -> Float {
    Float(max(samples.count, 1) * 14)
}

private func developerTraceTrackLatestSignal(track: DeveloperTraceTrack,
                                             sample: DeveloperTraceSample?,
                                             trace: DeveloperTraceSnapshot) -> String {
    guard let sample else { return "--" }
    switch track {
    case .frame:
        return formatMs(sample.frameStats.workMs)
    case .cpu:
        return formatMs(cpuMs(sample.frameStats))
    case .gpuPresent:
        return formatMs(sample.frameStats.gpuPresentSeconds * 1000)
    case .renderPass:
        return trace.renderPasses.first.map { "\($0.name) \(formatNs($0.encodeNS))" } ?? "--"
    case .particles:
        if sample.particleDroppedCount > 0 { return "\(sample.particleDroppedCount) drops" }
        if sample.particleLiveCount > 0 { return "\(sample.particleLiveCount) live" }
        return "--"
    case .console:
        return sample.consoleSeverity?.rawValue ?? "--"
    }
}

private func developerTraceMonitorTitle(_ track: DeveloperTraceTrack) -> String {
    switch track {
    case .frame:
        return "FPS / Frame"
    case .cpu:
        return "CPU"
    case .gpuPresent:
        return "GPU / Present"
    case .renderPass:
        return "Render Passes"
    case .particles:
        return "Particles"
    case .console:
        return "Console / Issues"
    }
}

private func developerTraceMonitorSeries(track: DeveloperTraceTrack,
                                         trace: DeveloperTraceSnapshot) -> [Float] {
    switch track {
    case .frame:
        return trace.samples.map { Float($0.frameStats.workMs) }
    case .cpu:
        return trace.samples.map { Float(cpuMs($0.frameStats)) }
    case .gpuPresent:
        return trace.samples.map { Float($0.frameStats.gpuPresentSeconds * 1000) }
    case .renderPass:
        return trace.renderPasses.map { Float(Double($0.encodeNS) / 1_000_000.0) }
    case .particles:
        return trace.samples.map { Float(max($0.particleLiveCount, $0.particleDroppedCount)) }
    case .console:
        return trace.samples.map { sample in
            Float(max(sample.issueIDs.count, sample.consoleSeverity.map(developerDiagnosticSeverityRank) ?? 0))
        }
    }
}

private func developerTraceMonitorLimit(_ track: DeveloperTraceTrack) -> Float? {
    switch track {
    case .frame:
        return 16.7
    case .cpu:
        return 10
    case .gpuPresent:
        return 10
    case .renderPass:
        return 2
    case .particles:
        return nil
    case .console:
        return 1
    }
}

private func developerTraceMonitorColor(_ track: DeveloperTraceTrack) -> SemanticColorRef {
    switch track {
    case .frame:
        return .accent
    case .cpu:
        return .info
    case .gpuPresent:
        return .warning
    case .renderPass:
        return .onSurface
    case .particles:
        return .success
    case .console:
        return .error
    }
}

private func developerTraceMonitorMode(_ track: DeveloperTraceTrack) -> ChartRenderMode {
    switch track {
    case .frame, .cpu, .gpuPresent, .particles:
        return .line
    case .renderPass, .console:
        return .bar
    }
}

private func developerTraceMonitorRangeLabel(_ values: [Float]) -> String {
    guard let minValue = values.min(),
          let maxValue = values.max() else {
        return "min -- max --"
    }
    return "min \(developerTraceMonitorFormat(minValue)) max \(developerTraceMonitorFormat(maxValue))"
}

private func developerTraceMonitorFormat(_ value: Float) -> String {
    if value >= 100 {
        return String(format: "%.0f", Double(value))
    }
    if value >= 10 {
        return String(format: "%.1f", Double(value))
    }
    return String(format: "%.2f", Double(value))
}

private func developerTraceMonitorSampleLabel(track: DeveloperTraceTrack,
                                              trace: DeveloperTraceSnapshot) -> String {
    switch track {
    case .renderPass:
        return "\(trace.renderPasses.count) passes"
    default:
        return "\(trace.samples.count) samples"
    }
}

func makeDeveloperMonitorSnapshots(trace: DeveloperTraceSnapshot) -> [DeveloperMonitorSnapshot] {
    DeveloperTraceTrack.allCases.map { track in
        makeDeveloperMonitorSnapshot(track: track, trace: trace)
    }
}

private func makeDeveloperMonitorSnapshot(track: DeveloperTraceTrack,
                                          trace: DeveloperTraceSnapshot) -> DeveloperMonitorSnapshot {
    let values = developerTraceMonitorSeries(track: track, trace: trace)
    let current = developerMonitorCurrentValue(track: track, values: values)
    let limit = developerTraceMonitorLimit(track)
    return DeveloperMonitorSnapshot(
        track: track,
        title: developerTraceMonitorTitle(track),
        currentValue: current,
        currentLabel: developerTraceTrackLatestSignal(track: track,
                                                      sample: trace.samples.last,
                                                      trace: trace),
        rangeLabel: developerTraceMonitorRangeLabel(values),
        sampleLabel: developerTraceMonitorSampleLabel(track: track, trace: trace),
        limit: limit,
        isOverLimit: limit.map { threshold in current.map { $0 > threshold } ?? false } ?? false,
        values: values
    )
}

private func developerMonitorCurrentValue(track: DeveloperTraceTrack,
                                          values: [Float]) -> Float? {
    switch track {
    case .renderPass:
        return values.max()
    default:
        return values.last
    }
}

private func developerTraceStatusText(summary: DeveloperTraceInvestigationSummary,
                                      trackFilter: DeveloperTraceTrack?,
                                      severityFilter: DeveloperTraceSeverityFilter,
                                      sortOrder: DeveloperTraceEventSortOrder,
                                      selectedSampleIndex: UInt64?) -> String {
    let trackText = trackFilter?.rawValue ?? "all tracks"
    let selectedText = selectedSampleIndex.map { "selected #\($0)" } ?? "no selection"
    let hotText = summary.hotSampleIndex.map { "hot #\($0) x\(summary.hotSampleEventCount)" } ?? "no hot sample"
    return "\(summary.visibleEventCount) events | \(summary.criticalCount) errors | \(summary.warningCount) warnings | \(hotText) | \(trackText) | \(severityFilter.rawValue) | \(sortOrder.rawValue) | \(selectedText)"
}

private func developerTraceEmptyFilterText(query: String,
                                           trackFilter: DeveloperTraceTrack?,
                                           severityFilter: DeveloperTraceSeverityFilter) -> String {
    var parts: [String] = []
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        parts.append("search \"\(trimmed)\"")
    }
    if let trackFilter {
        parts.append("track \(trackFilter.rawValue)")
    }
    if severityFilter != .all {
        parts.append("severity \(severityFilter.rawValue)")
    }
    if parts.isEmpty {
        return "The trace window has no projected events yet."
    }
    return "Active filters: \(parts.joined(separator: ", "))."
}

private func developerTraceBaselineSample(for sample: DeveloperTraceSample,
                                          baselineTrace: DeveloperTraceSnapshot?) -> DeveloperTraceSample? {
    guard let baselineTrace else { return nil }
    return baselineTrace.samples.first { $0.sampleIndex == sample.sampleIndex }
        ?? baselineTrace.samples.last
}

private struct DeveloperIssueQueue: View {
    let issues: [DeveloperDiagnosticIssue]
    let title: String
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
                .padding(horizontal: 10, vertical: 8)

            Column(alignment: .leading, spacing: 6) {
                for issue in issues {
                    DeveloperIssueRow(issue: issue,
                                      onOpenTarget: onOpenTarget)
                }
            }
            .padding(horizontal: 8, vertical: 0)
        }
    }
}

private struct DeveloperIssueRow: View {
    let issue: DeveloperDiagnosticIssue
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

    var body: some View {
        Button(action: { onOpenTarget(issue.target) }) {
            Column(alignment: .leading, spacing: 5) {
                Row(alignment: .center, spacing: 8) {
                    DeveloperSeverityBadge(severity: issue.severity,
                                           text: issue.severity.rawValue)
                    Text(issue.scope.rawValue)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Text(issue.title)
                        .lineLimit(1)
                        .font(.bodyStrong)
                        .foregroundColor(.onSurface)
                        .flex(1, shrink: 1)
                    Text(issue.target.label)
                        .font(.caption)
                        .foregroundColor(.accent)
                }

                Text(issue.primarySignal)
                    .lineLimit(2)
                    .font(.caption)
                    .foregroundColor(.onSurface)

                if !issue.evidence.isEmpty {
                    Text(issue.evidence.prefix(3).joined(separator: " | "))
                        .lineLimit(2)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }

                Text(issue.recommendation)
                    .lineLimit(2)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 10, vertical: 8)
            .background(.surfaceSunken)
            .cornerRadius(6)
            .border(developerDiagnosticBorder(issue.severity), width: 1)
        }
        .buttonStyle(.plain)
    }
}

private struct DeveloperSeverityBadge: View {
    let severity: DeveloperDiagnosticSeverity
    let text: String

    var body: some View {
        Text(text)
            .lineLimit(1)
            .font(.caption)
            .foregroundColor(developerDiagnosticForeground(severity))
            .padding(horizontal: 7, vertical: 2)
            .background(developerDiagnosticBackground(severity))
            .cornerRadius(4)
    }
}

private struct RenderFrameDebuggerView: View {
    let frameStats: EditorFrameStats
    let renderStats: RenderFrameStats
    let issues: [DeveloperDiagnosticIssue]

    var body: some View {
        let passes = makeDeveloperRenderPassBreakdown(renderStats: renderStats)
        ScrollView(.vertical) {
            Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
                Column(alignment: .leading, spacing: 8) {
                    if !issues.isEmpty {
                        DeveloperIssueQueue(issues: issues,
                                            title: "Render Issues",
                                            onOpenTarget: { _ in })
                    }
                    RenderPipelineSummary(frameStats: frameStats,
                                          renderStats: renderStats)
                }
                .flex(1, shrink: 1, basis: 250)

                RenderPassBreakdownView(passes: passes,
                                        renderStats: renderStats)
                    .flex(1.5, shrink: 1, basis: 360)
            }
            .framePercent(width: 100, minWidth: 0)
            .padding(horizontal: 12, vertical: 10)
        }
    }
}

private struct RenderPipelineSummary: View {
    let frameStats: EditorFrameStats
    let renderStats: RenderFrameStats

    var body: some View {
        Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
            StatGroup(title: "Frame Encode") {
                StatRow(label: "Render Frame", value: renderStats.frameIndex >= 0 ? "\(renderStats.frameIndex)" : "--")
                StatRow(label: "Prepare", value: formatNs(renderStats.cpuPrepareNS))
                StatRow(label: "Encode", value: formatNs(renderStats.cpuEncodeNS))
                StatRow(label: "Submit", value: formatNs(renderStats.cpuSubmitNS))
                StatRow(label: "Total", value: formatNs(renderStats.cpuFrameTotalNS))
                StatRow(label: "Present", value: formatMs(frameStats.gpuPresentSeconds * 1000))
            }
            .flex(1, shrink: 1, basis: 150)

            StatGroup(title: "Scene Work") {
                StatRow(label: "Passes", value: "\(renderStats.passCount)")
                StatRow(label: "Draw Calls", value: "\(renderStats.drawCallCount)")
                StatRow(label: "Bundles", value: "\(renderStats.renderBundleCount)")
                StatRow(label: "Bundle Jobs", value: "\(renderStats.renderBundleParallelJobs)")
                StatRow(label: "Settings Gen", value: "\(renderStats.settingsGeneration)")
            }
            .flex(1, shrink: 1, basis: 150)

            StatGroup(title: "Deformable Meshes") {
                StatRow(label: "Meshes", value: "\(renderStats.deformableMeshCount)")
                StatRow(label: "Vertices", value: "\(renderStats.deformableVertexCount)")
                StatRow(label: "Triangles", value: "\(renderStats.deformableTriangleCount)")
                StatRow(label: "Upload", value: formatNs(renderStats.deformableUploadNS))
                StatRow(label: "Uploaded", value: formatByteCount(renderStats.deformableUploadedBytes))
                StatRow(label: "Rejected", value: "\(renderStats.deformableRejectedMeshCount)")
            }
            .flex(1, shrink: 1, basis: 175)
        }
    }
}

private struct RenderPassBreakdownView: View {
    let passes: [DeveloperRenderPassInspection]
    let renderStats: RenderFrameStats

    var body: some View {
        Column(alignment: .leading, spacing: 8) {
            Text("Pass Debugger")
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
                .padding(horizontal: 10, vertical: 8)

            if passes.isEmpty {
                StatWrappedValue(label: "Passes", value: "No render pass stats have been reported for this frame.")
            } else {
                Column(alignment: .leading, spacing: 6) {
                    for pass in passes {
                        RenderPassInspectionRow(pass: pass)
                    }
                }
                .padding(horizontal: 8, vertical: 0)
            }

            Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
                StatGroup(title: "Shadow") {
                    StatRow(label: "Lights", value: "\(renderStats.shadowedLightCount)")
                    StatRow(label: "Tiles", value: "\(renderStats.shadowTileCount)")
                    StatRow(label: "Cascades", value: "\(renderStats.shadowCascadeCount)")
                    StatRow(label: "Map", value: renderStats.shadowMapResolution > 0 ? "\(renderStats.shadowMapResolution)" : "--")
                    StatRow(label: "Atlas", value: renderStats.shadowAtlasResolution > 0 ? "\(renderStats.shadowAtlasResolution)" : "--")
                }
                .flex(1, shrink: 1, basis: 180)

                StatGroup(title: "GPU Particles") {
                    StatRow(label: "Sim Batches", value: "\(renderStats.gpuParticleSimulationBatchCount)")
                    StatRow(label: "Sim Particles", value: "\(renderStats.gpuParticleSimulationParticleCount)")
                    StatRow(label: "Render Instances", value: "\(renderStats.gpuParticleRenderInstanceCount)")
                    StatRow(label: "Indirect Draws", value: "\(renderStats.gpuParticleIndirectDrawCount)")
                    StatRow(label: "Workgroups", value: "\(gpuParticleWorkgroupTotal(renderStats))")
                    StatRow(label: "Sort Padding", value: formatPercent(
                        renderStats.gpuParticleSortPaddedItemCount - renderStats.gpuParticleSortItemCount,
                        renderStats.gpuParticleSortPaddedItemCount
                    ))
                }
                .flex(1, shrink: 1, basis: 220)
            }
        }
    }
}

private struct RenderPassInspectionRow: View {
    let pass: DeveloperRenderPassInspection

    var body: some View {
        Column(alignment: .leading, spacing: 4) {
            Row(alignment: .center, spacing: 8) {
                Text(pass.name)
                    .lineLimit(1)
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                    .flex(1, shrink: 1)
                Text(formatNs(pass.encodeNS))
                    .lineLimit(1)
                    .font(.mono)
                    .foregroundColor(renderPassEncodeColor(pass.encodeNS))
                Text("\(pass.drawCallCount) draws")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            Text(pass.signal)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurface)
            Text(pass.recommendation)
                .lineLimit(2)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 10, vertical: 8)
        .background(.surfaceSunken)
        .cornerRadius(6)
        .border(renderPassEncodeBorder(pass.encodeNS), width: 1)
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
                .flex(1, shrink: 1, basis: 220)
            }
            .framePercent(width: 100, minWidth: 0)
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
            Box(direction: .column, alignItems: .stretch, spacing: 10) {
                ParticleHealthOverview(summary: summary,
                                       stats: stats,
                                       eventReport: eventReport,
                                       renderSummary: renderSummary)

                if let trend {
                    ParticleTrendOverview(trend: trend)
                }

                ParticleEmitterHotspotsView(hotspots: hotspots,
                                            selectedHotspot: selectedHotspot,
                                            selectedEntityID: selectedEntityID,
                                            emitterLabels: emitterLabels,
                                            authoringSummary: authoringSummary)
            }
            .framePercent(width: 100, minWidth: 0)
            .padding(horizontal: 12, vertical: 10)

            Divider()

            Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
                StatGroup(title: "Emitters") {
                    StatRow(label: "Total", value: "\(stats.emitterCount)")
                    StatRow(label: "Active", value: "\(stats.activeEmitterCount)")
                    StatRow(label: "Sim Step", value: formatMs(Double(stats.simulatedDeltaTime) * 1000))
                    StatRow(label: "Live", value: "\(stats.liveParticleCount)")
                    StatRow(label: "Configured Cap", value: "\(stats.maxParticleCount)")
                    StatRow(label: "Effective Cap", value: "\(stats.liveParticleLimit)")
                }
                .flex(1, shrink: 1, basis: 190)

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
                .flex(1, shrink: 1, basis: 220)

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
                .flex(1, shrink: 1, basis: 220)
            }
            .framePercent(width: 100, minWidth: 0)
            .padding(horizontal: 12, vertical: 10)

            Divider()

            Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
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
                .flex(1, shrink: 1, basis: 220)

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
                .flex(1, shrink: 1, basis: 260)

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
                .flex(1, shrink: 1, basis: 240)

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
                .flex(1, shrink: 1, basis: 260)
            }
            .framePercent(width: 100, minWidth: 0)
            .padding(horizontal: 12, vertical: 10)

            Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
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
                .flex(1, shrink: 1, basis: 220)

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
                .flex(1, shrink: 1, basis: 220)

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
        Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
            StatGroup(title: "Particle Health") {
                StatRow(label: "Status", value: summary.status)
                ParticleSeverityRow(severity: summary.severity)
                StatWrappedValue(label: "Signal", value: summary.primarySignal)
                StatWrappedValue(label: "Action", value: summary.recommendation)
            }
            .flex(1.4, shrink: 1, basis: 300)

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
            .flex(1, shrink: 1, basis: 180)

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
            .flex(1, shrink: 1, basis: 220)
        }
    }
}

private struct ParticleTrendOverview: View {
    let trend: DeveloperParticleTrendSummary

    var body: some View {
        Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
            StatGroup(title: "Particle Trend") {
                StatRow(label: "Samples", value: "\(trend.sampleCount)")
                StatRow(label: "Window", value: "#\(trend.firstSampleIndex)-#\(trend.lastSampleIndex)")
                StatRow(label: "Avg Live", value: formatDecimal(trend.averageLiveParticleCount))
                StatRow(label: "Max Live", value: "\(trend.maxLiveParticleCount)")
                StatRow(label: "Peak Live Sample", value: "#\(trend.peakLiveSampleIndex)")
                StatRow(label: "Live Pressure", value: "\(trend.liveBudgetPressureSamples)/\(trend.sampleCount)")
            }
            .flex(1, shrink: 1, basis: 220)

            StatGroup(title: "Spawn Trend") {
                StatRow(label: "Requests", value: "\(trend.totalRequestedSpawnCount)")
                StatRow(label: "Accepted", value: "\(trend.totalSpawnedParticleCount)")
                StatRow(label: "Drops", value: "\(trend.totalDroppedSpawnCount)")
                StatRow(label: "Capacity Drops", value: "\(trend.totalCapacityLimitedSpawnCount)")
                StatRow(label: "Budget Drops", value: "\(trend.totalSpawnBudgetLimitedCount)")
                StatRow(label: "Peak Drop", value: "#\(trend.peakDropSampleIndex) / \(trend.maxDroppedSpawnCount)")
                StatRow(label: "Peak Request", value: "#\(trend.peakSpawnRequestSampleIndex) / \(trend.maxRequestedSpawnCount)")
            }
            .flex(1, shrink: 1, basis: 240)

            StatGroup(title: "GPU / Events") {
                StatRow(label: "Event Drops", value: "\(trend.totalEventDroppedSpawnCount)")
                StatRow(label: "Readback Drops", value: "\(trend.totalDroppedReadbackEventCount)")
                StatRow(label: "Max CPU Render", value: "\(trend.maxCPURenderInstanceCount)")
                StatRow(label: "Max GPU Render", value: "\(trend.maxGPURenderInstanceCount)")
                StatRow(label: "Max GPU Sim", value: "\(trend.maxGPUSimulationParticleCount)")
                StatRow(label: "Max GPU Workgroups", value: "\(trend.maxGPUWorkgroupCount)")
                StatRow(label: "Max Sort Padding", value: formatPercentFraction(trend.maxSortPaddingOverhead))
            }
            .flex(1, shrink: 1, basis: 240)
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
        Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
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
            .flex(1, shrink: 1, basis: 300)

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
            .flex(1.4, shrink: 1, basis: 360)
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
        Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
            Text(isSelected ? "*" : "")
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.accent)
                .frame(width: 8)

            Text(label?.name ?? "#\(hotspot.entityID)")
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(.onSurface)
                .flex(1, shrink: 1, basis: 96)

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
        Row(alignment: .center, spacing: 8) {
            Text("Severity")
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1, basis: 82)

            Text(severity.rawValue)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(particleSeverityForeground(severity))
                .padding(horizontal: 7, vertical: 2)
                .background(particleSeverityBackground(severity))
                .cornerRadius(4)
                .flex(1, shrink: 1, basis: 70)
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

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Text(label)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1, basis: 82)

            Text(value)
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(.onSurface)
                .flex(1, shrink: 1, basis: 70)
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

private func formatByteCount(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 B" }
    if bytes < 1_024 { return "\(bytes) B" }
    let kib = Double(bytes) / 1_024
    if kib < 1_024 { return String(format: "%.1f KiB", kib) }
    return String(format: "%.1f MiB", kib / 1_024)
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

private func selectedFrameSample(history: [EditorFrameStatsHistorySample],
                                 selectedSampleIndex: UInt64?) -> EditorFrameStatsHistorySample? {
    if let selectedSampleIndex,
       let sample = history.first(where: { $0.sampleIndex == selectedSampleIndex }) {
        return sample
    }
    return history.last
}

private func frameBudgetGlyph(_ stats: EditorFrameStats) -> String {
    if stats.isFramePacingDominated { return "P" }
    if stats.workMs > 33.3 { return "!" }
    if stats.workMs > 16.7 { return "*" }
    return "."
}

private func frameBudgetColor(_ stats: EditorFrameStats) -> SemanticColorRef {
    if stats.workMs > 33.3 { return .error }
    if stats.isFramePacingDominated || stats.workMs > 16.7 { return .warning }
    return .success
}

private func developerDiagnosticForeground(_ severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
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

private func developerDiagnosticBackground(_ severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
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

private func developerDiagnosticBorder(_ severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
    case .nominal:
        return .success.opacity(0.25)
    case .info:
        return .info.opacity(0.25)
    case .warning:
        return .warning.opacity(0.35)
    case .critical:
        return .error.opacity(0.40)
    }
}

private func renderPassEncodeColor(_ encodeNS: UInt64) -> SemanticColorRef {
    if encodeNS > 16_700_000 { return .error }
    if encodeNS > 8_000_000 { return .warning }
    if encodeNS > 0 { return .onSurface }
    return .onSurfaceMuted
}

private func renderPassEncodeBorder(_ encodeNS: UInt64) -> SemanticColorRef {
    if encodeNS > 16_700_000 { return .error.opacity(0.40) }
    if encodeNS > 8_000_000 { return .warning.opacity(0.35) }
    return .border
}
