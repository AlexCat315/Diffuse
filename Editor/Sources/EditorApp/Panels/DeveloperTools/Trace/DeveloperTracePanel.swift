import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend

struct DeveloperTraceWorkbenchView: View {
    let liveTrace: DeveloperTraceSnapshot
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

    @State private var frozenTrace: DeveloperTraceSnapshot?
    @State private var selectedEventID: String?
    @State private var selectedSampleIndex: UInt64?
    @State private var isTimelineExpanded = false
    @State private var query = ""
    @State private var selectedTrack: DeveloperTraceTrack?
    @State private var severityFilter: DeveloperTraceSeverityFilter = .all
    @State private var sortOrder: DeveloperTraceEventSortOrder = .newest

    var body: some View {
        let trace = frozenTrace ?? liveTrace
        let visibleEvents = developerTraceVisibleEvents(trace: trace,
                                                        query: query,
                                                        trackFilter: selectedTrack,
                                                        severityFilter: severityFilter,
                                                        sortOrder: sortOrder)
        let activeEvent = visibleEvents.first { $0.id == selectedEventID } ?? visibleEvents.first
        let sampleIndex = activeEvent?.sampleIndex ?? selectedSampleIndex ?? trace.samples.last?.sampleIndex
        let selectedSample = trace.samples.first { $0.sampleIndex == sampleIndex }
        let summary = makeDeveloperTraceInvestigationSummary(events: visibleEvents)

        Column(alignment: .leading, spacing: 0) {
            DeveloperTraceToolbar(trace: trace,
                                  summary: summary,
                                  timelineExpanded: isTimelineExpanded,
                                  onPause: { freeze(liveTrace, mode: .paused) },
                                  onCapture: { freeze(liveTrace, mode: .captured) },
                                  onResume: { frozenTrace = nil },
                                  onToggleTimeline: { isTimelineExpanded.toggle() })
                .padding(horizontal: 12, vertical: 8)
            Divider()

            DeveloperTraceFilterBar(query: $query,
                                    selectedTrack: $selectedTrack,
                                    severityFilter: $severityFilter,
                                    sortOrder: $sortOrder,
                                    onClear: clearFilters)
                .padding(horizontal: 8, vertical: 5)

            if isTimelineExpanded {
                Divider()
                DeveloperTraceTimeline(trace: trace,
                                       selectedSampleIndex: sampleIndex,
                                       onSelectSample: { selectSample($0, trace: trace, events: visibleEvents) })
                    .padding(horizontal: 10, vertical: 6)
            }
            Divider()

            Row(alignment: .top, spacing: 0) {
                DeveloperTraceEventList(events: visibleEvents,
                                        selectedEventID: activeEvent?.id,
                                        searchIsActive: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                        onSelect: { selectedEventID = $0.id })
                    .frame(minWidth: 260, maxWidth: 390)

                Divider(axis: .vertical)
                    .frame(width: 1)

                DeveloperTraceEventDetails(trace: trace,
                                           event: activeEvent,
                                           sample: selectedSample,
                                           events: visibleEvents,
                                           onSelectEvent: { selectedEventID = $0 },
                                           onSelectSample: { selectSample($0, trace: trace, events: visibleEvents) },
                                           onOpenTarget: onOpenTarget)
                    .flex(1, shrink: 1)
            }
            .flex(1, shrink: 1)
        }
        .background(.surface)
    }

    private func freeze(_ trace: DeveloperTraceSnapshot, mode: DeveloperTraceMode) {
        frozenTrace = trace.withMode(mode)
        selectedSampleIndex = trace.samples.last?.sampleIndex
    }

    private func selectSample(_ sampleIndex: UInt64,
                              trace: DeveloperTraceSnapshot,
                              events: [DeveloperTraceEvent]) {
        selectedSampleIndex = sampleIndex
        selectedEventID = events.first { $0.sampleIndex == sampleIndex }?.id
            ?? trace.events.first { $0.sampleIndex == sampleIndex }?.id
    }

    private func clearFilters() {
        query = ""
        selectedTrack = nil
        severityFilter = .all
        sortOrder = .newest
    }
}

