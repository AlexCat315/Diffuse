import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend

enum DeveloperPerformanceMonitorCategory: String, CaseIterable {
    case frame = "Frame"
    case cpu = "CPU"
    case gpu = "GPU"
    case render = "Render"
    case particles = "Particles"
    case console = "Console"
}

enum DeveloperPerformanceMonitorUnit: Equatable {
    case milliseconds
    case fps
    case count
}

enum DeveloperPerformanceMonitorStatus: Int, Equatable, Comparable {
    case nominal = 0
    case warning = 1
    case critical = 2

    static func < (lhs: DeveloperPerformanceMonitorStatus,
                   rhs: DeveloperPerformanceMonitorStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum DeveloperPerformanceMonitorID: String, Hashable, CaseIterable {
    case frameWorkMs
    case frameObservedFPS
    case framePacingGapMs
    case cpuTotalMs
    case cpuInputMs
    case cpuSimulationMs
    case cpuRenderPrepareMs
    case cpuRenderSubmitMs
    case gpuPresentMs
    case renderDrawCalls
    case renderPasses
    case renderBundles
    case renderEncodeMs
    case particlesLive
    case particlesSpawnDrops
    case particlesGPUSimulated
    case particlesRenderInstances
    case consoleErrors
    case consoleWarnings

    static let defaultSelection: Set<DeveloperPerformanceMonitorID> = [
        .frameWorkMs,
        .cpuTotalMs,
        .gpuPresentMs,
        .renderDrawCalls,
        .particlesSpawnDrops,
    ]

    var category: DeveloperPerformanceMonitorCategory {
        switch self {
        case .frameWorkMs, .frameObservedFPS, .framePacingGapMs:
            return .frame
        case .cpuTotalMs, .cpuInputMs, .cpuSimulationMs, .cpuRenderPrepareMs, .cpuRenderSubmitMs:
            return .cpu
        case .gpuPresentMs:
            return .gpu
        case .renderDrawCalls, .renderPasses, .renderBundles, .renderEncodeMs:
            return .render
        case .particlesLive, .particlesSpawnDrops, .particlesGPUSimulated, .particlesRenderInstances:
            return .particles
        case .consoleErrors, .consoleWarnings:
            return .console
        }
    }

    var title: String {
        switch self {
        case .frameWorkMs:
            return "Frame Work"
        case .frameObservedFPS:
            return "Observed FPS"
        case .framePacingGapMs:
            return "Pacing Gap"
        case .cpuTotalMs:
            return "CPU Total"
        case .cpuInputMs:
            return "Input"
        case .cpuSimulationMs:
            return "Simulation"
        case .cpuRenderPrepareMs:
            return "Render Prepare"
        case .cpuRenderSubmitMs:
            return "Render Submit"
        case .gpuPresentMs:
            return "Present"
        case .renderDrawCalls:
            return "Draw Calls"
        case .renderPasses:
            return "Passes"
        case .renderBundles:
            return "Render Bundles"
        case .renderEncodeMs:
            return "Encode"
        case .particlesLive:
            return "Live Particles"
        case .particlesSpawnDrops:
            return "Spawn Drops"
        case .particlesGPUSimulated:
            return "GPU Simulated"
        case .particlesRenderInstances:
            return "Render Instances"
        case .consoleErrors:
            return "Errors"
        case .consoleWarnings:
            return "Warnings"
        }
    }

    var unit: DeveloperPerformanceMonitorUnit {
        switch self {
        case .frameWorkMs,
             .framePacingGapMs,
             .cpuTotalMs,
             .cpuInputMs,
             .cpuSimulationMs,
             .cpuRenderPrepareMs,
             .cpuRenderSubmitMs,
             .gpuPresentMs,
             .renderEncodeMs:
            return .milliseconds
        case .frameObservedFPS:
            return .fps
        case .renderDrawCalls,
             .renderPasses,
             .renderBundles,
             .particlesLive,
             .particlesSpawnDrops,
             .particlesGPUSimulated,
             .particlesRenderInstances,
             .consoleErrors,
             .consoleWarnings:
            return .count
        }
    }

    var chartMode: ChartRenderMode {
        switch self {
        case .renderDrawCalls,
             .renderPasses,
             .renderBundles,
             .particlesSpawnDrops,
             .consoleErrors,
             .consoleWarnings:
            return .bar
        default:
            return .line
        }
    }

    var budgetLimit: Float? {
        switch self {
        case .frameWorkMs:
            return 16.7
        case .cpuTotalMs:
            return 12.0
        case .gpuPresentMs:
            return 8.0
        case .framePacingGapMs:
            return 16.7
        case .renderEncodeMs:
            return 8.0
        case .particlesSpawnDrops, .consoleErrors, .consoleWarnings:
            return 0
        default:
            return nil
        }
    }
}

struct DeveloperPerformanceMonitorSnapshot: Equatable {
    var id: DeveloperPerformanceMonitorID
    var category: DeveloperPerformanceMonitorCategory
    var title: String
    var values: [Float]
    var sampleIndices: [UInt64]
    var currentValue: Float?
    var currentLabel: String
    var rangeLabel: String
    var sampleLabel: String
    var limit: Float?
    var status: DeveloperPerformanceMonitorStatus
}

func makeDeveloperPerformanceMonitors(
    frameStats: EditorFrameStats,
    frameHistory: [EditorFrameStatsHistorySample],
    particleHistory: [EditorParticleDiagnosticsSample],
    renderStats: RenderFrameStats,
    consoleEntries: [EditorConsoleEntry],
    maxSamples: Int = 180
) -> [DeveloperPerformanceMonitorSnapshot] {
    let frameSamples = developerProfilerFrameSamples(frameStats: frameStats,
                                                     frameHistory: frameHistory,
                                                     maxSamples: maxSamples)
    let particleSamples = Array(particleHistory.suffix(max(1, maxSamples)))

    return DeveloperPerformanceMonitorID.allCases.map { id in
        let series = developerPerformanceMonitorSeries(id: id,
                                                       frameSamples: frameSamples,
                                                       particleSamples: particleSamples,
                                                       renderStats: renderStats,
                                                       consoleEntries: consoleEntries)
        let current = developerPerformanceMonitorCurrentValue(id: id,
                                                              values: series.values)
        return DeveloperPerformanceMonitorSnapshot(
            id: id,
            category: id.category,
            title: id.title,
            values: series.values,
            sampleIndices: series.sampleIndices,
            currentValue: current,
            currentLabel: current.map { developerPerformanceMonitorFormat($0, unit: id.unit) } ?? "--",
            rangeLabel: developerPerformanceMonitorRangeLabel(values: series.values,
                                                              unit: id.unit),
            sampleLabel: "\(series.values.count) samples",
            limit: id.budgetLimit,
            status: developerPerformanceMonitorStatus(id: id, currentValue: current)
        )
    }
}

struct DeveloperProfilerWorkbenchView: View {
    let frameStats: EditorFrameStats
    let history: [EditorFrameStatsHistorySample]
    let renderStats: RenderFrameStats
    let particleHistory: [EditorParticleDiagnosticsSample]
    let issues: [DeveloperDiagnosticIssue]
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        let samples = developerProfilerFrameSamples(frameStats: frameStats,
                                                   frameHistory: history,
                                                   maxSamples: 180)
        let selectedSample = developerProfilerSelectedFrame(samples: samples,
                                                            selectedSampleIndex: selectedSampleIndex.wrappedValue)
        let selectedStats = selectedSample?.stats ?? frameStats
        Column(alignment: .leading, spacing: 0) {
            DeveloperProfilerToolbar(sampleCount: samples.count,
                                     selectedSample: selectedSample,
                                     frameStats: selectedStats)
                .padding(horizontal: 12, vertical: 8)
            Divider()

            Row(alignment: .top, spacing: 0) {
                DeveloperProfilerFrameList(samples: samples,
                                           selectedSampleIndex: selectedSampleIndex)
                    .frame(width: 300)

                Divider(axis: .vertical)
                    .frame(width: 1)

                ScrollView(.vertical) {
                    Column(alignment: .leading, spacing: 10) {
                        DeveloperProfilerFrameGraph(samples: samples,
                                                    selectedSample: selectedSample)
                        DeveloperProfilerPhaseBreakdown(stats: selectedStats,
                                                        renderStats: renderStats,
                                                        particleSample: developerProfilerParticleSample(
                                                            particleHistory: particleHistory,
                                                            sampleIndex: selectedSample?.sampleIndex
                                                        ))
                        DeveloperProfilerIssuePane(issues: issues)
                    }
                    .padding(horizontal: 12, vertical: 10)
                }
                .flex(1, shrink: 1)
            }
            .flex(1, shrink: 1)
        }
        .background(.surface)
    }
}

struct DeveloperPerformanceMonitorsView: View {
    let monitors: [DeveloperPerformanceMonitorSnapshot]
    let selectedMonitorIDs: Binding<Set<DeveloperPerformanceMonitorID>>
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        let selected = monitors.filter { selectedMonitorIDs.wrappedValue.contains($0.id) }
        Column(alignment: .leading, spacing: 0) {
            DeveloperPerformanceMonitorToolbar(monitors: monitors,
                                               selectedMonitorIDs: selectedMonitorIDs,
                                               selectedCount: selected.count)
                .padding(horizontal: 12, vertical: 8)
            Divider()

            Row(alignment: .top, spacing: 0) {
                DeveloperPerformanceMonitorTree(monitors: monitors,
                                                selectedMonitorIDs: selectedMonitorIDs,
                                                selectedSampleIndex: selectedSampleIndex)
                    .frame(width: 340)

                Divider(axis: .vertical)
                    .frame(width: 1)

                DeveloperPerformanceMonitorGraphPane(monitors: selected,
                                                     selectedSampleIndex: selectedSampleIndex)
                    .flex(1, shrink: 1)
            }
            .flex(1, shrink: 1)
        }
        .background(.surface)
    }
}

