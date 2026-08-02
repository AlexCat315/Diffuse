import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend

private enum DeveloperProfilerConstants {
    static let maxMaterializedFrameRows = 32
    static let maxGraphSamples = 48
}

enum DeveloperPerformanceMonitorCategory: String, CaseIterable {
    case frame = "Frame"
    case cpu = "CPU"
    case gpu = "GPU"
    case render = "Render"
    case particles = "Particles"
    case console = "Console"

    var color: SemanticColorRef {
        switch self {
        case .frame:
            return .accent
        case .cpu:
            return .info
        case .gpu:
            return .accentSecondary
        case .render:
            return .success
        case .particles:
            return .warning
        case .console:
            return .onSurfaceMuted
        }
    }
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
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

    @State private var selectedFrameFilter: DeveloperProfilerFrameFilter = .all

    var body: some View {
        let samples = developerProfilerFrameSamples(frameStats: frameStats,
                                                   frameHistory: history,
                                                   maxSamples: 180)
        let selectedSample = developerProfilerSelectedFrame(samples: samples,
                                                            selectedSampleIndex: selectedSampleIndex.wrappedValue)
        let selectedStats = selectedSample?.stats ?? frameStats
        let selectedParticleSample = developerProfilerParticleSample(particleHistory: particleHistory,
                                                                     sampleIndex: selectedSample?.sampleIndex)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            DeveloperProfilerToolbar(sampleCount: samples.count,
                                     selectedSample: selectedSample,
                                     frameStats: selectedStats)
                .padding(horizontal: 12, vertical: 8)
            Divider()

            Row(alignment: .top, spacing: 0) {
                DeveloperProfilerFrameList(samples: samples,
                                           selectedFilter: $selectedFrameFilter,
                                           selectedSampleIndex: selectedSampleIndex)
                    .frame(minWidth: 220, maxWidth: 260)
                    .flex(0, shrink: 1, basis: 248)

                Divider(axis: .vertical)
                    .frame(width: 1)

                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Box(direction: .column, alignItems: .stretch, spacing: 10) {
                        DeveloperProfilerSelectedFrameCard(sample: selectedSample,
                                                           stats: selectedStats)
                        DeveloperProfilerBottleneckSummaryCard(stats: selectedStats,
                                                               renderStats: renderStats,
                                                               particleSample: selectedParticleSample)
                        DeveloperProfilerFrameGraph(samples: samples,
                                                    selectedSample: selectedSample,
                                                    selectedSampleIndex: selectedSampleIndex)
                        DeveloperProfilerFrameComposition(stats: selectedStats)
                        DeveloperProfilerPhaseBreakdown(stats: selectedStats,
                                                        renderStats: renderStats,
                                                        particleSample: selectedParticleSample)
                        DeveloperProfilerIssuePane(issues: issues,
                                                   selectedSampleIndex: selectedSampleIndex,
                                                   onOpenTarget: onOpenTarget)
                    }
                    .framePercent(width: 100, minWidth: 0)
                    .padding(horizontal: 10, vertical: 10)
                }
                .frame(minWidth: 0)
                .flex(1, shrink: 1, basis: 0)
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
        Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
            DeveloperStatusPill(label: "LIVE", status: .nominal)
            Column(alignment: .leading, spacing: 2) {
                Text("Profiler")
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text(developerProfilerToolbarSubtitle(sampleCount: sampleCount,
                                                       selectedSample: selectedSample))
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .flex(1, shrink: 1, basis: 140)

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
            DeveloperProfilerMetric(label: "Pacing",
                                    value: developerProfilerFormatMs(frameStats.pacingGapMs),
                                    status: developerProfilerPacingStatus(frameStats.pacingGapMs))
        }
    }
}

private struct DeveloperStatusPill: View {
    let label: String
    let status: DeveloperPerformanceMonitorStatus

    var body: some View {
        Row(alignment: .center, spacing: 5) {
            Box { EmptyView() }
                .frame(width: 6, height: 6)
                .background(developerPerformanceStatusColor(status))
                .cornerRadius(3)
            Text(label)
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(.onSurface)
        }
        .padding(horizontal: 8, vertical: 5)
        .background(.surfaceSunken)
        .border(.divider, width: 1)
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
    let selectedFilter: Binding<DeveloperProfilerFrameFilter>
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        let filteredSamples = developerProfilerFilteredSamples(samples, filter: selectedFilter.wrappedValue)
        let visibleRows = developerProfilerVisibleFrameRows(
            filteredSamples,
            selectedSampleIndex: selectedSampleIndex.wrappedValue,
            maxRows: DeveloperProfilerConstants.maxMaterializedFrameRows
        )
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 8) {
                Text("Frames")
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text(developerProfilerFrameFilterCountLabel(visible: filteredSamples.count,
                                                            total: samples.count))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Spacer(minLength: 0)
            }
            .padding(horizontal: 10, vertical: 7)
            .background(.surfaceFloating)

            Divider()

            DeveloperProfilerFrameHealthCard(samples: samples)
                .padding(horizontal: 10, vertical: 8)

            Divider()

            DeveloperProfilerFrameFilterBar(samples: samples,
                                            selectedFilter: selectedFilter,
                                            selectedSampleIndex: selectedSampleIndex)
                .padding(horizontal: 8, vertical: 7)

            Divider()

            Row(alignment: .center, spacing: 8) {
                Text("Sample")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .frame(width: 58)
                Text("Work")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .frame(width: 72)
                Text("Focus")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .flex(1, shrink: 1)
            }
            .padding(horizontal: 10, vertical: 5)
            .background(.surface)