private struct DeveloperTraceToolbar: View {
    let trace: DeveloperTraceSnapshot
    let summary: DeveloperTraceInvestigationSummary
    let timelineExpanded: Bool
    let onPause: () -> Void
    let onCapture: () -> Void
    let onResume: () -> Void
    let onToggleTimeline: () -> Void

    var body: some View {
        Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 7) {
            DeveloperTraceModePill(mode: trace.mode)
            Column(alignment: .leading, spacing: 2) {
                Text(L("Trace Workbench"))
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text(trace.samples.isEmpty ? L("Waiting for frame samples") : developerTraceRange(trace.samples))
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .flex(1, shrink: 1, basis: 125)

            DeveloperTraceMetric(label: L("Events"), value: "\(summary.visibleEventCount)", severity: .nominal)
            DeveloperTraceMetric(label: L("Errors"), value: "\(summary.criticalCount)", severity: summary.criticalCount > 0 ? .critical : .nominal)
            DeveloperTraceMetric(label: L("Warnings"), value: "\(summary.warningCount)", severity: summary.warningCount > 0 ? .warning : .nominal)

            if trace.mode == .live {
                Button(L("Pause"), action: onPause).buttonStyle(.secondary)
            } else {
                Button(L("Resume Live"), action: onResume).buttonStyle(.secondary)
            }
            Button(L("Capture"), action: onCapture)
                .buttonStyle(.secondary)
            Button(L(timelineExpanded ? "Hide Timeline" : "Show Timeline"), action: onToggleTimeline)
                .buttonStyle(.secondary)
        }
    }
}

private struct DeveloperTraceModePill: View {
    let mode: DeveloperTraceMode

    private var label: String {
        switch mode {
        case .live: L("LIVE")
        case .paused: L("PAUSED")
        case .captured: L("CAPTURED")
        }
    }

    private var color: SemanticColorRef {
        switch mode {
        case .live: .success
        case .paused: .warning
        case .captured: .accent
        }
    }

    var body: some View {
        Row(alignment: .center, spacing: 5) {
            Box { EmptyView() }
                .frame(width: 6, height: 6)
                .background(color)
                .cornerRadius(3)
            Text(label).font(.mono).foregroundColor(.onSurface)
        }
        .padding(horizontal: 8, vertical: 6)
        .background(.surfaceSunken)
        .border(color, width: 1)
    }
}

private struct DeveloperTraceMetric: View {
    let label: String
    let value: String
    let severity: DeveloperDiagnosticSeverity

    var body: some View {
        Column(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundColor(.onSurfaceMuted)
            Text(value).font(.mono).foregroundColor(developerTraceColor(severity))
        }
        .padding(horizontal: 8, vertical: 5)
        .background(.surfaceSunken)
        .border(severity == .nominal ? .divider : developerTraceColor(severity), width: 1)
    }
}

private struct DeveloperTraceFilterBar: View {
    let query: Binding<String>
    let selectedTrack: Binding<DeveloperTraceTrack?>
    let severityFilter: Binding<DeveloperTraceSeverityFilter>
    let sortOrder: Binding<DeveloperTraceEventSortOrder>
    let onClear: () -> Void

    var body: some View {
        Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 4) {
            TextField(L("Search trace events"), text: query, size: .small, clearable: true)
                .frame(width: 168)
            Button(L("Clear Filters"), action: onClear).buttonStyle(.secondary)
            DeveloperTraceFilterChip(label: L("All Tracks"), isSelected: selectedTrack.wrappedValue == nil) {
                selectedTrack.wrappedValue = nil
            }
            for track in DeveloperTraceTrack.allCases {
                DeveloperTraceFilterChip(label: L(track.rawValue), isSelected: selectedTrack.wrappedValue == track) {
                    selectedTrack.wrappedValue = track
                }
            }
            for filter in DeveloperTraceSeverityFilter.allCases {
                DeveloperTraceFilterChip(label: L(filter.rawValue), isSelected: severityFilter.wrappedValue == filter) {
                    severityFilter.wrappedValue = filter
                }
            }
            Button {
                sortOrder.wrappedValue = developerTraceNextSortOrder(sortOrder.wrappedValue)
            } label: {
                Text(String(format: L("Sort: %@"), L(sortOrder.wrappedValue.rawValue)), lineLimit: 1)
            }
            .buttonStyle(.secondary)
        }
    }
}