private struct DeveloperProfilerToolbar: View {
    let sampleCount: Int
    let selectedSample: EditorFrameStatsHistorySample?
    let frameStats: EditorFrameStats

    var body: some View {
        Row(alignment: .center, spacing: 12) {
            Column(alignment: .leading, spacing: 2) {
                Text("Profiler")
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text("Frame history, phase cost, and promoted bottlenecks")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .flex(1, shrink: 1)

            DeveloperProfilerMetric(label: "Frames",
                                    value: "\(sampleCount)",
                                    status: .nominal)
            DeveloperProfilerMetric(label: "Selected",
                                    value: selectedSample.map { "#\($0.sampleIndex)" } ?? "Latest",
                                    status: .nominal)
            DeveloperProfilerMetric(label: "Work",
                                    value: developerProfilerFormatMs(frameStats.workMs),
                                    status: developerProfilerFrameStatus(frameStats.workMs))
            DeveloperProfilerMetric(label: "CPU",
                                    value: developerProfilerFormatMs(frameStats.cpuWorkSeconds * 1000),
                                    status: developerProfilerCPUStatus(frameStats.cpuWorkSeconds * 1000))
            DeveloperProfilerMetric(label: "GPU",
                                    value: developerProfilerFormatMs(frameStats.gpuPresentSeconds * 1000),
                                    status: developerProfilerGPUStatus(frameStats.gpuPresentSeconds * 1000))
        }
    }
}

private struct DeveloperProfilerMetric: View {
    let label: String
    let value: String
    let status: DeveloperPerformanceMonitorStatus

