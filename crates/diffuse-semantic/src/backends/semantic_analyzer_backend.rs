//! `SemanticAnalyzerBackend.swift` — pluggable label sources.

use std::collections::HashSet;

use crate::semantic_contracts::{
    CandidateRegionSet, GeometrySignals, RawStructure, RegionSource, SemanticProposal,
    SemanticProvenance,
};

/// Pluggable backend for assigning semantic labels to candidate regions.
/// Multiple backends run in parallel; their proposals are arbitrated by `AmbiguityScorer`.
pub trait SemanticAnalyzerBackend: Send + Sync {
    fn backend_id(&self) -> &'static str;

    fn analyze(
        &self,
        regions: &CandidateRegionSet,
        raw_structure: &RawStructure,
        signals: &GeometrySignals,
    ) -> Vec<SemanticProposal>;
}

/// Matches common DCC naming conventions (e.g. "ear_L" → "ear", "glass_mat" → "glass_panel").
pub struct NameHeuristicBackend;

impl NameHeuristicBackend {
    pub fn new() -> Self {
        NameHeuristicBackend
    }

    fn infer_label(name: &str) -> Option<String> {
        let normalized = name.replace(['_', '-'], " ").to_lowercase();
        let joined = normalized
            .split([' ', '\t'])
            .filter(|token| !token.is_empty() && !Self::is_affix(token))
            .collect::<Vec<_>>()
            .join("_");
        (!joined.is_empty()).then_some(joined)
    }

    /// Strips common DCC affixes that carry no semantic content.
    fn is_affix(token: &str) -> bool {
        const AFFIXES: [&str; 20] = [
            "l", "r", "left", "right", "top", "bot", "bottom", "lo", "hi", "low", "high", "geo",
            "mesh", "grp", "0", "1", "2", "3", "4", "5",
        ];
        AFFIXES.contains(&token)
    }
}

impl Default for NameHeuristicBackend {
    fn default() -> Self {
        NameHeuristicBackend::new()
    }
}

impl SemanticAnalyzerBackend for NameHeuristicBackend {
    fn backend_id(&self) -> &'static str {
        "name_heuristic"
    }

    fn analyze(
        &self,
        regions: &CandidateRegionSet,
        raw_structure: &RawStructure,
        _signals: &GeometrySignals,
    ) -> Vec<SemanticProposal> {
        let mut proposals = Vec::new();
        for region in regions
            .regions
            .iter()
            .filter(|region| region.source == RegionSource::Structural)
        {
            let node_id: String = region.id.chars().skip("region:".chars().count()).collect();
            let Some(node) = raw_structure.nodes.iter().find(|node| node.id == node_id) else {
                continue;
            };
            if node.name.is_empty() {
                continue;
            }

            if let Some(label) = Self::infer_label(&node.name) {
                proposals.push(
                    SemanticProposal::new(region.id.clone(), label, 0.75, self.backend_id())
                        .with_provenance(SemanticProvenance::Structural),
                );
            }
        }
        for slot in raw_structure
            .material_slots
            .iter()
            .filter(|slot| !slot.name.is_empty())
        {
            if let Some(label) = Self::infer_label(&slot.name) {
                // material-slot proposals attach to submesh regions if they exist
                proposals.push(
                    SemanticProposal::new(
                        format!("region:mat:{}", slot.id),
                        label,
                        0.65,
                        self.backend_id(),
                    )
                    .with_provenance(SemanticProvenance::Structural),
                );
            }
        }
        proposals
    }
}

/// Uses the skeleton bone name list to infer anatomical part labels.
pub struct RigBackend;

impl RigBackend {
    pub fn new() -> Self {
        RigBackend
    }