private struct DeveloperTraceFilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(isSelected: isSelected, action: action) {
            Text(label, lineLimit: 1)
        }
        .buttonStyle(ToggleButtonStyle(minWidth: 42, height: 22))
    }
}

private struct DeveloperTraceTimeline: View {
    let trace: DeveloperTraceSnapshot
    let selectedSampleIndex: UInt64?
    let onSelectSample: (UInt64) -> Void

    private var samples: [DeveloperTraceSample] { Array(trace.samples.suffix(60)) }

    var body: some View {
        let eventsBySample = Dictionary(grouping: trace.events, by: \.sampleIndex)
        Column(alignment: .leading, spacing: 2) {
            Row(alignment: .center, spacing: 8) {
                Text(L("Frame Timeline")).font(.bodyStrong).foregroundColor(.onSurface)
                Text(trace.samples.isEmpty ? L("No samples") : developerTraceRange(samples))
                    .font(.caption).foregroundColor(.onSurfaceMuted)
                Spacer(minLength: 0)
                Text(L("Select a cell to inspect its sample"))
                    .font(.caption).foregroundColor(.onSurfaceMuted)
            }
            if samples.isEmpty {
                Text(L("Frame samples appear as the editor runs."))
                    .font(.caption).foregroundColor(.onSurfaceMuted)
                    .padding(vertical: 6)
            } else {
                for track in DeveloperTraceTrack.allCases {
                    DeveloperTraceTimelineTrack(samples: samples,
                                                eventsBySample: eventsBySample,
                                                track: track,
                                                selectedSampleIndex: selectedSampleIndex,
                                                onSelectSample: onSelectSample)
                }
            }
        }
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperTraceTimelineTrack: View {
    let samples: [DeveloperTraceSample]
    let eventsBySample: [UInt64: [DeveloperTraceEvent]]
    let track: DeveloperTraceTrack
    let selectedSampleIndex: UInt64?
    let onSelectSample: (UInt64) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 4) {
            Text(L(track.rawValue))
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: 86)
            Box(direction: .row, alignItems: .center, spacing: 2) {
                for sample in samples {
                    DeveloperTraceTimelineCell(sample: sample,
                                               track: track,
                                               events: eventsBySample[sample.sampleIndex, default: []].filter { $0.track == track },
                                               isSelected: selectedSampleIndex == sample.sampleIndex,
                                               onSelect: { onSelectSample(sample.sampleIndex) })
                }
            }
            .flex(1, shrink: 1)
        }
    }
}

private struct DeveloperTraceTimelineCell: View {
    let sample: DeveloperTraceSample
    let track: DeveloperTraceTrack
    let events: [DeveloperTraceEvent]
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let severity = developerTraceSampleSeverity(track: track, sample: sample, events: events)
        Button(action: onSelect) {
            Box {
                Text(events.isEmpty ? "·" : developerTraceGlyph(severity))
                    .font(.caption)
                    .foregroundColor(events.isEmpty ? .onSurfaceMuted : developerTraceColor(severity))
            }
            .frame(width: 9, height: 13)
            .background(isSelected ? .accent.opacity(0.2) : developerTraceCellColor(track: track, sample: sample, severity: severity, hasEvents: !events.isEmpty))
            .border(isSelected ? .accent : (events.isEmpty ? .divider : developerTraceColor(severity)), width: isSelected ? 1 : (events.isEmpty ? 0 : 1))
        }
        .buttonStyle(.plain)
    }
}

private struct DeveloperTraceEventList: View {
    let events: [DeveloperTraceEvent]
    let selectedEventID: String?
    let searchIsActive: Bool
    let onSelect: (DeveloperTraceEvent) -> Void