    var body: some View {
        Column(alignment: .leading, spacing: 1) {
            Text(label)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Text(value)
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(developerPerformanceStatusColor(status))
        }
        .padding(horizontal: 8, vertical: 5)
        .background(.surfaceSunken)
        .border(status == .nominal ? .divider : developerPerformanceStatusColor(status), width: 1)
    }
}

private struct DeveloperProfilerFrameList: View {
    let samples: [EditorFrameStatsHistorySample]
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        Column(alignment: .leading, spacing: 0) {
            Row(alignment: .center, spacing: 8) {
                Text("Frames")
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text("\(samples.count)")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Spacer(minLength: 0)
            }
            .padding(horizontal: 10, vertical: 7)
            .background(.surfaceFloating)

            Divider()

            ScrollView(.vertical) {
                Column(alignment: .leading, spacing: 0) {
                    for sample in samples.reversed() {
                        DeveloperProfilerFrameRow(sample: sample,
                                                  isSelected: selectedSampleIndex.wrappedValue == sample.sampleIndex,
                                                  onSelect: {
                                                      selectedSampleIndex.wrappedValue = sample.sampleIndex
                                                  })
                    }
                }
            }
            .background(.surfaceSunken)
        }
    }
}

private struct DeveloperProfilerFrameRow: View {
    let sample: EditorFrameStatsHistorySample
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Row(alignment: .center, spacing: 8) {
                Text("#\(sample.sampleIndex)")
                    .lineLimit(1)
                    .font(.mono)
                    .foregroundColor(isSelected ? .accent : .onSurface)
                    .frame(width: 56)
                Text(developerProfilerFrameGlyph(sample.stats.workMs))
                    .lineLimit(1)
                    .font(.mono)
                    .foregroundColor(developerPerformanceStatusColor(developerProfilerFrameStatus(sample.stats.workMs)))
                    .frame(width: 18)
                Text(developerProfilerFormatMs(sample.stats.workMs))
                    .lineLimit(1)
                    .font(.mono)
                    .foregroundColor(.onSurface)
                    .frame(width: 74)
                Text(developerProfilerBottleneckLabel(sample.stats))
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .flex(1, shrink: 1)
            }
            .padding(horizontal: 9, vertical: 5)
            .background(isSelected ? .accent.opacity(0.12) : .surfaceSunken)
            .border(isSelected ? .accent : .divider, width: isSelected ? 1 : 0)
        }
        .buttonStyle(.plain)
    }
}

private struct DeveloperProfilerFrameGraph: View {
    let samples: [EditorFrameStatsHistorySample]
    let selectedSample: EditorFrameStatsHistorySample?

    var body: some View {
        let values = samples.map { Float($0.stats.workMs) }
        Column(alignment: .leading, spacing: 6) {
            Row(alignment: .center, spacing: 8) {
                Text("Frame Time")
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text(developerPerformanceMonitorRangeLabel(values: values, unit: .milliseconds))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Spacer(minLength: 0)
            }
            MonitorChart(values: values,
                         color: .accent,
                         mode: .line,
                         threshold: ChartThreshold(value: 16.7, color: .warning),
                         marker: developerProfilerMarker(samples: samples,
                                                         selectedSample: selectedSample),
                         style: ChartStyle(minValue: 0,
                                           gridLineCount: 5,
                                           lineWidth: 1.5,
                                           barSpacing: 1,
                                           contentInset: 6,
                                           background: .surfaceSunken,
                                           gridColor: .divider))
                .frame(height: 148)
        }
        .padding(horizontal: 10, vertical: 8)
        .background(.surface)
        .border(.divider, width: 1)
    }
}