            ScrollView(.vertical) {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    if filteredSamples.isEmpty {
                        Text("No frames match")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                            .padding(horizontal: 10, vertical: 8)
                    } else {
                        for sample in visibleRows.reversed() {
                            DeveloperProfilerFrameRow(sample: sample,
                                                      isSelected: selectedSampleIndex.wrappedValue == sample.sampleIndex,
                                                      onSelect: {
                                                          selectedSampleIndex.wrappedValue = sample.sampleIndex
                                                      })
                        }
                    }
                }
                .framePercent(width: 100, minWidth: 0)
            }
            .background(.surfaceSunken)
        }
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperProfilerFrameFilterBar: View {
    let samples: [EditorFrameStatsHistorySample]
    let selectedFilter: Binding<DeveloperProfilerFrameFilter>
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 5) {
            for filter in DeveloperProfilerFrameFilter.allCases {
                DeveloperProfilerFrameFilterChip(
                    filter: filter,
                    count: developerProfilerFilteredSamples(samples, filter: filter).count,
                    isSelected: selectedFilter.wrappedValue == filter,
                    onSelect: {
                        selectedFilter.wrappedValue = filter
                        developerProfilerSelectLatestVisibleFrame(samples: samples,
                                                                  filter: filter,
                                                                  selectedSampleIndex: selectedSampleIndex)
                    }
                )
            }
        }
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperProfilerFrameFilterChip: View {
    let filter: DeveloperProfilerFrameFilter
    let count: Int
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(isSelected: isSelected, action: onSelect) {
            Row(alignment: .center, spacing: 4) {
                Text(filter.label, lineLimit: 1)
                Text("\(count)", lineLimit: 1)
                    .font(.mono)
            }
        }
        .buttonStyle(ToggleButtonStyle(minWidth: 42, height: 22))
    }
}

private struct DeveloperProfilerFrameRow: View {
    let sample: EditorFrameStatsHistorySample
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let status = developerProfilerFrameStatus(sample.stats.frameMs)
        let workStatus = developerProfilerFrameStatus(sample.stats.workMs)
        let focus = developerProfilerFrameFocus(sample.stats)
        let focusColor = isSelected ? developerPerformanceStatusColor(focus.status) : .onSurfaceMuted
        Button(action: onSelect) {
            Row(alignment: .center, spacing: 0) {
                Box { EmptyView() }
                    .frame(width: 3, height: 26)
                    .background(developerPerformanceStatusColor(status))
                Row(alignment: .center, spacing: 8) {
                    Text("#\(sample.sampleIndex)")
                        .lineLimit(1)
                        .font(.mono)
                        .foregroundColor(isSelected ? .accent : .onSurface)
                        .frame(width: 58)
                    Text(developerProfilerFormatMs(sample.stats.workMs))
                        .lineLimit(1)
                        .font(.mono)
                        .foregroundColor(developerPerformanceStatusColor(workStatus))
                        .frame(width: 72)
                    Row(alignment: .center, spacing: 5) {
                        if isSelected && focus.status != .nominal {
                            Box { EmptyView() }
                                .frame(width: 6, height: 6)
                                .background(developerPerformanceStatusColor(focus.status))
                                .cornerRadius(3)
                        }
                        Text(focus.label)
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(focusColor)
                            .flex(1, shrink: 1)
                    }
                    .flex(1, shrink: 1)
                }
                .padding(horizontal: 7, vertical: 4)
                .framePercent(width: 100, minWidth: 0)
            }
            .background(isSelected ? .accent.opacity(0.12) : .surfaceSunken)
            .border(isSelected ? .accent : .divider, width: isSelected ? 1 : 0)
        }
        .buttonStyle(.plain)
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperProfilerFrameHealthCard: View {
    let samples: [EditorFrameStatsHistorySample]

    var body: some View {
        let health = developerProfilerFrameHealth(samples: samples)
        let status = developerProfilerFrameHealthStatus(health)
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Row(alignment: .center, spacing: 6) {
                Text("Frame Health")
                    .lineLimit(1)
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Spacer(minLength: 0)
                Text("\(health.sampleCount) samples")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }

            Row(alignment: .center, spacing: 6) {
                DeveloperProfilerHealthMetric(label: "Budget",
                                              value: "\(Int(health.budgetHitRate.rounded()))%",
                                              status: status)
                DeveloperProfilerHealthMetric(label: "Avg",
                                              value: developerProfilerFormatMs(health.averageWorkMs),
                                              status: developerProfilerFrameStatus(health.averageWorkMs))
                DeveloperProfilerHealthMetric(label: "Max",
                                              value: developerProfilerFormatMs(health.maxWorkMs),
                                              status: developerProfilerFrameStatus(health.maxWorkMs))
            }

            Row(alignment: .center, spacing: 6) {
                DeveloperProfilerHealthMetric(label: "Over",
                                              value: "\(health.overBudgetCount)",
                                              status: health.overBudgetCount > 0 ? .warning : .nominal)
                DeveloperProfilerHealthMetric(label: "Critical",
                                              value: "\(health.criticalCount)",
                                              status: health.criticalCount > 0 ? .critical : .nominal)
                DeveloperProfilerHealthMetric(label: "Pacing",
                                              value: "\(health.pacingCount)",
                                              status: health.pacingCount > 0 ? .warning : .nominal)
            }
        }
        .padding(horizontal: 8, vertical: 7)
        .background(.surface)
        .border(status == .nominal ? .divider : developerPerformanceStatusColor(status), width: 1)
    }
}