    var body: some View {
        Column(alignment: .leading, spacing: 0) {
            Row(alignment: .center, spacing: 6) {
                Text(L("Events")).font(.bodyStrong).foregroundColor(.onSurface)
                Text("\(events.count)").font(.mono).foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 10, vertical: 8)
            .background(.surfaceFloating)
            Divider()
            ScrollView(.vertical, scrollbarGutter: .stable) {
                Column(alignment: .leading, spacing: 4) {
                    if events.isEmpty {
                        Text(searchIsActive ? L("No events match these filters.") : L("No diagnostic events in this trace window."))
                            .font(.caption).foregroundColor(.onSurfaceMuted)
                            .padding(horizontal: 10, vertical: 10)
                    } else {
                        for event in events {
                            DeveloperTraceEventRow(event: event,
                                                   isSelected: event.id == selectedEventID,
                                                   onSelect: { onSelect(event) })
                        }
                    }
                }
                .framePercent(width: 100, minWidth: 0)
                .padding(horizontal: 6, vertical: 6)
            }
            .background(.surfaceSunken)
        }
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperTraceEventRow: View {
    let event: DeveloperTraceEvent
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Row(alignment: .top, spacing: 7) {
                Text(developerTraceGlyph(event.severity))
                    .font(.mono)
                    .foregroundColor(developerTraceColor(event.severity))
                    .frame(width: 14)
                Column(alignment: .leading, spacing: 3) {
                    Row(alignment: .center, spacing: 5) {
                        Text(L(event.track.rawValue)).font(.caption).foregroundColor(.onSurfaceMuted)
                        Spacer(minLength: 0)
                        Text("#\(event.sampleIndex)").font(.mono).foregroundColor(.onSurfaceMuted)
                    }
                    Text(event.title).lineLimit(2).font(.bodyStrong).foregroundColor(.onSurface)
                    Text(event.primarySignal).lineLimit(2).font(.caption).foregroundColor(developerTraceColor(event.severity))
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 7, vertical: 7)
            .background(isSelected ? .accent.opacity(0.12) : .surface)
            .border(isSelected ? .accent : developerTraceColor(event.severity), width: 1)
        }
        .buttonStyle(.plain)
        .framePercent(width: 100, minWidth: 0)
    }
}

private struct DeveloperTraceEventDetails: View {
    let trace: DeveloperTraceSnapshot
    let event: DeveloperTraceEvent?
    let sample: DeveloperTraceSample?
    let events: [DeveloperTraceEvent]
    let onSelectEvent: (String?) -> Void
    let onSelectSample: (UInt64) -> Void
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

    var body: some View {
        ScrollView(.vertical, scrollbarGutter: .stable) {
            Column(alignment: .leading, spacing: 9) {
                if let event {
                    DeveloperTraceEventDetailCard(event: event,
                                                   events: events,
                                                   onSelectEvent: onSelectEvent,
                                                   onOpenTarget: onOpenTarget)
                } else {
                    Column(alignment: .leading, spacing: 5) {
                        Text(L("No event selected")).font(.bodyStrong).foregroundColor(.onSurface)
                        Text(L("Select a timeline cell or event to inspect its evidence and related frame."))
                            .font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                    .padding(10)
                    .background(.surfaceFloating)
                }
                if let sample {
                    DeveloperTraceSampleCard(trace: trace, sample: sample, onSelectSample: onSelectSample)
                }
            }
            .framePercent(width: 100, minWidth: 0)
            .padding(10)
        }
        .frame(minWidth: 0)
    }
}

private struct DeveloperTraceEventDetailCard: View {
    let event: DeveloperTraceEvent
    let events: [DeveloperTraceEvent]
    let onSelectEvent: (String?) -> Void
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

    var body: some View {
        Column(alignment: .leading, spacing: 8) {
            Row(alignment: .center, spacing: 6) {
                Text(L(event.severity.rawValue)).font(.caption).foregroundColor(developerTraceColor(event.severity))
                Text(L(event.track.rawValue)).font(.caption).foregroundColor(.onSurfaceMuted)
                Spacer(minLength: 0)
                Text("#\(event.sampleIndex)").font(.mono).foregroundColor(.onSurfaceMuted)
            }
            Text(event.title).font(.bodyStrong).foregroundColor(.onSurface)
            Text(event.primarySignal).font(.bodyStrong).foregroundColor(developerTraceColor(event.severity))
            if !event.evidence.isEmpty {
                Divider()
                Text(L("Evidence")).font(.bodyStrong).foregroundColor(.onSurface)
                Text(event.evidence.map { "•  \($0)" }.joined(separator: "\n"))
                    .lineLimit(8).font(.caption).foregroundColor(.onSurfaceMuted)
            }
            Divider()
            Text(L("Recommended action")).font(.bodyStrong).foregroundColor(.onSurface)
            Text(event.recommendation).lineLimit(5).font(.caption).foregroundColor(.onSurfaceMuted)
            Row(alignment: .center, spacing: 6) {
                Button(L("Previous Event")) {
                    onSelectEvent(developerTraceAdjacentEventID(events: events,
                                                                selectedEventID: event.id,
                                                                direction: .previous))
                }
                .buttonStyle(.secondary)
                Button(L("Next Event")) {
                    onSelectEvent(developerTraceAdjacentEventID(events: events,
                                                                selectedEventID: event.id,
                                                                direction: .next))
                }
                .buttonStyle(.secondary)
                Spacer(minLength: 0)
                Button(L(event.target.label)) { onOpenTarget(event.target) }
                    .buttonStyle(.primary)
            }
        }
        .padding(10)
        .background(.surfaceFloating)
        .border(developerTraceColor(event.severity), width: 1)
    }
}

private struct DeveloperTraceSampleCard: View {
    let trace: DeveloperTraceSnapshot
    let sample: DeveloperTraceSample
    let onSelectSample: (UInt64) -> Void

