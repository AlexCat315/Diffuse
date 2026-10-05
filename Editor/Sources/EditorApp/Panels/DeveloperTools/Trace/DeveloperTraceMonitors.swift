import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

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
