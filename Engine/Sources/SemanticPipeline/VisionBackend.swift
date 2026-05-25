import Foundation
import PerceptionRuntime

/// Uses the Apple Vision image classifier (via `AppleVisionPerceptionWorker`) to produce
/// top-level semantic category proposals from a preview image of the asset.
///
/// Requires `rawStructure.previewImagePath` to be set; returns an empty array when absent
/// or when running on a platform without Vision framework support.
public struct VisionBackend: SemanticAnalyzerBackend, Sendable {
    public let backendID = "vision"

    private let maxResults: Int
    private let confidenceThreshold: Float

    public init(maxResults: Int = 3, confidenceThreshold: Float = 0.40) {
        self.maxResults = maxResults
        self.confidenceThreshold = confidenceThreshold
    }

    public func analyze(regions: CandidateRegionSet,
                        rawStructure: RawStructure,
                        signals: GeometrySignals) async -> [SemanticProposal] {
        guard let imagePath = rawStructure.previewImagePath,
              !imagePath.isEmpty
        else { return [] }

        let imageURL = imagePath.hasPrefix("file://")
            ? URL(string: imagePath) ?? URL(fileURLWithPath: String(imagePath.dropFirst(7)))
            : URL(fileURLWithPath: imagePath)

        guard FileManager.default.fileExists(atPath: imageURL.path) else { return [] }

        let worker = AppleVisionPerceptionWorker()
        let result: PerceptionResult
        do {
            result = try await worker.analyzeImageAsync(at: imageURL, maxResults: maxResults)
        } catch {
            return []
        }

        // Map the top classification observations to proposals on all root-level regions.
        let rootRegions = regions.regions.filter {
            $0.source == .structural && $0.parentRegionID == nil
        }
        guard !rootRegions.isEmpty else { return [] }

        var proposals: [SemanticProposal] = []
        for observation in result.observations {
            guard case let .classification(obs) = observation,
                  let candidate = obs.semanticCandidates.first,
                  Float(candidate.confidence) >= confidenceThreshold
            else { continue }

            for region in rootRegions {
                proposals.append(SemanticProposal(
                    regionID: region.id,
                    label: candidate.label,
                    confidence: Float(candidate.confidence) * 0.80,
                    source: backendID,
                    provenance: .structural
                ))
            }
        }
        return proposals
    }
}
