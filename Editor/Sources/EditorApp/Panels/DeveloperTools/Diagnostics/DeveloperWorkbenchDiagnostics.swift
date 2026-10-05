import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

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

func developerDiagnosticSeverityRank(_ severity: DeveloperDiagnosticSeverity) -> Int {
    switch severity {
    case .critical: 4
    case .warning: 3
    case .info: 2
    case .nominal: 1
    }
}
