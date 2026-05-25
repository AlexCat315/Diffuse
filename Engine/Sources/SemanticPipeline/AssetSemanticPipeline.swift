import Foundation

public struct SemanticPipelineConfig: Sendable {
    /// Confidence floor for automatic commit when a single backend agrees.
    public var autoCommitThreshold: Float
    /// More conservative threshold when the only evidence is a vision backend.
    public var visionOnlyAutoThreshold: Float
    /// Top-1 vs top-2 gap below which proposals are considered conflicting.
    public var conflictMargin: Float

    public static let `default` = SemanticPipelineConfig(
        autoCommitThreshold: 0.85,
        visionOnlyAutoThreshold: 0.95,
        conflictMargin: 0.15
    )

    public init(autoCommitThreshold: Float,
                visionOnlyAutoThreshold: Float,
                conflictMargin: Float) {
        self.autoCommitThreshold = autoCommitThreshold
        self.visionOnlyAutoThreshold = visionOnlyAutoThreshold
        self.conflictMargin = conflictMargin
    }
}

/// Coordinates the full asset semantic annotation pass:
/// Structure → Geometry → Region → Backend analysis → Ambiguity scoring → Memory.
///
/// Backends are injected; the coordinator is pure data flow with no hidden state.
public struct AssetSemanticPipeline: Sendable {
    public let config: SemanticPipelineConfig
    private let backends: [any SemanticAnalyzerBackend]
    private let memory: (any SemanticMemoryStore)?

    public init(config: SemanticPipelineConfig = .default,
                backends: [any SemanticAnalyzerBackend] = [],
                memory: (any SemanticMemoryStore)? = nil) {
        self.config = config
        self.backends = backends
        self.memory = memory
    }

    // MARK: - Main entry point

    /// Runs the full pipeline and returns either auto-committed proposals or questions
    /// for the `MinimalConfirmationUI`.
    public func run(rawStructure: RawStructure,
                    signals: GeometrySignals) async -> AmbiguityDecision {
        let regionSet = buildRegions(rawStructure: rawStructure, signals: signals)
        let proposals = await collectProposals(regionSet: regionSet,
                                               rawStructure: rawStructure,
                                               signals: signals)
        return score(proposals: proposals)
    }

    /// Applies user confirmations from the UI: records accepted labels in memory
    /// and returns the final committed proposals ready to write to the `inferred` World layer.
    public func apply(confirmations: [SemanticConfirmation],
                      regions: CandidateRegionSet,
                      pendingProposals: [SemanticProposal]) async -> [SemanticProposal] {
        var committed: [SemanticProposal] = []
        let byRegion = Dictionary(grouping: pendingProposals, by: \.regionID)

        for confirmation in confirmations {
            guard let region = regions.regions.first(where: { $0.id == confirmation.regionID })
            else { continue }

            switch confirmation.outcome {
            case let .accepted(label):
                await memory?.record(regionID: confirmation.regionID,
                                     fingerprint: region.fingerprint,
                                     confirmation: confirmation)
                committed.append(SemanticProposal(
                    regionID: confirmation.regionID,
                    label: label,
                    confidence: 1.0,
                    source: "user_confirmed",
                    provenance: .confirmed
                ))
            case let .renamed(newLabel):
                await memory?.record(regionID: confirmation.regionID,
                                     fingerprint: region.fingerprint,
                                     confirmation: SemanticConfirmation(
                                         regionID: confirmation.regionID,
                                         outcome: .accepted(label: newLabel),
                                         confirmedBy: confirmation.confirmedBy
                                     ))
                committed.append(SemanticProposal(
                    regionID: confirmation.regionID,
                    label: newLabel,
                    confidence: 1.0,
                    source: "user_confirmed",
                    provenance: .confirmed
                ))
            case .rejected, .deferred:
                break
            }
        }
        return committed
    }

    // MARK: - Private

    private func buildRegions(rawStructure: RawStructure,
                               signals: GeometrySignals) -> CandidateRegionSet {
        var regions: [Region] = []

        // Structural regions: one per named node.
        for node in rawStructure.nodes {
            regions.append(Region(
                id: "region:\(node.id)",
                source: .structural,
                fingerprint: GeometryFingerprint()
            ))
        }

        // Geometric regions from connected components not covered by structural nodes.
        let structuralMeshIDs = Set(rawStructure.meshes.map(\.id))
        for component in signals.connectedComponents where !structuralMeshIDs.contains(component.meshID) {
            regions.append(Region(
                id: "region:cc:\(component.id)",
                source: .geometric,
                fingerprint: GeometryFingerprint()
            ))
        }

        return CandidateRegionSet(assetURI: rawStructure.assetURI, regions: regions)
    }

    private func collectProposals(regionSet: CandidateRegionSet,
                                  rawStructure: RawStructure,
                                  signals: GeometrySignals) async -> [SemanticProposal] {
        var all: [SemanticProposal] = []
        await withTaskGroup(of: [SemanticProposal].self) { group in
            for backend in backends {
                group.addTask {
                    await backend.analyze(regions: regionSet, rawStructure: rawStructure, signals: signals)
                }
            }
            for await batch in group { all.append(contentsOf: batch) }
        }
        return all
    }

    private func score(proposals: [SemanticProposal]) -> AmbiguityDecision {
        var autoCommit: [SemanticProposal] = []
        var questions: [AmbiguityQuestion] = []

        let byRegion = Dictionary(grouping: proposals, by: \.regionID)
        for (regionID, regionProposals) in byRegion.sorted(by: { $0.key < $1.key }) {
            let sorted = regionProposals.sorted { $0.confidence > $1.confidence }
            guard let top = sorted.first else { continue }

            let threshold: Float = top.source == "vision"
                ? config.visionOnlyAutoThreshold
                : config.autoCommitThreshold
            let hasConflict = sorted.count > 1
                && (sorted[0].confidence - sorted[1].confidence) < config.conflictMargin

            if !hasConflict && top.confidence >= threshold {
                autoCommit.append(top)
            } else {
                questions.append(AmbiguityQuestion(
                    regionID: regionID,
                    candidates: sorted.map {
                        AmbiguityQuestion.Candidate(label: $0.label,
                                                    confidence: $0.confidence,
                                                    source: $0.source)
                    },
                    suggestedDefault: top.label
                ))
            }
        }

        return questions.isEmpty ? .autoCommit(autoCommit) : .needsConfirmation(questions)
    }
}
