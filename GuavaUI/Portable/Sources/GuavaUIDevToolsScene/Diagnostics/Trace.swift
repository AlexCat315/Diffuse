import Foundation
import GuavaUIScene
import GuavaUIAgentCore

public struct UITracePhase: Codable, Sendable {
    public let phase: String
    public let count: Int
    public let averageMs: Double
    public let p95Ms: Double
    public let maximumMs: Double
}

public struct UITraceCapture: Codable, Sendable {
    public let id: String
    public let durationMs: Double
    public let eventCount: Int
    public let dropped: Int
    public let phases: [UITracePhase]
}

public struct UITraceQuery: Codable, Sendable {
    public let capture: UITraceCapture
    public let events: UIDiagnosticPage<PerformanceTimeline.Event>
}

public struct UITracePhaseChange: Codable, Sendable {
    public let phase: String
    public let baseline: UITracePhase?
    public let candidate: UITracePhase?
    public let averageDeltaMs: Double?
    public let p95DeltaMs: Double?
}

public struct UITraceComparison: Codable, Sendable {
    public let baseline: UITraceCapture
    public let candidate: UITraceCapture
    public let changes: [UITracePhaseChange]
}

@MainActor
final class UITraceStore {
    private struct Record {
        let summary: UITraceCapture
        let events: [PerformanceTimeline.Event]
    }
    private var records: [Record] = []
    private var recording = false
    private var generation = 0

    func reset() { generation += 1; records.removeAll() }

    func capture(timeline: PerformanceTimeline, milliseconds: Int) async throws -> UITraceCapture {
        guard (50...5000).contains(milliseconds), !recording else {
            throw AgentError.invalidConfiguration("Capture duration must be 50–5000 ms; only one capture may run at a time.")
        }
        let epoch = generation
        recording = true
        defer { recording = false }
        return try await timeline.record {
            let after = timeline.latestSequence
            let start = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(milliseconds))
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            let events = timeline.events(after: after)
            let elapsed = start.duration(to: .now).components
            let duration = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            let phases = Dictionary(grouping: events, by: \.phase).map { name, spans in
                let values = spans.map(\.durationMs).sorted()
                return UITracePhase(phase: name, count: values.count,
                    averageMs: values.reduce(0, +) / Double(values.count),
                    p95Ms: values[Int((Double(values.count - 1) * 0.95).rounded(.up))], maximumMs: values.last ?? 0)
            }.sorted { $0.phase < $1.phase }
            let summary = UITraceCapture(id: UUID().uuidString, durationMs: duration, eventCount: events.count,
                dropped: Int(timeline.latestSequence - after) - events.count, phases: phases)
            if records.count == 8 { records.removeFirst() }
            records.append(Record(summary: summary, events: events))
            return summary
        }
    }

    private func record(id: String) throws -> Record {
        guard let record = records.first(where: { $0.summary.id == id }) else {
            throw AgentError.invalidConfiguration("Capture is missing or expired: \(id)")
        }
        return record
    }
    func query(id: String, offset: Int, limit: Int) throws -> UITraceQuery {
        let record = try record(id: id)
        return UITraceQuery(capture: record.summary, events: UIDiagnosticPage(record.events, offset: offset, limit: limit))
    }
    func compare(baselineID: String, candidateID: String) throws -> UITraceComparison {
        let baseline = try record(id: baselineID).summary, candidate = try record(id: candidateID).summary
        let phases = Set(baseline.phases.map(\.phase) + candidate.phases.map(\.phase)).sorted()
        let changes = phases.map { phase in
            let before = baseline.phases.first { $0.phase == phase }, after = candidate.phases.first { $0.phase == phase }
            return UITracePhaseChange(phase: phase, baseline: before, candidate: after,
                averageDeltaMs: before.flatMap { b in after.map { $0.averageMs - b.averageMs } },
                p95DeltaMs: before.flatMap { b in after.map { $0.p95Ms - b.p95Ms } })
        }
        return UITraceComparison(baseline: baseline, candidate: candidate, changes: changes)
    }
}