private struct DeveloperProfilerPhaseBreakdown: View {
    let stats: EditorFrameStats
    let renderStats: RenderFrameStats
    let particleSample: EditorParticleDiagnosticsSample?

    var body: some View {
        Row(alignment: .top, spacing: 10) {
            DeveloperProfilerSection(title: "CPU Phases") {
                DeveloperProfilerPhaseRow(label: "Input",
                                          valueMs: stats.inputSeconds * 1000,
                                          totalMs: max(stats.cpuWorkSeconds * 1000, 0.001))
                DeveloperProfilerPhaseRow(label: "Simulation",
                                          valueMs: stats.simulationSeconds * 1000,
                                          totalMs: max(stats.cpuWorkSeconds * 1000, 0.001))
                DeveloperProfilerPhaseRow(label: "Render Prepare",
                                          valueMs: stats.renderPrepareSeconds * 1000,
                                          totalMs: max(stats.cpuWorkSeconds * 1000, 0.001))
                DeveloperProfilerPhaseRow(label: "Render Submit",
                                          valueMs: stats.renderSubmitSeconds * 1000,
                                          totalMs: max(stats.cpuWorkSeconds * 1000, 0.001))
            }
            .flex(1, shrink: 1)

            DeveloperProfilerSection(title: "Render") {
                DeveloperProfilerValueRow(label: "Draw Calls", value: "\(stats.drawCallCount)")
                DeveloperProfilerValueRow(label: "Passes", value: "\(stats.passCount)")
                DeveloperProfilerValueRow(label: "Bundles", value: "\(stats.renderBundleCount)")
                DeveloperProfilerValueRow(label: "Encode", value: developerProfilerFormatNs(renderStats.cpuEncodeNS))
                DeveloperProfilerValueRow(label: "Present", value: developerProfilerFormatMs(stats.gpuPresentSeconds * 1000))
            }
            .flex(1, shrink: 1)

            DeveloperProfilerSection(title: "Particles") {
                if let particleSample {
                    DeveloperProfilerValueRow(label: "Live",
                                              value: "\(particleSample.liveParticleCount)/\(particleSample.liveParticleLimit)")
                    DeveloperProfilerValueRow(label: "Requested",
                                              value: "\(particleSample.requestedSpawnCount)")
                    DeveloperProfilerValueRow(label: "Spawned",
                                              value: "\(particleSample.spawnedParticleCount)")
                    DeveloperProfilerValueRow(label: "Dropped",
                                              value: "\(developerProfilerParticleDropCount(particleSample))")
                    DeveloperProfilerValueRow(label: "GPU Sim",
                                              value: "\(particleSample.gpuSimulationParticleCount)")
                } else {
                    DeveloperProfilerValueRow(label: "Live", value: "--")
                    DeveloperProfilerValueRow(label: "Dropped", value: "--")
                    DeveloperProfilerValueRow(label: "GPU Sim", value: "--")
                }
            }
            .flex(1, shrink: 1)
        }
    }
}

private struct DeveloperProfilerSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
            content
        }
        .padding(horizontal: 10, vertical: 8)
        .background(.surface)
        .border(.divider, width: 1)
    }
}

private struct DeveloperProfilerPhaseRow: View {
    let label: String
    let valueMs: Double
    let totalMs: Double

    var body: some View {
        let fraction = Float(min(max(valueMs / totalMs, 0), 1))
        Row(alignment: .center, spacing: 8) {
            Text(label)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: 92)
            Row(alignment: .center, spacing: 0) {
                Box { EmptyView() }
                    .frame(width: 96 * fraction, height: 6)
                    .background(.accent)
                Box { EmptyView() }
                    .frame(width: 96 * (1 - fraction), height: 6)
                    .background(.surfaceSunken)
            }
            .cornerRadius(2)
            Text(developerProfilerFormatMs(valueMs))
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(.onSurface)
                .frame(width: 70)
        }
    }
}

private struct DeveloperProfilerValueRow: View {
    let label: String
    let value: String

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Text(label)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1)
            Text(value)
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(.onSurface)
        }
    }
}

private struct DeveloperProfilerIssuePane: View {
    let issues: [DeveloperDiagnosticIssue]

    var body: some View {
        let visibleIssues = Array(issues.prefix(6))
        DeveloperProfilerSection(title: "Promoted Issues") {
            if issues.isEmpty {
                Text("No promoted profiler issues.")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            } else {
                Column(alignment: .leading, spacing: 4) {
                    for issue in visibleIssues {
                        DeveloperProfilerIssueRow(issue: issue)
                    }
                }
            }
        }
    }
}

private struct DeveloperProfilerIssueRow: View {
    let issue: DeveloperDiagnosticIssue

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Text(developerIssueGlyph(issue.severity))
                .font(.mono)
                .foregroundColor(developerIssueColor(issue.severity))
                .frame(width: 18)
            Text(issue.scope.rawValue)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: 70)
            Text(issue.title)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurface)
                .flex(1, shrink: 1)
            Text(issue.primarySignal)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: 180)
        }
        .padding(horizontal: 8, vertical: 4)
        .background(.surfaceSunken)
    }
}