private struct DeveloperProfilerHealthMetric: View {
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
        .padding(horizontal: 6, vertical: 4)
        .background(.surfaceSunken)
        .border(status == .nominal ? .divider : developerPerformanceStatusColor(status), width: 1)
        .flex(1, shrink: 1)
    }
}

private struct DeveloperProfilerSelectedFrameCard: View {
    let sample: EditorFrameStatsHistorySample?
    let stats: EditorFrameStats

    var body: some View {
        let frameStatus = developerProfilerFrameStatus(stats.frameMs)
        Box(direction: .column, alignItems: .stretch, spacing: 9) {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                Column(alignment: .leading, spacing: 3) {
                    Row(alignment: .center, spacing: 8) {
                        Text(sample.map { "Frame #\($0.frameIndex)" } ?? "Latest Frame")
                            .lineLimit(1)
                            .font(.bodyStrong)
                            .foregroundColor(.onSurface)
                        Text(sample.map { "sample #\($0.sampleIndex)" } ?? "live")
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    Text(developerProfilerBottleneckLabel(stats))
                        .lineLimit(2)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
                .flex(1, shrink: 1, basis: 160)

                DeveloperStatusPill(label: developerProfilerFrameStatusShortLabel(stats.frameMs),
                                    status: frameStatus)
            }

            Box(direction: .row, alignItems: .stretch, wrap: .wrap, spacing: 8) {
                DeveloperProfilerCompactMetric(label: "Observed",
                                               value: developerProfilerFormatFPS(stats.fps),
                                               status: .nominal)
                DeveloperProfilerCompactMetric(label: "Work FPS",
                                               value: developerProfilerFormatFPS(stats.workFPS),
                                               status: developerProfilerFrameStatus(stats.workMs))
                DeveloperProfilerCompactMetric(label: "Draws",
                                               value: "\(stats.drawCallCount)",
                                               status: .nominal)
                DeveloperProfilerCompactMetric(label: "Passes",
                                               value: "\(stats.passCount)",
                                               status: .nominal)
            }
        }
        .padding(horizontal: 10, vertical: 9)
        .background(.surface)
        .border(developerPerformanceStatusColor(frameStatus), width: 1)
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperProfilerCompactMetric: View {
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
        .flex(1, shrink: 1, basis: 88)
    }
}

private struct DeveloperProfilerBottleneckSummaryCard: View {
    let stats: EditorFrameStats
    let renderStats: RenderFrameStats
    let particleSample: EditorParticleDiagnosticsSample?

    var body: some View {
        let summary = developerProfilerBottleneckSummary(stats: stats,
                                                         renderStats: renderStats,
                                                         particleSample: particleSample)
        Box(direction: .column, alignItems: .stretch, spacing: 7) {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                DeveloperStatusPill(label: developerPerformanceMonitorStatusLabel(summary.status),
                                    status: summary.status)
                Text(summary.title)
                    .lineLimit(2)
                    .font(.bodyStrong)
                    .foregroundColor(developerPerformanceStatusColor(summary.status))
                    .flex(1, shrink: 1, basis: 140)
            }

            Text(summary.primarySignal)
                .lineLimit(2)
                .font(.caption)
                .foregroundColor(.onSurface)

            DeveloperProfilerEvidenceGrid(items: summary.evidence)

            Text(summary.action)
                .lineLimit(2)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 10, vertical: 8)
        .background(.surface)
        .border(summary.status == .nominal ? .divider : developerPerformanceStatusColor(summary.status), width: 1)
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperProfilerEvidenceGrid: View {
    let items: [DeveloperProfilerEvidenceItem]

    var body: some View {
        let visibleItems = Array(items.prefix(4))
        Box(direction: .row, alignItems: .stretch, wrap: .wrap, spacing: 6) {
            for item in visibleItems {
                DeveloperProfilerEvidenceCell(item: item)
            }
        }
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperProfilerEvidenceCell: View {
    let item: DeveloperProfilerEvidenceItem

    var body: some View {
        Row(alignment: .center, spacing: 6) {
            Text(item.label)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1, basis: 0)
            Text(item.value)
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(developerPerformanceStatusColor(item.status))
                .flex(0, shrink: 0)
        }
        .padding(horizontal: 8, vertical: 5)
        .background(.surfaceSunken)
        .border(item.status == .nominal ? .divider : developerPerformanceStatusColor(item.status), width: 1)
        .frame(minWidth: 104)
        .flex(1, shrink: 1, basis: 112)
    }
}

private struct DeveloperProfilerFrameGraph: View {
    let samples: [EditorFrameStatsHistorySample]
    let selectedSample: EditorFrameStatsHistorySample?
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        let visibleSamples = Array(samples.suffix(DeveloperProfilerConstants.maxGraphSamples))
        let values = visibleSamples.map { Float($0.stats.frameMs) }
        let graphMaxValue = developerProfilerFrameChartMaxValue(values: values)
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                Text("Frame Time")
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text(developerPerformanceMonitorRangeLabel(values: values, unit: .milliseconds))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .flex(1, shrink: 1, basis: 120)
                Text("\(visibleSamples.count) recent")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Text(selectedSample.map { "#\($0.sampleIndex)" } ?? "Latest")
                    .lineLimit(1)
                    .font(.mono)
                    .foregroundColor(.accent)
            }

            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 10) {
                DeveloperProfilerLegend(label: "16.7 ms budget", color: .warning)
                DeveloperProfilerLegend(label: "OK", color: .success.opacity(0.75))
                DeveloperProfilerLegend(label: "Over", color: .warning)
                DeveloperProfilerLegend(label: "Critical", color: .error)
            }

            DeveloperProfilerFrameHeatStrip(samples: visibleSamples,
                                            selectedSample: selectedSample,
                                            selectedSampleIndex: selectedSampleIndex)
                .frame(height: 44)

            MonitorChart(values: values,
                         color: .accent,
                         mode: .line,
                         threshold: ChartThreshold(value: 16.7, color: .warning),
                         marker: developerProfilerMarker(samples: visibleSamples,
                                                         selectedSample: selectedSample),
                         style: ChartStyle(minValue: 0,
                                           maxValue: graphMaxValue,
                                           gridLineCount: 5,
                                           lineWidth: 2.0,
                                           barSpacing: 1,
                                           contentInset: 6,
                                           background: .surfaceSunken,
                                           gridColor: .divider))
                .frame(height: 76)
        }
        .padding(horizontal: 10, vertical: 8)
        .background(.surface)
        .border(.divider, width: 1)
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperProfilerFrameHeatStrip: View {
    let samples: [EditorFrameStatsHistorySample]
    let selectedSample: EditorFrameStatsHistorySample?
    let selectedSampleIndex: Binding<UInt64?>

    var body: some View {
        let maxMs = max(samples.map(\.stats.frameMs).max() ?? 16.7, 33.3)
        Box(direction: .row, alignItems: .stretch, spacing: 1) {
            for sample in samples {
                DeveloperProfilerFrameHeatBar(sample: sample,
                                              maxMs: maxMs,
                                              isSelected: selectedSample?.sampleIndex == sample.sampleIndex,
                                              onSelect: {
                                                  selectedSampleIndex.wrappedValue = sample.sampleIndex
                                              })
            }
        }
        .padding(horizontal: 4, vertical: 4)
        .background(.surfaceSunken)
        .border(.divider, width: 1)
    }
}

private struct DeveloperProfilerFrameHeatBar: View {
    let sample: EditorFrameStatsHistorySample
    let maxMs: Double
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let ratio = Float(min(max(sample.stats.frameMs / max(maxMs, 0.001), 0), 1))
        let barHeight = max(4, ratio * 34)
        Button(action: onSelect) {
            Box(direction: .column, alignItems: .stretch, justifyContent: .flexEnd) {
                Box { EmptyView() }
                    .frame(height: barHeight)
                    .background(developerProfilerFrameHeatColor(sample.stats.frameMs))
            }
            .background(isSelected ? .accent.opacity(0.20) : .surface)
            .border(isSelected ? .accent : .surfaceSunken, width: isSelected ? 1 : 0)
        }
        .buttonStyle(.plain)
        .flex(1, shrink: 1, basis: 2)
    }
}

private struct DeveloperProfilerFrameComposition: View {
    let stats: EditorFrameStats