    fn canonical_bone_label(name: &str) -> Option<&'static str> {
        // Strip namespace prefix (e.g. "mixamorig:LeftUpperArm" → "LeftUpperArm")
        let stripped = name.rsplit(':').next().unwrap_or(name);
        // Normalize: insert spaces before uppercase runs, then lowercase.
        let mut normalized = String::new();
        for (i, ch) in stripped.chars().enumerate() {
            if ch.is_uppercase() && i > 0 {
                normalized.push(' ');
            }
            normalized.extend(ch.to_lowercase());
        }
        let tokens: HashSet<&str> = normalized
            .split([' ', '\t'])
            .flat_map(|token| token.split('_'))
            .filter(|token| !token.is_empty())
            .collect();

        const TABLE: &[(&[&str], &str)] = &[
            (&["head"], "head"),
            (&["neck"], "neck"),
            (&["spine"], "spine"),
            (&["chest"], "chest"),
            (&["hip"], "hip"),
            (&["pelvis"], "pelvis"),
            (&["shoulder"], "shoulder"),
            (&["upper", "arm"], "upper_arm"),
            (&["lower", "arm"], "lower_arm"),
            (&["forearm"], "lower_arm"),
            (&["hand"], "hand"),
            (&["finger"], "finger"),
            (&["thumb"], "thumb"),
            (&["upper", "leg"], "upper_leg"),
            (&["thigh"], "upper_leg"),
            (&["lower", "leg"], "lower_leg"),
            (&["shin"], "lower_leg"),
            (&["calf"], "lower_leg"),
            (&["foot"], "foot"),
            (&["toe"], "toe"),
        ];
        for (keywords, label) in TABLE {
            if keywords.iter().all(|keyword| tokens.contains(*keyword)) {
                return Some(*label);
            }
        }
        None
    }
}

impl Default for RigBackend {
    fn default() -> Self {
        RigBackend::new()
    }
}

impl SemanticAnalyzerBackend for RigBackend {
    fn backend_id(&self) -> &'static str {
        "rig"
    }

    fn analyze(
        &self,
        _regions: &CandidateRegionSet,
        raw_structure: &RawStructure,
        _signals: &GeometrySignals,
    ) -> Vec<SemanticProposal> {
        let Some(skeleton) = &raw_structure.skeleton else {
            return Vec::new();
        };
        let mut proposals = Vec::new();
        for bone in &skeleton.bones {
            if let Some(label) = Self::canonical_bone_label(&bone.name) {
                proposals.push(
                    SemanticProposal::new(
                        format!("region:bone:{}", bone.id),
                        label,
                        0.90,
                        self.backend_id(),
                    )
                    .with_provenance(SemanticProvenance::Structural),
                );
            }
        }
        proposals
    }
}

/// Reads DCC custom properties that explicitly name the part (e.g. `semantic_role = "door_handle"`).
pub struct MetadataBackend {
    pub custom_property_key: String,
}

impl MetadataBackend {
    pub fn new(custom_property_key: impl Into<String>) -> Self {
        MetadataBackend {
            custom_property_key: custom_property_key.into(),
        }
    }
}

impl Default for MetadataBackend {
    fn default() -> Self {
        MetadataBackend::new("semantic_role")
    }
}

impl SemanticAnalyzerBackend for MetadataBackend {
    fn backend_id(&self) -> &'static str {
        "metadata"
    }

    fn analyze(
        &self,
        regions: &CandidateRegionSet,
        raw_structure: &RawStructure,
        _signals: &GeometrySignals,
    ) -> Vec<SemanticProposal> {
        let Some(role) = raw_structure
            .custom_properties
            .get(&self.custom_property_key)
        else {
            return Vec::new();
        };
        if role.is_empty() {
            return Vec::new();
        }
        // Root-level custom property applies to all top-level structural regions.
        regions
            .regions
            .iter()
            .filter(|region| {
                region.source == RegionSource::Structural && region.parent_region_id.is_none()
            })
            .map(|region| {
                SemanticProposal::new(region.id.clone(), role.clone(), 0.95, self.backend_id())
                    .with_provenance(SemanticProvenance::Structural)
            })
            .collect()
    }
}