private struct DeveloperPerformanceMonitorToolbar: View {
    let monitors: [DeveloperPerformanceMonitorSnapshot]
    let selectedMonitorIDs: Binding<Set<DeveloperPerformanceMonitorID>>
    let selectedCount: Int

    var body: some View {
        Row(alignment: .center, spacing: 10) {
            Column(alignment: .leading, spacing: 2) {
                Text("Performance Monitors")
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text("Select counters from the tree to plot live history.")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .flex(1, shrink: 1)

            DeveloperProfilerMetric(label: "Selected",
                                    value: "\(selectedCount)",
                                    status: .nominal)
            DeveloperProfilerMetric(label: "Warnings",
                                    value: "\(monitors.filter { $0.status == .warning }.count)",
                                    status: monitors.contains { $0.status == .warning } ? .warning : .nominal)
            DeveloperProfilerMetric(label: "Critical",
                                    value: "\(monitors.filter { $0.status == .critical }.count)",
                                    status: monitors.contains { $0.status == .critical } ? .critical : .nominal)

            Button(action: {
                selectedMonitorIDs.wrappedValue = Set(DeveloperPerformanceMonitorID.allCases)
            }) {
                Text("All")
                    .font(.caption)
            }
            .buttonStyle(.ghost)

            Button(action: {
                selectedMonitorIDs.wrappedValue = DeveloperPerformanceMonitorID.defaultSelection
            }) {
                Text("Core")
                    .font(.caption)
            }
            .buttonStyle(.ghost)

            Button(action: {
                selectedMonitorIDs.wrappedValue = []
            }) {
                Text("None")
                    .font(.caption)
            }
            .buttonStyle(.ghost)
        }
    }
}

private struct DeveloperPerformanceMonitorTree: View {
    let monitors: [DeveloperPerformanceMonitorSnapshot]
    let selectedMonitorIDs: Binding<Set<DeveloperPerformanceMonitorID>>
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        Column(alignment: .leading, spacing: 0) {
            Row(alignment: .center, spacing: 8) {
                Text("Monitor")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .flex(1, shrink: 1)
                Text("Value")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .frame(width: 84)
            }
            .padding(horizontal: 10, vertical: 7)
            .background(.surfaceFloating)

            Divider()

            ScrollView(.vertical) {
                Column(alignment: .leading, spacing: 0) {
                    for category in DeveloperPerformanceMonitorCategory.allCases {
                        let categoryMonitors = monitors.filter { $0.category == category }
                        if !categoryMonitors.isEmpty {
                            DeveloperPerformanceMonitorCategoryHeader(category: category)
                            for monitor in categoryMonitors {
                                DeveloperPerformanceMonitorTreeRow(
                                    monitor: monitor,
                                    isSelected: selectedMonitorIDs.wrappedValue.contains(monitor.id),
                                    selectedMonitorIDs: selectedMonitorIDs,
                                    selectedSampleIndex: selectedSampleIndex
                                )
                            }
                        }
                    }
                }
            }
            .background(.surfaceSunken)
        }
    }
}

private struct DeveloperPerformanceMonitorCategoryHeader: View {
    let category: DeveloperPerformanceMonitorCategory

    var body: some View {
        Text(category.rawValue)
            .lineLimit(1)
            .font(.bodyStrong)
            .foregroundColor(.onSurface)
            .padding(horizontal: 10, vertical: 7)
            .background(.surface)
    }
}

private struct DeveloperPerformanceMonitorTreeRow: View {
    let monitor: DeveloperPerformanceMonitorSnapshot
    let isSelected: Bool
    let selectedMonitorIDs: Binding<Set<DeveloperPerformanceMonitorID>>
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Checkbox(isOn: Binding(
                get: { selectedMonitorIDs.wrappedValue.contains(monitor.id) },
                set: { enabled in
                    var next = selectedMonitorIDs.wrappedValue
                    if enabled {
                        next.insert(monitor.id)
                    } else {
                        next.remove(monitor.id)
                    }
                    selectedMonitorIDs.wrappedValue = next
                    selectedSampleIndex.wrappedValue = monitor.sampleIndices.last
                }
            ))
            Text(monitor.title)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(isSelected ? .onSurface : .onSurfaceMuted)
                .flex(1, shrink: 1)
            Text(monitor.currentLabel)
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(developerPerformanceStatusColor(monitor.status))
                .frame(width: 84)
        }
        .padding(horizontal: 10, vertical: 5)
        .background(isSelected ? .accent.opacity(0.09) : .surfaceSunken)
    }
}

