import Foundation

/// Pluggable backend for assigning semantic labels to candidate regions.
/// Multiple backends run in parallel; their proposals are arbitrated by `AmbiguityScorer`.
public protocol SemanticAnalyzerBackend: Sendable {
    var backendID: String { get }
    func analyze(regions: CandidateRegionSet,
                 rawStructure: RawStructure,
                 signals: GeometrySignals) async -> [SemanticProposal]
}

/// Matches common DCC naming conventions (e.g. "ear_L" → "ear", "glass_mat" → "glass_panel").
public struct NameHeuristicBackend: SemanticAnalyzerBackend, Sendable {
    public let backendID = "name_heuristic"

    public init() {}

    public func analyze(regions: CandidateRegionSet,
                        rawStructure: RawStructure,
                        signals: GeometrySignals) async -> [SemanticProposal] {
        var proposals: [SemanticProposal] = []
        for region in regions.regions where region.source == .structural {
            let nodeID = String(region.id.dropFirst("region:".count))
            guard let node = rawStructure.nodes.first(where: { $0.id == nodeID }),
                  !node.name.isEmpty
            else { continue }

            if let label = inferLabel(from: node.name) {
                proposals.append(SemanticProposal(
                    regionID: region.id,
                    label: label,
                    confidence: 0.75,
                    source: backendID,
                    provenance: .structural
                ))
            }
        }
        for slot in rawStructure.materialSlots where !slot.name.isEmpty {
            if let label = inferLabel(from: slot.name) {
                // material-slot proposals attach to submesh regions if they exist
                proposals.append(SemanticProposal(
                    regionID: "region:mat:\(slot.id)",
                    label: label,
                    confidence: 0.65,
                    source: backendID,
                    provenance: .structural
                ))
            }
        }
        return proposals
    }

    private func inferLabel(from name: String) -> String? {
        let normalized = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && !isAffix($0) }
            .joined(separator: "_")
        return normalized.isEmpty ? nil : normalized
    }

    // Strips common DCC affixes that carry no semantic content.
    private func isAffix(_ token: String) -> Bool {
        let affixes: Set<String> = ["l", "r", "left", "right", "top", "bot", "bottom",
                                    "lo", "hi", "low", "high", "geo", "mesh", "grp",
                                    "0", "1", "2", "3", "4", "5"]
        return affixes.contains(token)
    }
}

/// Uses the skeleton bone name list to infer anatomical part labels.
public struct RigBackend: SemanticAnalyzerBackend, Sendable {
    public let backendID = "rig"

    public init() {}

    public func analyze(regions: CandidateRegionSet,
                        rawStructure: RawStructure,
                        signals: GeometrySignals) async -> [SemanticProposal] {
        guard let skeleton = rawStructure.skeleton else { return [] }
        var proposals: [SemanticProposal] = []
        for bone in skeleton.bones {
            if let label = canonicalBoneLabel(bone.name) {
                proposals.append(SemanticProposal(
                    regionID: "region:bone:\(bone.id)",
                    label: label,
                    confidence: 0.90,
                    source: backendID,
                    provenance: .structural
                ))
            }
        }
        return proposals
    }

    private func canonicalBoneLabel(_ name: String) -> String? {
        // Strip namespace prefix (e.g. "mixamorig:LeftUpperArm" → "LeftUpperArm")
        let stripped = name.components(separatedBy: ":").last ?? name
        // Normalize: insert spaces before uppercase runs, then lowercase.
        var normalized = ""
        for (i, ch) in stripped.enumerated() {
            if ch.isUppercase && i > 0 { normalized += " " }
            normalized += ch.lowercased()
        }
        let tokens = normalized.components(separatedBy: .whitespaces)
            .flatMap { $0.components(separatedBy: "_") }
            .filter { !$0.isEmpty }
        let tokenSet = Set(tokens)

        let table: [(Set<String>, String)] = [
            (["head"], "head"),
            (["neck"], "neck"),
            (["spine"], "spine"),
            (["chest"], "chest"),
            (["hip"], "hip"),
            (["pelvis"], "pelvis"),
            (["shoulder"], "shoulder"),
            (["upper", "arm"], "upper_arm"),
            (["lower", "arm"], "lower_arm"),
            (["forearm"], "lower_arm"),
            (["hand"], "hand"),
            (["finger"], "finger"),
            (["thumb"], "thumb"),
            (["upper", "leg"], "upper_leg"),
            (["thigh"], "upper_leg"),
            (["lower", "leg"], "lower_leg"),
            (["shin"], "lower_leg"),
            (["calf"], "lower_leg"),
            (["foot"], "foot"),
            (["toe"], "toe"),
        ]
        for (keywords, label) in table {
            if keywords.isSubset(of: tokenSet) { return label }
        }
        return nil
    }
}

/// Reads DCC custom properties that explicitly name the part (e.g. `semantic_role = "door_handle"`).
public struct MetadataBackend: SemanticAnalyzerBackend, Sendable {
    public let backendID = "metadata"
    public let customPropertyKey: String

    public init(customPropertyKey: String = "semantic_role") {
        self.customPropertyKey = customPropertyKey
    }

    public func analyze(regions: CandidateRegionSet,
                        rawStructure: RawStructure,
                        signals: GeometrySignals) async -> [SemanticProposal] {
        guard let role = rawStructure.customProperties[customPropertyKey],
              !role.isEmpty
        else { return [] }
        // Root-level custom property applies to all top-level structural regions.
        return regions.regions
            .filter { $0.source == .structural && $0.parentRegionID == nil }
            .map { region in
                SemanticProposal(
                    regionID: region.id,
                    label: role,
                    confidence: 0.95,
                    source: backendID,
                    provenance: .structural
                )
            }
    }
}
