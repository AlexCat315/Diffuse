import Foundation
import IntentRuntime

/// Maps committed SemanticProposals to WorldEvents for injection into the World inferred layer.
///
/// Usage:
/// ```swift
/// let events = SemanticWorldEventMapper().makeWorldEvents(from: proposals, targetRef: "scene:42")
/// await session.observe(events: events)
/// ```
public struct SemanticWorldEventMapper: Sendable {
    public init() {}

    /// Converts a list of committed proposals into `entityInferredUpdated` WorldEvents.
    /// The `targetRef` is the entity reference in the scene (e.g. `"scene:42"`).
    public func makeWorldEvents(from proposals: [SemanticProposal],
                                targetRef: String) -> [WorldEvent] {
        guard !proposals.isEmpty else { return [] }
        var events: [WorldEvent] = []

        // Split by source so we can set appropriate confidence and property names.
        let bySource = Dictionary(grouping: proposals, by: \.source)

        // semanticRole: highest-confidence proposal, biased toward confirmed/metadata sources.
        let ranked = proposals.sorted {
            if $0.provenance == .confirmed && $1.provenance != .confirmed { return true }
            if $0.source == "metadata" && $1.source != "metadata" { return true }
            return $0.confidence > $1.confidence
        }
        if let top = ranked.first {
            events.append(.entityInferredUpdated(
                ref: targetRef,
                property: "semanticRole",
                value: .string(top.label),
                confidence: Double(top.confidence),
                source: "semantic:\(top.source)"
            ))
        }

        // semanticParts: all structural/geometric region labels joined as a summary.
        let partProposals = proposals.filter {
            !$0.regionID.contains(":bone:") && !$0.regionID.contains(":mat:")
        }
        let uniquePartLabels = Array(Set(partProposals.map(\.label))).sorted()
        if uniquePartLabels.count > 1 {
            let avgConf = partProposals.map(\.confidence).reduce(0, +) / Float(partProposals.count)
            events.append(.entityInferredUpdated(
                ref: targetRef,
                property: "semanticParts",
                value: .string(uniquePartLabels.joined(separator: ", ")),
                confidence: Double(avgConf),
                source: "semantic:pipeline"
            ))
        }

        // rigParts: bone labels from RigBackend.
        let rigProposals = (bySource["rig"] ?? [])
        let rigLabels = Array(Set(rigProposals.map(\.label))).sorted()
        if !rigLabels.isEmpty {
            let avgConf = rigProposals.map(\.confidence).reduce(0, +) / Float(rigProposals.count)
            events.append(.entityInferredUpdated(
                ref: targetRef,
                property: "rigParts",
                value: .string(rigLabels.joined(separator: ", ")),
                confidence: Double(avgConf),
                source: "semantic:rig"
            ))
        }

        return events
    }
}