    var body: some View {
        let investigation = makeDeveloperTraceSampleInvestigation(trace: trace, sampleIndex: sample.sampleIndex)
        let context = makeDeveloperTraceSampleContext(trace: trace, sampleIndex: sample.sampleIndex)
        Column(alignment: .leading, spacing: 7) {
            Row(alignment: .center, spacing: 6) {
                Text(L("Sample Context")).font(.bodyStrong).foregroundColor(.onSurface)
                Spacer(minLength: 0)
                Text("#\(sample.sampleIndex) · frame \(sample.frameIndex)")
                    .font(.mono).foregroundColor(.onSurfaceMuted)
            }
            Row(alignment: .center, spacing: 5) {
                DeveloperTraceSampleMetric(label: L("Work"), value: developerTraceFormatMs(sample.frameStats.workMs), severity: developerTraceSampleSeverity(track: .frame, sample: sample, events: []))
                DeveloperTraceSampleMetric(label: L("CPU"), value: developerTraceFormatMs(developerTraceCPUms(sample.frameStats)), severity: developerTraceSampleSeverity(track: .cpu, sample: sample, events: []))
                DeveloperTraceSampleMetric(label: L("GPU"), value: developerTraceFormatMs(sample.frameStats.gpuPresentSeconds * 1000), severity: developerTraceSampleSeverity(track: .gpuPresent, sample: sample, events: []))
                DeveloperTraceSampleMetric(label: L("Particles"), value: "\(sample.particleLiveCount)", severity: sample.particleDroppedCount > 0 ? .warning : .nominal)
            }
            Text(String(format: L("%lld events · %lld errors · %lld warnings"),
                        Int64(investigation.eventCount), Int64(investigation.criticalCount), Int64(investigation.warningCount)))
                .font(.caption).foregroundColor(.onSurfaceMuted)
            if let context {
                Row(alignment: .center, spacing: 5) {
                    if let previous = context.previous {
                        DeveloperTraceContextButton(row: previous, onSelect: onSelectSample)
                    }
                    DeveloperTraceContextButton(row: context.selected, onSelect: onSelectSample)
                    if let next = context.next {
                        DeveloperTraceContextButton(row: next, onSelect: onSelectSample)
                    }
                }
            }
            if sample.particleDroppedCount > 0 {
                Text(String(format: L("%lld particle spawns were dropped in this sample."), Int64(sample.particleDroppedCount)))
                    .font(.caption).foregroundColor(.warning)
            }
        }
        .padding(10)
        .background(.surfaceFloating)
        .border(.divider, width: 1)
    }
}

private struct DeveloperTraceSampleMetric: View {
    let label: String
    let value: String
    let severity: DeveloperDiagnosticSeverity

    var body: some View {
        Column(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundColor(.onSurfaceMuted)
            Text(value).font(.mono).foregroundColor(developerTraceColor(severity))
        }
        .flex(1, shrink: 1)
        .padding(horizontal: 6, vertical: 5)
        .background(.surfaceSunken)
    }
}

private struct DeveloperTraceContextButton: View {
    let row: DeveloperTraceSampleContextRow
    let onSelect: (UInt64) -> Void

