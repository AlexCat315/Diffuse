import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

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

func developerTraceTrack(for scope: DeveloperDiagnosticScope) -> DeveloperTraceTrack {
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

func developerTraceEventPrecedes(_ lhs: DeveloperTraceEvent,
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
