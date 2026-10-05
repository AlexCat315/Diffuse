import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

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
