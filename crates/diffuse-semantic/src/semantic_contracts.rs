//! `SemanticContracts.swift` — data contracts shared by every pipeline stage.
//!
//! Only the types Swift marks `Codable` (`RegionSource`, `SemanticProvenance`)
//! carry serde attributes; the structure/geometry inputs are runtime values.

use std::collections::BTreeMap;

use diffuse_perception::SwiftDate;
use serde::{Deserialize, Serialize};

// MARK: - StructureExtractor output

#[derive(Clone, Debug, PartialEq)]
pub struct RawStructure {
    pub asset_uri: String,
    /// Local path to a preview image (PNG/JPEG) for vision-based backends.
    pub preview_image_path: Option<String>,
    pub nodes: Vec<RawStructureNode>,
    pub meshes: Vec<RawStructureMeshRecord>,
    pub submeshes: Vec<RawStructureSubmeshRecord>,
    pub material_slots: Vec<RawStructureMaterialSlot>,
    pub skeleton: Option<RawStructureSkeleton>,
    pub morph_targets: Vec<RawStructureMorphTarget>,
    pub uv_sets: Vec<RawStructureUVSet>,
    pub custom_properties: BTreeMap<String, String>,
}

impl RawStructure {
    pub fn new(asset_uri: impl Into<String>) -> Self {
        RawStructure {
            asset_uri: asset_uri.into(),
            preview_image_path: None,
            nodes: Vec::new(),
            meshes: Vec::new(),
            submeshes: Vec::new(),
            material_slots: Vec::new(),
            skeleton: None,
            morph_targets: Vec::new(),
            uv_sets: Vec::new(),
            custom_properties: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RawStructureNode {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    /// Column-major 4x4.
    pub local_transform: Vec<f32>,
}

impl RawStructureNode {
    pub fn new(id: impl Into<String>, name: impl Into<String>) -> Self {
        RawStructureNode {
            id: id.into(),
            name: name.into(),
            parent_id: None,
            local_transform: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RawStructureMeshRecord {
    pub id: String,
    pub node_id: String,
    pub vertex_count: i64,
    pub face_count: i64,
}

impl RawStructureMeshRecord {
    pub fn new(
        id: impl Into<String>,
        node_id: impl Into<String>,
        vertex_count: i64,
        face_count: i64,
    ) -> Self {
        RawStructureMeshRecord {
            id: id.into(),
            node_id: node_id.into(),
            vertex_count,
            face_count,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RawStructureSubmeshRecord {
    pub id: String,
    pub mesh_id: String,
    pub material_slot: i64,
    pub index_start: i64,
    pub index_count: i64,
}

impl RawStructureSubmeshRecord {
    pub fn new(
        id: impl Into<String>,
        mesh_id: impl Into<String>,
        material_slot: i64,
        index_start: i64,
        index_count: i64,
    ) -> Self {
        RawStructureSubmeshRecord {
            id: id.into(),
            mesh_id: mesh_id.into(),
            material_slot,
            index_start,
            index_count,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RawStructureMaterialSlot {
    pub id: String,
    pub name: String,
    pub source_index: i64,
}

impl RawStructureMaterialSlot {
    pub fn new(id: impl Into<String>, name: impl Into<String>, source_index: i64) -> Self {
        RawStructureMaterialSlot {
            id: id.into(),
            name: name.into(),
            source_index,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RawStructureBone {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
}

impl RawStructureBone {
    pub fn new(id: impl Into<String>, name: impl Into<String>) -> Self {
        RawStructureBone {
            id: id.into(),
            name: name.into(),
            parent_id: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RawStructureSkeleton {
    pub bones: Vec<RawStructureBone>,
}

impl RawStructureSkeleton {
    pub fn new(bones: Vec<RawStructureBone>) -> Self {
        RawStructureSkeleton { bones }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RawStructureMorphTarget {
    pub id: String,
    pub name: String,
    pub mesh_id: String,
}

impl RawStructureMorphTarget {
    pub fn new(id: impl Into<String>, name: impl Into<String>, mesh_id: impl Into<String>) -> Self {
        RawStructureMorphTarget {
            id: id.into(),
            name: name.into(),
            mesh_id: mesh_id.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RawStructureUVSet {
    pub mesh_id: String,
    pub channel: i64,
    pub island_count: i64,
}

impl RawStructureUVSet {
    pub fn new(mesh_id: impl Into<String>, channel: i64, island_count: i64) -> Self {
        RawStructureUVSet {
            mesh_id: mesh_id.into(),
            channel,
            island_count,
        }
    }
}

// MARK: - GeometryAnalyzer output

#[derive(Clone, Debug, PartialEq)]
pub struct GeometrySignals {
    pub asset_uri: String,
    pub connected_components: Vec<GeometrySignalsConnectedComponent>,
    pub symmetry_axes: Vec<GeometrySignalsSymmetryAxis>,
    pub protrusions: Vec<GeometrySignalsProtrusion>,
    pub support_planes: Vec<GeometrySignalsSupportPlane>,
    pub surface_area: f32,
    pub volume_estimate: f32,
}

impl GeometrySignals {
    pub fn new(asset_uri: impl Into<String>) -> Self {
        GeometrySignals {
            asset_uri: asset_uri.into(),
            connected_components: Vec::new(),
            symmetry_axes: Vec::new(),
            protrusions: Vec::new(),
            support_planes: Vec::new(),
            surface_area: 0.0,
            volume_estimate: 0.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GeometrySignalsAABB {
    pub min: (f32, f32, f32),
    pub max: (f32, f32, f32),
}

impl GeometrySignalsAABB {
    pub fn new(min: (f32, f32, f32), max: (f32, f32, f32)) -> Self {
        GeometrySignalsAABB { min, max }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GeometrySignalsSymmetryAxis {
    pub axis: (f32, f32, f32),
    pub confidence: f32,
}

impl GeometrySignalsSymmetryAxis {
    pub fn new(axis: (f32, f32, f32), confidence: f32) -> Self {
        GeometrySignalsSymmetryAxis { axis, confidence }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GeometrySignalsConnectedComponent {
    pub id: String,
    pub mesh_id: String,
    pub face_count: i64,
    pub bounds: GeometrySignalsAABB,
}

impl GeometrySignalsConnectedComponent {
    pub fn new(
        id: impl Into<String>,
        mesh_id: impl Into<String>,
        face_count: i64,
        bounds: GeometrySignalsAABB,
    ) -> Self {
        GeometrySignalsConnectedComponent {
            id: id.into(),
            mesh_id: mesh_id.into(),
            face_count,
            bounds,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GeometrySignalsProtrusion {
    pub id: String,
    pub length: f32,
    pub base_radius: f32,
}

impl GeometrySignalsProtrusion {
    pub fn new(id: impl Into<String>, length: f32, base_radius: f32) -> Self {
        GeometrySignalsProtrusion {
            id: id.into(),
            length,
            base_radius,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GeometrySignalsSupportPlane {
    pub id: String,
    pub normal: (f32, f32, f32),
    pub area: f32,
}

impl GeometrySignalsSupportPlane {
    pub fn new(id: impl Into<String>, normal: (f32, f32, f32), area: f32) -> Self {
        GeometrySignalsSupportPlane {
            id: id.into(),
            normal,
            area,
        }
    }
}

// MARK: - Geometry fingerprint (lookup key for SemanticMemoryStore)

#[derive(Clone, Debug, PartialEq)]
pub struct GeometryFingerprint {
    /// Rotation/translation/uniform-scale-invariant shape descriptor (not sent to LLM).
    pub shape_descriptor: Vec<f32>,
    /// Laplacian spectral hash — only consumed by KNN lookup, never by LLM.
    pub spectral_hash: Vec<u8>,
    pub genus: i64,
    pub boundary_loops: i64,
    pub face_count_bucket: i64,
    pub scale_hint: f32,
    pub version: i64,
}

impl GeometryFingerprint {
    pub fn new() -> Self {
        GeometryFingerprint {
            shape_descriptor: Vec::new(),
            spectral_hash: Vec::new(),
            genus: 0,
            boundary_loops: 0,
            face_count_bucket: 0,
            scale_hint: 1.0,
            version: 1,
        }
    }

    pub fn with_topology(
        genus: i64,
        boundary_loops: i64,
        face_count_bucket: i64,
        version: i64,
    ) -> Self {
        GeometryFingerprint {
            genus,
            boundary_loops,
            face_count_bucket,
            version,
            ..GeometryFingerprint::new()
        }
    }
}

impl Default for GeometryFingerprint {
    fn default() -> Self {
        GeometryFingerprint::new()
    }
}

// MARK: - CandidateRegionBuilder output

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RegionSource {
    Structural,
    Geometric,
    Memory,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RegionBounds {
    pub center_x: f32,
    pub center_y: f32,
    pub center_z: f32,
    pub size_x: f32,
    pub size_y: f32,
    pub size_z: f32,
}

impl RegionBounds {
    pub const ZERO: RegionBounds = RegionBounds {
        center_x: 0.0,
        center_y: 0.0,
        center_z: 0.0,
        size_x: 0.0,
        size_y: 0.0,
        size_z: 0.0,
    };

    pub fn new(
        center_x: f32,
        center_y: f32,
        center_z: f32,
        size_x: f32,
        size_y: f32,
        size_z: f32,
    ) -> Self {
        RegionBounds {
            center_x,
            center_y,
            center_z,
            size_x,
            size_y,
            size_z,
        }
    }
}

impl Default for RegionBounds {
    fn default() -> Self {
        RegionBounds::ZERO
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Region {
    pub id: String,
    pub source: RegionSource,
    pub bounds: RegionBounds,
    pub symmetry_group_id: Option<String>,
    pub parent_region_id: Option<String>,
    pub fingerprint: GeometryFingerprint,
}

impl Region {
    pub fn new(id: impl Into<String>, source: RegionSource) -> Self {
        Region {
            id: id.into(),
            source,
            bounds: RegionBounds::ZERO,
            symmetry_group_id: None,
            parent_region_id: None,
            fingerprint: GeometryFingerprint::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CandidateRegionSet {
    pub asset_uri: String,
    pub regions: Vec<Region>,
}

impl CandidateRegionSet {
    pub fn new(asset_uri: impl Into<String>) -> Self {
        CandidateRegionSet {
            asset_uri: asset_uri.into(),
            regions: Vec::new(),
        }
    }

    pub fn with_regions(asset_uri: impl Into<String>, regions: Vec<Region>) -> Self {
        CandidateRegionSet {
            asset_uri: asset_uri.into(),
            regions,
        }
    }
}

// MARK: - SemanticAnalyzer output

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SemanticProvenance {
    Structural,
    Geometric,
    Inferred,
    Confirmed,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SemanticEvidence {
    pub kind: String,
    pub weight: f32,
    pub detail: Option<String>,
}

impl SemanticEvidence {
    pub fn new(kind: impl Into<String>, weight: f32) -> Self {
        SemanticEvidence {
            kind: kind.into(),
            weight,
            detail: None,
        }
    }

    pub fn with_detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SemanticAlternative {
    pub label: String,
    pub confidence: f32,
}

impl SemanticAlternative {
    pub fn new(label: impl Into<String>, confidence: f32) -> Self {
        SemanticAlternative {
            label: label.into(),
            confidence,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SemanticProposal {
    pub region_id: String,
    pub label: String,
    pub confidence: f32,
    /// Backend identifier.
    pub source: String,
    pub evidence: Vec<SemanticEvidence>,
    pub alternatives: Vec<SemanticAlternative>,
    pub provenance: SemanticProvenance,
}

impl SemanticProposal {
    pub fn new(
        region_id: impl Into<String>,
        label: impl Into<String>,
        confidence: f32,
        source: impl Into<String>,
    ) -> Self {
        SemanticProposal {
            region_id: region_id.into(),
            label: label.into(),
            confidence,
            source: source.into(),
            evidence: Vec::new(),
            alternatives: Vec::new(),
            provenance: SemanticProvenance::Inferred,
        }
    }

    pub fn with_provenance(mut self, provenance: SemanticProvenance) -> Self {
        self.provenance = provenance;
        self
    }

    pub fn with_evidence(mut self, evidence: Vec<SemanticEvidence>) -> Self {
        self.evidence = evidence;
        self
    }

    pub fn with_alternatives(mut self, alternatives: Vec<SemanticAlternative>) -> Self {
        self.alternatives = alternatives;
        self
    }
}

// MARK: - AmbiguityScorer output

#[derive(Clone, Debug, PartialEq)]
pub struct AmbiguityQuestionCandidate {
    pub label: String,
    pub confidence: f32,
    pub source: String,
}

impl AmbiguityQuestionCandidate {
    pub fn new(label: impl Into<String>, confidence: f32, source: impl Into<String>) -> Self {
        AmbiguityQuestionCandidate {
            label: label.into(),
            confidence,
            source: source.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct AmbiguityQuestion {
    pub region_id: String,
    pub candidates: Vec<AmbiguityQuestionCandidate>,
    pub suggested_default: Option<String>,
}

impl AmbiguityQuestion {
    pub fn new(region_id: impl Into<String>, candidates: Vec<AmbiguityQuestionCandidate>) -> Self {
        AmbiguityQuestion {
            region_id: region_id.into(),
            candidates,
            suggested_default: None,
        }
    }

    pub fn with_suggested_default(mut self, label: impl Into<String>) -> Self {
        self.suggested_default = Some(label.into());
        self
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum AmbiguityDecision {
    AutoCommit(Vec<SemanticProposal>),
    NeedsConfirmation(Vec<AmbiguityQuestion>),
}

// MARK: - Confirmation output

#[derive(Clone, Debug, PartialEq)]
pub enum SemanticConfirmationOutcome {
    Accepted(String),
    Renamed(String),
    Rejected,
    Deferred,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SemanticConfirmation {
    pub region_id: String,
    pub outcome: SemanticConfirmationOutcome,
    pub confirmed_by: String,
    pub confirmed_at: SwiftDate,
}

impl SemanticConfirmation {
    pub fn new(
        region_id: impl Into<String>,
        outcome: SemanticConfirmationOutcome,
        confirmed_by: impl Into<String>,
    ) -> Self {
        SemanticConfirmation {
            region_id: region_id.into(),
            outcome,
            confirmed_by: confirmed_by.into(),
            confirmed_at: SwiftDate::now(),
        }
    }

    pub fn with_confirmed_at(mut self, confirmed_at: SwiftDate) -> Self {
        self.confirmed_at = confirmed_at;
        self
    }
}