    var body: some View {
        let inputMs = stats.inputSeconds * 1000
        let simulationMs = stats.simulationSeconds * 1000
        let prepareMs = stats.renderPrepareSeconds * 1000
        let submitMs = stats.renderSubmitSeconds * 1000
        let presentMs = stats.gpuPresentSeconds * 1000
        let pacingMs = stats.pacingGapMs
        let measuredMs = inputMs + simulationMs + prepareMs + submitMs + presentMs + pacingMs
        let totalMs = max(stats.frameMs, stats.workMs, measuredMs, 0.001)
        Box(direction: .column, alignItems: .stretch, spacing: 7) {
            Row(alignment: .center, spacing: 8) {
                Text("Frame Composition")
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Spacer(minLength: 0)
            }

            Row(alignment: .center, spacing: 10) {
                DeveloperProfilerLegend(label: "CPU", color: .info)
                DeveloperProfilerLegend(label: "GPU", color: .accentSecondary)
                DeveloperProfilerLegend(label: "Pacing", color: .accentMuted)
                Spacer(minLength: 0)
            }

            Box(direction: .row, alignItems: .stretch) {
                DeveloperProfilerCompositionSegment(valueMs: inputMs,
                                                    totalMs: totalMs,
                                                    color: .info)
                DeveloperProfilerCompositionSegment(valueMs: simulationMs,
                                                    totalMs: totalMs,
                                                    color: .info.opacity(0.75))
                DeveloperProfilerCompositionSegment(valueMs: prepareMs,
                                                    totalMs: totalMs,
                                                    color: .success)
                DeveloperProfilerCompositionSegment(valueMs: submitMs,
                                                    totalMs: totalMs,
                                                    color: .success.opacity(0.75))
                DeveloperProfilerCompositionSegment(valueMs: presentMs,
                                                    totalMs: totalMs,
                                                    color: .accentSecondary)
                DeveloperProfilerCompositionSegment(valueMs: pacingMs,
                                                    totalMs: totalMs,
                                                    color: .accentMuted.opacity(0.75))
                DeveloperProfilerCompositionSegment(valueMs: max(0, totalMs - measuredMs),
                                                    totalMs: totalMs,
                                                    color: .surfaceSunken)
            }
            .frame(height: 16)
            .background(.surfaceSunken)
            .cornerRadius(3)

            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 8) {
                DeveloperProfilerValueRow(label: "Frame", value: developerProfilerFormatMs(stats.frameMs))
                    .flex(1, shrink: 1, basis: 92)
                DeveloperProfilerValueRow(label: "Work", value: developerProfilerFormatMs(stats.workMs))
                    .flex(1, shrink: 1, basis: 92)
                DeveloperProfilerValueRow(label: "Pacing", value: developerProfilerFormatMs(stats.pacingGapMs))
                    .flex(1, shrink: 1, basis: 92)
            }
        }
        .padding(horizontal: 10, vertical: 8)
        .background(.surface)
        .border(.divider, width: 1)
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperProfilerLegend: View {
    let label: String
    let color: SemanticColorRef

    var body: some View {
        Row(alignment: .center, spacing: 4) {
            Box { EmptyView() }
                .frame(width: 7, height: 7)
                .background(color)
                .cornerRadius(2)
            Text(label)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
    }
}

private struct DeveloperProfilerCompositionSegment: View {
    let valueMs: Double
    let totalMs: Double
    let color: SemanticColorRef

    var body: some View {
        let weight = Float(max(0, valueMs))
        let visibleWeight = weight > 0 ? max(weight, Float(totalMs) * 0.012) : 0
        Box { EmptyView() }
            .flex(visibleWeight, shrink: 1)
            .background(valueMs > 0 ? color : .surfaceSunken)
    }
}

private struct DeveloperProfilerPhaseBreakdown: View {
    let stats: EditorFrameStats
    let renderStats: RenderFrameStats
    let particleSample: EditorParticleDiagnosticsSample?

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 10) {
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

            Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 10) {
                DeveloperProfilerSection(title: "Render") {
                    DeveloperProfilerValueRow(label: "Draw Calls", value: "\(stats.drawCallCount)")
                    DeveloperProfilerValueRow(label: "Passes", value: "\(stats.passCount)")
                    DeveloperProfilerValueRow(label: "Bundles", value: "\(stats.renderBundleCount)")
                    DeveloperProfilerValueRow(label: "Encode", value: developerProfilerFormatNs(renderStats.cpuEncodeNS))
                    DeveloperProfilerValueRow(label: "Present", value: developerProfilerFormatMs(stats.gpuPresentSeconds * 1000))
                }
                .flex(1, shrink: 1, basis: 160)

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
                .flex(1, shrink: 1, basis: 160)
            }
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
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Text(title)
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
            content
        }
        .padding(horizontal: 10, vertical: 8)
        .background(.surface)
        .border(.divider, width: 1)
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperProfilerPhaseRow: View {
    let label: String
    let valueMs: Double
    let totalMs: Double

    var body: some View {
        let fraction = Float(min(max(valueMs / totalMs, 0), 1))
        let filledWeight = max(fraction, 0.001)
        let remainingWeight = max(1 - fraction, 0.001)
        Row(alignment: .center, spacing: 8) {
            Text(label)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: 108)
            Box(direction: .row, alignItems: .stretch, spacing: 0) {
                if valueMs > 0 {
                    Box { EmptyView() }
                        .flex(filledWeight, shrink: 1)
                        .background(.accent)
                }
                Box { EmptyView() }
                    .flex(remainingWeight, shrink: 1)
                    .background(.surfaceSunken)
            }
            .frame(height: 6)
            .cornerRadius(2)
            .flex(1, shrink: 1)
            Text(developerProfilerFormatMs(valueMs))
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(.onSurface)
                .frame(width: 64)
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
                .flex(1, shrink: 1, basis: 0)
            Text(value)
                .lineLimit(1)
                .font(.mono)
                .foregroundColor(.onSurface)
                .flex(0, shrink: 0)
        }
    }
}

private struct DeveloperProfilerIssuePane: View {
    let issues: [DeveloperDiagnosticIssue]
    let selectedSampleIndex: Binding<UInt64?>
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

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
                        DeveloperProfilerIssueRow(issue: issue,
                                                  selectedSampleIndex: selectedSampleIndex,
                                                  onOpenTarget: onOpenTarget)
                    }
                }
            }
        }
    }
}

