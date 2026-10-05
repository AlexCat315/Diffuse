import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct ParticleDiagnosticsTabView: View {
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