private struct DeveloperPerformanceMonitorGraphPane: View {
    let monitors: [DeveloperPerformanceMonitorSnapshot]
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        ScrollView(.vertical) {
            if monitors.isEmpty {
                Column(alignment: .leading, spacing: 6) {
                    Text("No monitors selected")
                        .font(.bodyStrong)
                        .foregroundColor(.onSurface)
                    Text("Pick one or more items from the monitor tree to display graphs.")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
                .padding(horizontal: 12, vertical: 12)
            } else {
                Column(alignment: .leading, spacing: 10) {
                    DeveloperPerformanceMonitorSummary(monitors: monitors)
                    for monitor in monitors {
                        DeveloperPerformanceMonitorGraphCard(monitor: monitor,
                                                             selectedSampleIndex: selectedSampleIndex)
                    }
                }
                .padding(horizontal: 12, vertical: 10)
            }
        }
        .background(.surfaceSunken)
    }
}

private struct DeveloperPerformanceMonitorSummary: View {
    let monitors: [DeveloperPerformanceMonitorSnapshot]

    var body: some View {
        Row(alignment: .top, spacing: 10) {
            DeveloperProfilerMetric(label: "Graphs",
                                    value: "\(monitors.count)",
                                    status: .nominal)
            if let hot = monitors.sorted(by: developerPerformanceMonitorPrecedes).first {
                DeveloperProfilerMetric(label: "Hot",
                                        value: hot.title,
                                        status: hot.status)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DeveloperPerformanceMonitorGraphCard: View {
    let monitor: DeveloperPerformanceMonitorSnapshot
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        Column(alignment: .leading, spacing: 7) {
            Row(alignment: .center, spacing: 8) {
                Text(monitor.category.rawValue)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .frame(width: 72)
                Text(monitor.title)
                    .lineLimit(1)
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                    .flex(1, shrink: 1)
                Text(monitor.currentLabel)
                    .lineLimit(1)
                    .font(.mono)
                    .foregroundColor(developerPerformanceStatusColor(monitor.status))
                Button(action: {
                    selectedSampleIndex.wrappedValue = monitor.sampleIndices.last
                }) {
                    Text("Latest")
                        .font(.caption)
                }
                .buttonStyle(.ghost)
            }

            MonitorChart(values: monitor.values,
                         color: developerPerformanceStatusColor(monitor.status),
                         mode: monitor.id.chartMode,
                         threshold: monitor.limit.map { ChartThreshold(value: $0, color: .warning) },
                         marker: developerPerformanceMonitorMarker(monitor: monitor,
                                                                   selectedSampleIndex: selectedSampleIndex.wrappedValue),
                         style: ChartStyle(minValue: 0,
                                           gridLineCount: 5,
                                           lineWidth: 1.4,
                                           barSpacing: 1,
                                           contentInset: 6,
                                           background: .surfaceSunken,
                                           gridColor: .divider))
                .frame(height: 112)

            Row(alignment: .center, spacing: 12) {
                DeveloperProfilerValueRow(label: "Range", value: monitor.rangeLabel)
                    .flex(1, shrink: 1)
                DeveloperProfilerValueRow(label: "Samples", value: monitor.sampleLabel)
                    .flex(1, shrink: 1)
                DeveloperProfilerValueRow(label: "Limit",
                                          value: monitor.limit.map {
                                              developerPerformanceMonitorFormat($0, unit: monitor.id.unit)
                                          } ?? "--")
                    .flex(1, shrink: 1)
            }
        }
        .padding(horizontal: 10, vertical: 9)
        .background(.surface)
        .border(monitor.status == .nominal ? .divider : developerPerformanceStatusColor(monitor.status), width: 1)
    }
}

private struct DeveloperMonitorSeries {
    var values: [Float]
    var sampleIndices: [UInt64]
}

private func developerProfilerFrameSamples(frameStats: EditorFrameStats,
                                           frameHistory: [EditorFrameStatsHistorySample],
                                           maxSamples: Int) -> [EditorFrameStatsHistorySample] {
    let clipped = Array(frameHistory.suffix(max(1, maxSamples)))
    if !clipped.isEmpty {
        return clipped
    }
    return [
        EditorFrameStatsHistorySample(sampleIndex: 0,
                                      frameIndex: 0,
                                      stats: frameStats),
    ]
}

private func developerPerformanceMonitorSeries(
    id: DeveloperPerformanceMonitorID,
    frameSamples: [EditorFrameStatsHistorySample],
    particleSamples: [EditorParticleDiagnosticsSample],
    renderStats: RenderFrameStats,
    consoleEntries: [EditorConsoleEntry]
) -> DeveloperMonitorSeries {
    switch id {
    case .frameWorkMs:
        return frameSeries(frameSamples) { Float($0.workMs) }
    case .frameObservedFPS:
        return frameSeries(frameSamples) { Float($0.fps) }
    case .framePacingGapMs:
        return frameSeries(frameSamples) { Float($0.pacingGapMs) }
    case .cpuTotalMs:
        return frameSeries(frameSamples) { Float($0.cpuWorkSeconds * 1000) }
    case .cpuInputMs:
        return frameSeries(frameSamples) { Float($0.inputSeconds * 1000) }
    case .cpuSimulationMs:
        return frameSeries(frameSamples) { Float($0.simulationSeconds * 1000) }
    case .cpuRenderPrepareMs:
        return frameSeries(frameSamples) { Float($0.renderPrepareSeconds * 1000) }
    case .cpuRenderSubmitMs:
        return frameSeries(frameSamples) { Float($0.renderSubmitSeconds * 1000) }
    case .gpuPresentMs:
        return frameSeries(frameSamples) { Float($0.gpuPresentSeconds * 1000) }
    case .renderDrawCalls:
        return frameSeries(frameSamples) { Float($0.drawCallCount) }
    case .renderPasses:
        return frameSeries(frameSamples) { Float($0.passCount) }
    case .renderBundles:
        return frameSeries(frameSamples) { Float($0.renderBundleCount) }
    case .renderEncodeMs:
        let fromFrameStats = frameSeries(frameSamples) { stats in
            Float(stats.cpuSkyboxEncodeNS + stats.cpuBaseEncodeNS + stats.cpuPostProcessEncodeNS) / 1_000_000
        }
        if fromFrameStats.values.contains(where: { $0 > 0 }) {
            return fromFrameStats
        }
        return DeveloperMonitorSeries(values: [Float(renderStats.cpuEncodeNS) / 1_000_000],
                                      sampleIndices: [frameSamples.last?.sampleIndex ?? 0])
    case .particlesLive:
        return particleSeries(particleSamples) { Float($0.liveParticleCount) }
    case .particlesSpawnDrops:
        return particleSeries(particleSamples) { Float(developerProfilerParticleDropCount($0)) }
    case .particlesGPUSimulated:
        return particleSeries(particleSamples) { Float($0.gpuSimulationParticleCount) }
    case .particlesRenderInstances:
        return particleSeries(particleSamples) { Float($0.cpuRenderInstanceCount + $0.gpuRenderInstanceCount) }
    case .consoleErrors:
        return DeveloperMonitorSeries(values: [Float(consoleEntries.filter { $0.severity == .error }.count)],
                                      sampleIndices: [frameSamples.last?.sampleIndex ?? 0])
    case .consoleWarnings:
        return DeveloperMonitorSeries(values: [Float(consoleEntries.filter { $0.severity == .warning }.count)],
                                      sampleIndices: [frameSamples.last?.sampleIndex ?? 0])
    }
}

private func frameSeries(_ samples: [EditorFrameStatsHistorySample],
                         value: (EditorFrameStats) -> Float) -> DeveloperMonitorSeries {
    DeveloperMonitorSeries(values: samples.map { value($0.stats) },
                           sampleIndices: samples.map(\.sampleIndex))
}

private func particleSeries(_ samples: [EditorParticleDiagnosticsSample],
                            value: (EditorParticleDiagnosticsSample) -> Float) -> DeveloperMonitorSeries {
    if samples.isEmpty {
        return DeveloperMonitorSeries(values: [0], sampleIndices: [0])
    }
    return DeveloperMonitorSeries(values: samples.map(value),
                                  sampleIndices: samples.map(\.sampleIndex))
}

private func developerPerformanceMonitorCurrentValue(id: DeveloperPerformanceMonitorID,
                                                     values: [Float]) -> Float? {
    guard !values.isEmpty else { return nil }
    switch id {
    case .renderEncodeMs:
        return values.last
    default:
        return values.last
    }
}

private func developerPerformanceMonitorStatus(id: DeveloperPerformanceMonitorID,
                                               currentValue: Float?) -> DeveloperPerformanceMonitorStatus {
    guard let currentValue else { return .nominal }
    switch id {
    case .frameWorkMs:
        if currentValue > 33.3 { return .critical }
        if currentValue > 16.7 { return .warning }
    case .cpuTotalMs:
        if currentValue > 24 { return .critical }
        if currentValue > 12 { return .warning }
    case .gpuPresentMs:
        if currentValue > 16.7 { return .critical }
        if currentValue > 8 { return .warning }
    case .framePacingGapMs:
        if currentValue > 33.3 { return .critical }
        if currentValue > 16.7 { return .warning }
    case .renderEncodeMs:
        if currentValue > 16.7 { return .critical }
        if currentValue > 8 { return .warning }
    case .particlesSpawnDrops:
        if currentValue > 0 { return .warning }
    case .consoleErrors:
        if currentValue > 0 { return .critical }
    case .consoleWarnings:
        if currentValue > 0 { return .warning }
    default:
        break
    }
    return .nominal
}

private func developerPerformanceMonitorFormat(_ value: Float,
                                               unit: DeveloperPerformanceMonitorUnit) -> String {
    switch unit {
    case .milliseconds:
        return String(format: "%.1f ms", Double(value))
    case .fps:
        return String(format: "%.0f fps", Double(value))
    case .count:
        return String(format: "%.0f", Double(value))
    }
}

private func developerPerformanceMonitorRangeLabel(values: [Float],
                                                   unit: DeveloperPerformanceMonitorUnit) -> String {
    guard let minValue = values.min(), let maxValue = values.max() else {
        return "min -- max --"
    }
    return "min \(developerPerformanceMonitorFormat(minValue, unit: unit)) max \(developerPerformanceMonitorFormat(maxValue, unit: unit))"
}

private func developerPerformanceMonitorMarker(monitor: DeveloperPerformanceMonitorSnapshot,
                                               selectedSampleIndex: UInt64?) -> ChartMarker? {
    guard !monitor.values.isEmpty else { return nil }
    guard let selectedSampleIndex,
          let index = monitor.sampleIndices.firstIndex(of: selectedSampleIndex) else {
        return ChartMarker(index: monitor.values.count - 1, color: .accent, width: 1)
    }
    return ChartMarker(index: min(max(index, 0), monitor.values.count - 1),
                       color: .accent,
                       width: 1)
}

private func developerPerformanceMonitorPrecedes(_ lhs: DeveloperPerformanceMonitorSnapshot,
                                                 _ rhs: DeveloperPerformanceMonitorSnapshot) -> Bool {
    if lhs.status != rhs.status {
        return lhs.status > rhs.status
    }
    return lhs.title < rhs.title
}

private func developerProfilerSelectedFrame(samples: [EditorFrameStatsHistorySample],
                                            selectedSampleIndex: UInt64?) -> EditorFrameStatsHistorySample? {
    guard let selectedSampleIndex else { return samples.last }
    return samples.first { $0.sampleIndex == selectedSampleIndex } ?? samples.last
}

private func developerProfilerParticleSample(particleHistory: [EditorParticleDiagnosticsSample],
                                             sampleIndex: UInt64?) -> EditorParticleDiagnosticsSample? {
    guard let sampleIndex else { return particleHistory.last }
    return particleHistory.last { $0.sampleIndex == sampleIndex } ?? particleHistory.last
}

private func developerProfilerParticleDropCount(_ sample: EditorParticleDiagnosticsSample) -> Int {
    sample.droppedSpawnCount
        + sample.capacityLimitedSpawnCount
        + sample.spawnBudgetLimitedCount
        + sample.eventDroppedSpawnCount
}

private func developerProfilerMarker(samples: [EditorFrameStatsHistorySample],
                                     selectedSample: EditorFrameStatsHistorySample?) -> ChartMarker? {
    guard !samples.isEmpty else { return nil }
    guard let selectedSample,
          let index = samples.firstIndex(where: { $0.sampleIndex == selectedSample.sampleIndex }) else {
        return ChartMarker(index: samples.count - 1, color: .accent, width: 1)
    }
    return ChartMarker(index: index, color: .accent, width: 1)
}

private func developerProfilerFrameStatus(_ workMs: Double) -> DeveloperPerformanceMonitorStatus {
    if workMs > 33.3 { return .critical }
    if workMs > 16.7 { return .warning }
    return .nominal
}

private func developerProfilerCPUStatus(_ cpuMs: Double) -> DeveloperPerformanceMonitorStatus {
    if cpuMs > 24 { return .critical }
    if cpuMs > 12 { return .warning }
    return .nominal
}

private func developerProfilerGPUStatus(_ gpuMs: Double) -> DeveloperPerformanceMonitorStatus {
    if gpuMs > 16.7 { return .critical }
    if gpuMs > 8 { return .warning }
    return .nominal
}

private func developerPerformanceStatusColor(_ status: DeveloperPerformanceMonitorStatus) -> SemanticColorRef {
    switch status {
    case .nominal:
        return .onSurface
    case .warning:
        return .warning
    case .critical:
        return .error
    }
}

private func developerProfilerFrameGlyph(_ workMs: Double) -> String {
    switch developerProfilerFrameStatus(workMs) {
    case .nominal:
        return "-"
    case .warning:
        return "!"
    case .critical:
        return "x"
    }
}

private func developerProfilerBottleneckLabel(_ stats: EditorFrameStats) -> String {
    let cpuMs = stats.cpuWorkSeconds * 1000
    let gpuMs = stats.gpuPresentSeconds * 1000
    if stats.isFramePacingDominated {
        return "Pacing"
    }
    if gpuMs > cpuMs {
        return "GPU / present"
    }
    if stats.renderSubmitSeconds > stats.simulationSeconds && stats.renderSubmitSeconds > stats.renderPrepareSeconds {
        return "Render submit"
    }
    if stats.renderPrepareSeconds > stats.simulationSeconds {
        return "Render prepare"
    }
    if stats.simulationSeconds > 0 {
        return "Simulation"
    }
    return "Idle"
}

private func developerProfilerFormatMs(_ value: Double) -> String {
    String(format: "%.1f ms", value)
}

private func developerProfilerFormatNs(_ value: UInt64) -> String {
    developerProfilerFormatMs(Double(value) / 1_000_000)
}

private func developerIssueGlyph(_ severity: DeveloperDiagnosticSeverity) -> String {
    switch severity {
    case .critical:
        return "x"
    case .warning:
        return "!"
    case .info:
        return "i"
    case .nominal:
        return "-"
    }
}

private func developerIssueColor(_ severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
    case .critical:
        return .error
    case .warning:
        return .warning
    case .info:
        return .accent
    case .nominal:
        return .onSurfaceMuted
    }
}