private struct DeveloperProfilerIssueRow: View {
    let issue: DeveloperDiagnosticIssue
    let selectedSampleIndex: Binding<UInt64?>
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

    var body: some View {
        let targetSampleIndex = issue.target.frameSampleIndex
        Row(alignment: .center, spacing: 8) {
            Text(developerIssueGlyph(issue.severity))
                .font(.mono)
                .foregroundColor(developerIssueColor(issue.severity))
                .frame(width: 18)
            Text(issue.scope.rawValue)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: 64)
            Text(issue.title)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurface)
                .flex(1, shrink: 1)
            Text(issue.primarySignal)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .flex(1, shrink: 1)
            Button(action: { onOpenTarget(issue.target) }) {
                Text(issue.target.label, lineLimit: 1)
                    .font(.caption)
                    .foregroundColor(targetSampleIndex != nil && selectedSampleIndex.wrappedValue == targetSampleIndex
                        ? .accent
                        : .onSurface)
            }
            .buttonStyle(.ghost)
            .flex(0, shrink: 1)
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
            DeveloperStatusPill(label: "LIVE", status: .nominal)
            Column(alignment: .leading, spacing: 2) {
                Text("Performance Monitors")
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text("\(monitors.count) counters")
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
        Row(alignment: .center, spacing: 7) {
            Box { EmptyView() }
                .frame(width: 8, height: 8)
                .background(category.color)
                .cornerRadius(2)
            Text(category.rawValue)
                .lineLimit(1)
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
            Spacer(minLength: 0)
        }
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
            Box { EmptyView() }
                .frame(width: 7, height: 7)
                .background(developerPerformanceStatusColor(monitor.status))
                .cornerRadius(3)
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
                }
                .padding(horizontal: 12, vertical: 12)
            } else {
                Box(direction: .column, alignItems: .stretch, spacing: 10) {
                    DeveloperPerformanceMonitorSummary(monitors: monitors.sorted(by: developerPerformanceMonitorPrecedes))
                    for monitor in monitors.sorted(by: developerPerformanceMonitorPrecedes) {
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
        Row(alignment: .top, spacing: 0) {
            Box { EmptyView() }
                .frame(width: 3, height: 174)
                .background(monitor.category.color)

            Box(direction: .column, alignItems: .stretch, spacing: 7) {
                Row(alignment: .center, spacing: 8) {
                    Text(monitor.category.rawValue)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .frame(width: 72)
                    DeveloperStatusPill(label: developerPerformanceMonitorStatusLabel(monitor.status),
                                        status: monitor.status)
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
                             color: monitor.status == .nominal ? monitor.category.color : developerPerformanceStatusColor(monitor.status),
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
            .flex(1, shrink: 1)
        }
        .background(.surface)
        .border(monitor.status == .nominal ? .divider : developerPerformanceStatusColor(monitor.status), width: 1)
    }
}

private struct DeveloperMonitorSeries {
    var values: [Float]
    var sampleIndices: [UInt64]
}

private struct DeveloperProfilerBottleneckSummary {
    var title: String
    var status: DeveloperPerformanceMonitorStatus
    var primarySignal: String
    var evidence: [DeveloperProfilerEvidenceItem]
    var action: String
}

private struct DeveloperProfilerEvidenceItem {
    var label: String
    var value: String
    var status: DeveloperPerformanceMonitorStatus
}

private struct DeveloperProfilerFrameHealth {
    var sampleCount: Int
    var overBudgetCount: Int
    var criticalCount: Int
    var pacingCount: Int
    var budgetHitRate: Double
    var averageWorkMs: Double
    var maxWorkMs: Double
}

private struct DeveloperProfilerFrameFocus {
    var label: String
    var status: DeveloperPerformanceMonitorStatus
}

private enum DeveloperProfilerFrameFilter: CaseIterable, Equatable {
    case all
    case hot
    case critical
    case pacing
    case submit

    var label: String {
        switch self {
        case .all:
            return "All"
        case .hot:
            return "Hot"
        case .critical:
            return "Crit"
        case .pacing:
            return "Pacing"
        case .submit:
            return "Submit"
        }
    }
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

private func developerPerformanceMonitorStatusLabel(_ status: DeveloperPerformanceMonitorStatus) -> String {
    switch status {
    case .nominal:
        return "OK"
    case .warning:
        return "WARN"
    case .critical:
        return "CRIT"
    }
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

private func developerProfilerFilteredSamples(_ samples: [EditorFrameStatsHistorySample],
                                              filter: DeveloperProfilerFrameFilter) -> [EditorFrameStatsHistorySample] {
    samples.filter { developerProfilerFrameMatchesFilter($0, filter: filter) }
}

private func developerProfilerVisibleFrameRows(_ samples: [EditorFrameStatsHistorySample],
                                               selectedSampleIndex: UInt64?,
                                               maxRows: Int) -> [EditorFrameStatsHistorySample] {
    guard samples.count > maxRows else { return samples }
    var visible = Array(samples.suffix(max(1, maxRows)))
    guard let selectedSampleIndex,
          !visible.contains(where: { $0.sampleIndex == selectedSampleIndex }),
          let selected = samples.first(where: { $0.sampleIndex == selectedSampleIndex })
    else {
        return visible
    }

    visible.removeFirst()
    visible.insert(selected, at: 0)
    return visible
}

private func developerProfilerFrameMatchesFilter(_ sample: EditorFrameStatsHistorySample,
                                                 filter: DeveloperProfilerFrameFilter) -> Bool {
    switch filter {
    case .all:
        return true
    case .hot:
        return developerProfilerFrameStatus(sample.stats.frameMs) != .nominal
            || developerProfilerFrameStatus(sample.stats.workMs) != .nominal
            || developerProfilerPacingStatus(sample.stats.pacingGapMs) != .nominal
            || sample.stats.isFramePacingDominated
    case .critical:
        return developerProfilerFrameStatus(sample.stats.frameMs) == .critical
            || developerProfilerFrameStatus(sample.stats.workMs) == .critical
            || developerProfilerPacingStatus(sample.stats.pacingGapMs) == .critical
    case .pacing:
        return sample.stats.isFramePacingDominated
            || developerProfilerPacingStatus(sample.stats.pacingGapMs) != .nominal
    case .submit:
        return developerProfilerFrameFocus(sample.stats).label == "Submit"
    }
}

private func developerProfilerFrameFilterCountLabel(visible: Int, total: Int) -> String {
    visible == total ? "\(total)" : "\(visible)/\(total)"
}

private func developerProfilerSelectLatestVisibleFrame(samples: [EditorFrameStatsHistorySample],
                                                       filter: DeveloperProfilerFrameFilter,
                                                       selectedSampleIndex: Binding<UInt64?>) {
    let visibleSamples = developerProfilerFilteredSamples(samples, filter: filter)
    if let current = selectedSampleIndex.wrappedValue,
       visibleSamples.contains(where: { $0.sampleIndex == current }) {
        return
    }
    selectedSampleIndex.wrappedValue = visibleSamples.last?.sampleIndex ?? samples.last?.sampleIndex
}

private func developerProfilerToolbarSubtitle(sampleCount: Int,
                                              selectedSample: EditorFrameStatsHistorySample?) -> String {
    let selected = selectedSample.map { "#\($0.sampleIndex)" } ?? "latest"
    return "\(sampleCount) frames | \(selected)"
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

private func developerProfilerFrameHealth(samples: [EditorFrameStatsHistorySample]) -> DeveloperProfilerFrameHealth {
    guard !samples.isEmpty else {
        return DeveloperProfilerFrameHealth(sampleCount: 0,
                                            overBudgetCount: 0,
                                            criticalCount: 0,
                                            pacingCount: 0,
                                            budgetHitRate: 100,
                                            averageWorkMs: 0,
                                            maxWorkMs: 0)
    }

    let overBudgetCount = samples.filter { developerProfilerFrameStatus($0.stats.frameMs) != .nominal }.count
    let criticalCount = samples.filter { developerProfilerFrameStatus($0.stats.frameMs) == .critical }.count
    let pacingCount = samples.filter {
        $0.stats.isFramePacingDominated || developerProfilerPacingStatus($0.stats.pacingGapMs) != .nominal
    }.count
    let totalFrameMs = samples.reduce(0) { $0 + $1.stats.frameMs }
    let maxFrameMs = samples.map(\.stats.frameMs).max() ?? 0
    let budgetHitRate = Double(max(samples.count - overBudgetCount, 0)) / Double(samples.count) * 100

    return DeveloperProfilerFrameHealth(sampleCount: samples.count,
                                        overBudgetCount: overBudgetCount,
                                        criticalCount: criticalCount,
                                        pacingCount: pacingCount,
                                        budgetHitRate: budgetHitRate,
                                        averageWorkMs: totalFrameMs / Double(samples.count),
                                        maxWorkMs: maxFrameMs)
}

private func developerProfilerFrameHealthStatus(_ health: DeveloperProfilerFrameHealth) -> DeveloperPerformanceMonitorStatus {
    if health.criticalCount > 0 {
        return .critical
    }
    if health.overBudgetCount > 0 || health.pacingCount > 0 {
        return .warning
    }
    return .nominal
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

private func developerProfilerFrameChartMaxValue(values: [Float]) -> Float? {
    guard let maxValue = values.max() else { return 50.1 }
    let visualCeiling = max(Float(50.1), min(maxValue * 1.08, Float(120)))
    return visualCeiling
}

private func developerProfilerFrameStatus(_ workMs: Double) -> DeveloperPerformanceMonitorStatus {
    if workMs > 33.3 { return .critical }
    if workMs > 16.7 { return .warning }
    return .nominal
}

private func developerProfilerFrameStatusShortLabel(_ workMs: Double) -> String {
    switch developerProfilerFrameStatus(workMs) {
    case .nominal:
        return "OK"
    case .warning:
        return "OVER"
    case .critical:
        return "CRIT"
    }
}

private func developerProfilerFrameHeatColor(_ workMs: Double) -> SemanticColorRef {
    switch developerProfilerFrameStatus(workMs) {
    case .nominal:
        return .success.opacity(0.75)
    case .warning:
        return .warning
    case .critical:
        return .error
    }
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

private func developerProfilerPacingStatus(_ pacingMs: Double) -> DeveloperPerformanceMonitorStatus {
    if pacingMs > 33.3 { return .critical }
    if pacingMs > 16.7 { return .warning }
    return .nominal
}

private func developerProfilerFrameFocus(_ stats: EditorFrameStats) -> DeveloperProfilerFrameFocus {
    let cpuMs = stats.cpuWorkSeconds * 1000
    let gpuMs = stats.gpuPresentSeconds * 1000
    let pacingStatus = developerProfilerPacingStatus(stats.pacingGapMs)
    let frameStatus = developerProfilerFrameStatus(stats.workMs)
    let cpuStatus = developerProfilerCPUStatus(cpuMs)
    let gpuStatus = developerProfilerGPUStatus(gpuMs)

    if stats.isFramePacingDominated || pacingStatus != .nominal {
        return DeveloperProfilerFrameFocus(label: "Pacing", status: pacingStatus)
    }

    if gpuStatus != .nominal && gpuMs >= cpuMs {
        return DeveloperProfilerFrameFocus(label: "GPU", status: gpuStatus)
    }

    if cpuStatus != .nominal || frameStatus != .nominal {
        let renderSubmitSeconds = stats.renderSubmitSeconds
        let renderPrepareSeconds = stats.renderPrepareSeconds
        let simulationSeconds = stats.simulationSeconds
        if renderSubmitSeconds >= renderPrepareSeconds && renderSubmitSeconds >= simulationSeconds {
            return DeveloperProfilerFrameFocus(label: "Submit", status: max(cpuStatus, frameStatus))
        }
        if renderPrepareSeconds >= simulationSeconds {
            return DeveloperProfilerFrameFocus(label: "Prepare", status: max(cpuStatus, frameStatus))
        }
        return DeveloperProfilerFrameFocus(label: "Sim", status: max(cpuStatus, frameStatus))
    }

    return DeveloperProfilerFrameFocus(label: "OK", status: .nominal)
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

private func developerProfilerBottleneckSummary(
    stats: EditorFrameStats,
    renderStats: RenderFrameStats,
    particleSample: EditorParticleDiagnosticsSample?
) -> DeveloperProfilerBottleneckSummary {
    let cpuMs = stats.cpuWorkSeconds * 1000
    let gpuMs = stats.gpuPresentSeconds * 1000
    let pacingMs = stats.pacingGapMs
    let renderSubmitMs = stats.renderSubmitSeconds * 1000
    let renderPrepareMs = stats.renderPrepareSeconds * 1000
    let simulationMs = stats.simulationSeconds * 1000
    let particleDrops = particleSample.map(developerProfilerParticleDropCount) ?? 0

    let baseEvidence = [
        DeveloperProfilerEvidenceItem(label: "Frame",
                                      value: developerProfilerFormatMs(stats.frameMs),
                                      status: developerProfilerFrameStatus(stats.frameMs)),
        DeveloperProfilerEvidenceItem(label: "Work",
                                      value: developerProfilerFormatMs(stats.workMs),
                                      status: developerProfilerFrameStatus(stats.workMs)),
    ]

    if stats.isFramePacingDominated || developerProfilerPacingStatus(pacingMs) != .nominal {
        return DeveloperProfilerBottleneckSummary(
            title: "Frame pacing wait",
            status: developerProfilerPacingStatus(pacingMs),
            primarySignal: "Most of this frame is waiting outside engine work.",
            evidence: baseEvidence + [
                DeveloperProfilerEvidenceItem(label: "Pacing",
                                              value: developerProfilerFormatMs(pacingMs),
                                              status: developerProfilerPacingStatus(pacingMs)),
                DeveloperProfilerEvidenceItem(label: "GPU",
                                              value: developerProfilerFormatMs(gpuMs),
                                              status: developerProfilerGPUStatus(gpuMs)),
            ],
            action: "Check presentation wait, throttling, vsync, or frame limiter before optimizing CPU systems."
        )
    }

    if developerProfilerGPUStatus(gpuMs) != .nominal && gpuMs >= cpuMs {
        return DeveloperProfilerBottleneckSummary(
            title: "GPU present pressure",
            status: developerProfilerGPUStatus(gpuMs),
            primarySignal: "GPU present time is higher than CPU work for this frame.",
            evidence: baseEvidence + [
                DeveloperProfilerEvidenceItem(label: "GPU",
                                              value: developerProfilerFormatMs(gpuMs),
                                              status: developerProfilerGPUStatus(gpuMs)),
                DeveloperProfilerEvidenceItem(label: "Draws",
                                              value: "\(stats.drawCallCount)",
                                              status: .nominal),
            ],
            action: "Inspect passes, overdraw, render targets, and shader cost before tuning simulation code."
        )
    }

    if developerProfilerCPUStatus(cpuMs) != .nominal || developerProfilerFrameStatus(stats.workMs) != .nominal {
        let renderSubmitDominates = renderSubmitMs >= simulationMs && renderSubmitMs >= renderPrepareMs
        let renderPrepareDominates = renderPrepareMs >= simulationMs
        let title: String
        let action: String
        if renderSubmitDominates {
            title = "Render submit cost"
            action = "Inspect draw submission, pass count, bundle use, and render encoder work."
        } else if renderPrepareDominates {
            title = "Render prepare cost"
            action = "Inspect visibility, batching, material sorting, and render data preparation."
        } else {
            title = "Simulation cost"
            action = "Inspect update systems and simulation work before changing render settings."
        }
        return DeveloperProfilerBottleneckSummary(
            title: title,
            status: max(developerProfilerCPUStatus(cpuMs), developerProfilerFrameStatus(stats.workMs)),
            primarySignal: "Engine work is over frame budget.",
            evidence: baseEvidence + [
                DeveloperProfilerEvidenceItem(label: "CPU",
                                              value: developerProfilerFormatMs(cpuMs),
                                              status: developerProfilerCPUStatus(cpuMs)),
                DeveloperProfilerEvidenceItem(label: "Submit",
                                              value: developerProfilerFormatMs(renderSubmitMs),
                                              status: developerProfilerFrameStatus(renderSubmitMs)),
            ],
            action: action
        )
    }

    if particleDrops > 0 {
        return DeveloperProfilerBottleneckSummary(
            title: "Particle spawn pressure",
            status: .warning,
            primarySignal: "Particles are dropping spawn requests in this sample.",
            evidence: baseEvidence + [
                DeveloperProfilerEvidenceItem(label: "Dropped",
                                              value: "\(particleDrops)",
                                              status: .warning),
                DeveloperProfilerEvidenceItem(label: "Live",
                                              value: particleSample.map {
                                                  "\($0.liveParticleCount)/\($0.liveParticleLimit)"
                                              } ?? "--",
                                              status: .nominal),
            ],
            action: "Open Particles to inspect capacity, spawn budgets, and event drops."
        )
    }

    return DeveloperProfilerBottleneckSummary(
        title: "Frame within budget",
        status: .nominal,
        primarySignal: "No active CPU, GPU, pacing, or particle pressure is dominant.",
        evidence: baseEvidence + [
            DeveloperProfilerEvidenceItem(label: "Encode",
                                          value: developerProfilerFormatNs(renderStats.cpuEncodeNS),
                                          status: developerProfilerFrameStatus(Double(renderStats.cpuEncodeNS) / 1_000_000)),
            DeveloperProfilerEvidenceItem(label: "Pacing",
                                          value: developerProfilerFormatMs(pacingMs),
                                          status: developerProfilerPacingStatus(pacingMs)),
        ],
        action: "Use the frame timeline to select an over-budget sample if hitching persists."
    )
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

private func developerProfilerCompactMs(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func developerProfilerFormatFPS(_ value: Double) -> String {
    value > 0 ? String(format: "%.0f", value) : "--"
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