    var body: some View {
        Button(action: { onSelect(row.sampleIndex) }) {
            Column(alignment: .leading, spacing: 2) {
                Text(L(row.position.rawValue)).font(.caption).foregroundColor(.onSurfaceMuted)
                Text("#\(row.sampleIndex) · \(developerTraceFormatMs(row.workMs))")
                    .font(.mono).foregroundColor(developerTraceColor(row.highestSeverity))
                Text(String(format: L("%lld events · Δ %@"), Int64(row.eventCount), developerTraceFormatMs(row.workDeltaFromSelectedMs)))
                    .lineLimit(1).font(.caption).foregroundColor(.onSurfaceMuted)
            }
            .padding(6)
            .background(row.position == .selected ? .accent.opacity(0.12) : .surfaceSunken)
            .border(row.position == .selected ? .accent : .divider, width: 1)
        }
        .buttonStyle(.plain)
        .flex(1, shrink: 1)
    }
}

private func developerTraceRange(_ samples: [DeveloperTraceSample]) -> String {
    guard let first = samples.first, let last = samples.last else { return L("No samples") }
    return "#\(first.sampleIndex)–#\(last.sampleIndex) · \(samples.count) \(L("samples"))"
}

private func developerTraceNextSortOrder(_ order: DeveloperTraceEventSortOrder) -> DeveloperTraceEventSortOrder {
    switch order {
    case .newest: .severity
    case .severity: .track
    case .track: .newest
    }
}

private func developerTraceColor(_ severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    switch severity {
    case .critical: .error
    case .warning: .warning
    case .info: .info
    case .nominal: .onSurfaceMuted
    }
}

private func developerTraceGlyph(_ severity: DeveloperDiagnosticSeverity) -> String {
    switch severity {
    case .critical: "!"
    case .warning: "▲"
    case .info: "i"
    case .nominal: "·"
    }
}

private func developerTraceSampleSeverity(track: DeveloperTraceTrack,
                                          sample: DeveloperTraceSample,
                                          events: [DeveloperTraceEvent]) -> DeveloperDiagnosticSeverity {
    if let event = events.max(by: { developerTraceSeverityRankForUI($0.severity) < developerTraceSeverityRankForUI($1.severity) }) {
        return event.severity
    }
    switch track {
    case .frame:
        return sample.frameStats.workMs > 33.3 ? .critical : (sample.frameStats.workMs > 16.7 ? .warning : .nominal)
    case .cpu:
        return developerTraceCPUms(sample.frameStats) > 20 ? .critical : (developerTraceCPUms(sample.frameStats) > 10 ? .warning : .nominal)
    case .gpuPresent:
        let value = sample.frameStats.gpuPresentSeconds * 1000
        return value > 20 ? .critical : (value > 10 ? .warning : .nominal)
    case .renderPass:
        return .nominal
    case .particles:
        return sample.particleDroppedCount > 0 ? .warning : .nominal
    case .console:
        return sample.consoleSeverity ?? .nominal
    }
}

private func developerTraceCellColor(track: DeveloperTraceTrack,
                                     sample: DeveloperTraceSample,
                                     severity: DeveloperDiagnosticSeverity,
                                     hasEvents: Bool) -> SemanticColorRef {
    guard !hasEvents else { return .surfaceFloating }
    switch track {
    case .frame: return sample.frameStats.workMs > 8 ? .surfaceFloating : .surfaceSunken
    case .cpu: return developerTraceCPUms(sample.frameStats) > 5 ? .surfaceFloating : .surfaceSunken
    case .gpuPresent: return sample.frameStats.gpuPresentSeconds * 1000 > 5 ? .surfaceFloating : .surfaceSunken
    case .renderPass, .particles, .console: return severity == .nominal ? .surfaceSunken : .surfaceFloating
    }
}

private func developerTraceFormatMs(_ value: Double) -> String {
    let magnitude = abs(value)
    let number = magnitude < 10
        ? String(format: "%.2f", value)
        : String(format: "%.1f", value)
    return "\(number)ms"
}

private func developerTraceCPUms(_ stats: EditorFrameStats) -> Double {
    stats.cpuWorkSeconds * 1000
}

private func developerTraceSeverityRankForUI(_ severity: DeveloperDiagnosticSeverity) -> Int {
    switch severity {
    case .critical: 4
    case .warning: 3
    case .info: 2
    case .nominal: 1
    }
}
