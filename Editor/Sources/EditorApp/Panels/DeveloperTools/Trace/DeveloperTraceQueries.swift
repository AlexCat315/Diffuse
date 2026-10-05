import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

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

func developerTraceTrackLatestSignal(track: DeveloperTraceTrack,
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
