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
            let renderStats = app.currentRenderStats()
            let particleStats = app.currentParticleFrameStats()
            let particleEventReport = app.currentParticleSimulationEventApplyReport()
            let particleScalability = app.currentParticleScalabilityState()
            let particleRenderSummary = app.currentRenderScene().particleSummary

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
                TabItem("Particles", id: DeveloperToolTab.particles) {
                    ParticleDiagnosticsView(stats: particleStats,
                                            eventReport: particleEventReport,
                                            scalability: particleScalability,
                                            renderSummary: particleRenderSummary,
                                            renderStats: renderStats)
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

private struct PerformanceDiagnosticsView: View {
    let stats: EditorFrameStats
    let timingRevision: UInt64

    var body: some View {
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

private struct ParticleDiagnosticsView: View {
    let stats: ParticleFrameStatsResource
    let eventReport: ParticleSimulationEventApplyReport
    let scalability: ParticleScalabilityStateResource
    let renderSummary: ParticleRenderSummary
    let renderStats: RenderFrameStats

    var body: some View {
        ScrollView(.vertical) {
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
                    StatRow(label: "Total", value: "\(stats.spawnedParticleCount)")
                    StatRow(label: "Continuous", value: "\(stats.continuousSpawnedCount)")
                    StatRow(label: "Burst", value: "\(stats.burstSpawnedCount)")
                    StatRow(label: "Distance", value: "\(stats.distanceSpawnedCount)")
                    StatRow(label: "Sub-Emitter", value: "\(stats.subEmitterSpawnedCount)")
                    StatRow(label: "Capacity Drops", value: "\(stats.capacityLimitedSpawnCount)")
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Lifecycle") {
                    StatRow(label: "Expired", value: "\(stats.expiredParticleCount)")
                    StatRow(label: "Collisions", value: "\(stats.collisionCount)")
                    StatRow(label: "Live / Config", value: formatPercent(stats.liveParticleCount,
                                                                          stats.maxParticleCount))
                    StatRow(label: "Live / Effective", value: formatPercent(stats.liveParticleCount,
                                                                             stats.liveParticleLimit))
                    StatRow(label: "Drop Rate", value: formatPercent(stats.capacityLimitedSpawnCount,
                                                                      stats.spawnedParticleCount
                                                                        + stats.capacityLimitedSpawnCount))
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
                    StatRow(label: "Spawn Pressure", value: stats.capacityLimitedSpawnCount > 0 ? "YES" : "NO")
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
                    StatRow(label: "Sub-Emitter Spawns", value: "\(eventReport.subEmitterSpawnedCount)")
                    StatRow(label: "Capacity Drops", value: "\(eventReport.capacityLimitedSpawnCount)")
                    StatRow(label: "Missing Emitters", value: "\(eventReport.missingEmitterCount)")
                    StatRow(label: "Empty Buckets", value: "\(eventReport.emptyEventEmitterCount)")
                }
                .flex(1, shrink: 1)

                StatGroup(title: "Render Batches") {
                    StatRow(label: "Submitted", value: "\(renderSummary.particleCount)")
                    StatRow(label: "Batches", value: "\(renderSummary.batchCount)")
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

private func formatPercent(_ numerator: Int, _ denominator: Int) -> String {
    guard denominator > 0 else { return "--" }
    let percent = Double(numerator) / Double(denominator) * 100
    if percent < 10 { return String(format: "%.1f%%", percent) }
    return String(format: "%.0f%%", percent)
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
