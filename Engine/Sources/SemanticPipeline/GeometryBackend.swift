import Foundation

/// Infers semantic category from shape features in `GeometrySignals`.
///
/// Proposals target the root structural region (whole asset) or individual connected
/// components. Confidence is intentionally modest (0.50–0.72) because geometric
/// heuristics are weaker than naming or metadata evidence — the arbitration layer
/// in `AssetSemanticPipeline` handles conflicts with other backends.
public struct GeometryBackend: SemanticAnalyzerBackend, Sendable {
    public let backendID = "geometry"

    public init() {}

    public func analyze(regions: CandidateRegionSet,
                        rawStructure: RawStructure,
                        signals: GeometrySignals) async -> [SemanticProposal] {
        guard !regions.regions.isEmpty else { return [] }
        var proposals: [SemanticProposal] = []

        // --- Root-level asset category ---
        let rootRegions = regions.regions.filter { $0.parentRegionID == nil && $0.source == .structural }
        guard let rootRegion = rootRegions.first else { return [] }

        let hasStrongSymmetry = signals.symmetryAxes.first(where: { $0.confidence > 0.60 }) != nil
        let protrusionCount = signals.protrusions.count
        let hasSupportPlane = !signals.supportPlanes.isEmpty
        let aabbCategory = aabbAspectRatioCategory(signals)

        // Character detection: bilateral symmetry + limb-like protrusions
        if hasStrongSymmetry && protrusionCount >= 4 {
            proposals.append(SemanticProposal(
                regionID: rootRegion.id,
                label: "character",
                confidence: 0.65,
                source: backendID,
                provenance: .geometric
            ))
        } else if hasStrongSymmetry && protrusionCount == 2 {
            proposals.append(SemanticProposal(
                regionID: rootRegion.id,
                label: "bipedal_prop",
                confidence: 0.55,
                source: backendID,
                provenance: .geometric
            ))
        }

        // Furniture detection: flat support plane + moderate height
        if hasSupportPlane && aabbCategory == .medium {
            proposals.append(SemanticProposal(
                regionID: rootRegion.id,
                label: "furniture",
                confidence: 0.60,
                source: backendID,
                provenance: .geometric
            ))
        }

        // Tall narrow asset: column, tree, or upright prop
        if aabbCategory == .tall {
            proposals.append(SemanticProposal(
                regionID: rootRegion.id,
                label: "upright_prop",
                confidence: 0.55,
                source: backendID,
                provenance: .geometric
            ))
        }

        // Very flat asset: decal, rug, floor panel
        if aabbCategory == .flat {
            proposals.append(SemanticProposal(
                regionID: rootRegion.id,
                label: "flat_surface",
                confidence: 0.58,
                source: backendID,
                provenance: .geometric
            ))
        }

        // Near-cubic compact prop with no distinguishing features
        if aabbCategory == .cubic && !hasStrongSymmetry && !hasSupportPlane {
            proposals.append(SemanticProposal(
                regionID: rootRegion.id,
                label: "prop",
                confidence: 0.50,
                source: backendID,
                provenance: .geometric
            ))
        }

        // --- Per-component protrusion labelling ---
        if protrusionCount > 0 {
            for (i, protrusion) in signals.protrusions.enumerated() {
                let regionID = "region:protrusion:\(protrusion.id)"
                let aspectRatio = protrusion.length / max(protrusion.baseRadius, 0.001)
                let label: String
                if aspectRatio > 4 { label = "limb" }
                else if aspectRatio > 2 { label = "appendage" }
                else { label = "protrusion" }
                proposals.append(SemanticProposal(
                    regionID: regionID,
                    label: label,
                    confidence: 0.60 - Float(i) * 0.02,
                    source: backendID,
                    provenance: .geometric
                ))
            }
        }

        return proposals
    }

    // MARK: - Private

    private enum AABBCategory { case tall, flat, cubic, medium }

    private func aabbAspectRatioCategory(_ signals: GeometrySignals) -> AABBCategory {
        guard !signals.connectedComponents.isEmpty else { return .medium }

        var minX = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude

        for cc in signals.connectedComponents {
            minX = min(minX, cc.bounds.min.x); maxX = max(maxX, cc.bounds.max.x)
            minY = min(minY, cc.bounds.min.y); maxY = max(maxY, cc.bounds.max.y)
            minZ = min(minZ, cc.bounds.min.z); maxZ = max(maxZ, cc.bounds.max.z)
        }

        let height = maxY - minY
        let width  = max(maxX - minX, maxZ - minZ)
        guard width > 0.001 else { return .medium }
        let ar = height / width

        switch ar {
        case 3.0...:        return .tall
        case ..<0.20:       return .flat
        case 0.70...1.40:   return .cubic
        default:            return .medium
        }
    }
}

// MARK: - Pipeline standard configuration

extension AssetSemanticPipeline {
    /// Returns a pipeline configured with all built-in backends: name heuristic,
    /// rig, metadata, and geometry. Pass `memory` to enable cross-session recall.
    public static func standard(memory: (any SemanticMemoryStore)? = nil) -> AssetSemanticPipeline {
        AssetSemanticPipeline(
            config: .default,
            backends: [
                NameHeuristicBackend(),
                RigBackend(),
                MetadataBackend(),
                GeometryBackend(),
            ],
            memory: memory
        )
    }
}
