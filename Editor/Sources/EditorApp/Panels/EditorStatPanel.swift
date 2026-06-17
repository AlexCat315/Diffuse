import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend

struct DeveloperToolsPanel: View {
    let app: EditorApplication

    @State private var selectedTab: DeveloperToolTab = .performance

    var body: some View {
        StoreScope(app.store) { store in
            let timingRevision = store.frameTimingRevision
            let frameStats = store.state.frameStats
            let renderStats = app.currentRenderStats()

            TabView(selection: $selectedTab, tabs: [
                TabItem(L("Performance"), id: DeveloperToolTab.performance) {
                    PerformanceDiagnosticsView(stats: frameStats,
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
    case console
}

private struct PerformanceDiagnosticsView: View {
    let stats: EditorFrameStats
    let timingRevision: UInt64

    var body: some View {
        ScrollView(.vertical) {
            Row(alignment: .top, spacing: 12) {
                StatGroup(title: L("Frame")) {
                    StatRow(label: "FPS", value: formatFPS(stats.fps))
                    StatRow(label: "Frame", value: formatMs(stats.frameMs))
                    StatRow(label: "Sample", value: "#\(timingRevision)")
                    StatRow(label: "16.7ms Budget", value: stats.frameMs <= 16.7 ? "OK" : "MISS")
                    StatRow(label: "33.3ms Budget", value: stats.frameMs <= 33.3 ? "OK" : "MISS")
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

            Row(alignment: .top, spacing: 12) {
                StatGroup(title: "Budget") {
                    StatRow(label: "Target 60 FPS", value: budgetStatus(frameMs: stats.frameMs, targetMs: 16.7))
                    StatRow(label: "Target 30 FPS", value: budgetStatus(frameMs: stats.frameMs, targetMs: 33.3))
                    StatRow(label: "Headroom @60", value: formatSignedMs(16.7 - stats.frameMs))
                    StatRow(label: "Headroom @30", value: formatSignedMs(33.3 - stats.frameMs))
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Bottleneck") {
                    StatRow(label: "Likely", value: bottleneck(stats))
                    StatRow(label: "CPU Total", value: formatMs(cpuMs(stats)))
                    StatRow(label: "GPU Present", value: formatMs(stats.gpuPresentSeconds * 1000))
                    StatRow(label: "Frame", value: formatMs(stats.frameMs))
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
        Column(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
                .padding(horizontal: 8, vertical: 5)
                .frame(maxWidth: .infinity)
                .background(.surfaceVariant)

            Column(alignment: .leading, spacing: 0) {
                content
            }
            .padding(vertical: 4)
        }
        .border(Color(r: 1, g: 1, b: 1, a: 0.08), width: 1)
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

private func cpuMs(_ stats: EditorFrameStats) -> Double {
    (stats.inputSeconds
     + stats.simulationSeconds
     + stats.renderPrepareSeconds
     + stats.renderSubmitSeconds) * 1000
}

private func budgetStatus(frameMs: Double, targetMs: Double) -> String {
    guard frameMs > 0 else { return "--" }
    if frameMs <= targetMs { return "OK" }
    return "+\(formatMs(frameMs - targetMs))"
}

private func bottleneck(_ stats: EditorFrameStats) -> String {
    let cpu = cpuMs(stats)
    let gpu = stats.gpuPresentSeconds * 1000
    guard stats.frameMs > 0 else { return "--" }
    if cpu <= 0, gpu <= 0 { return "Frame pacing" }
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
