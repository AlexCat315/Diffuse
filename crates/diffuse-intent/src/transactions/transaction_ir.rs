//! The transaction IR: a set of operations across scene, sequence and assets.
//!
//! A transaction is previewed against a copy of the world, then applied. Everything in
//! it that reaches the persisted edit log or a policy decision is serialized, so the
//! `CapabilityInvocationRecord` in particular carries the **exact** capability identity
//! rather than letting policy infer a verb from a lower-level mutation.

use std::collections::BTreeMap;

use diffuse_capability::capability_contract::{CapabilityAccess, PluginCapabilityAuthority};
use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::editing::ComponentWriteMode;
use diffuse_scene::physics::collider::Collider;
use diffuse_scene::rendering::render_extraction::LightType;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_sequence::sequence_document::SequenceDocument;
use serde::{Deserialize, Serialize};

use crate::planning::intent_ir::IntentIR;
use crate::planning::scene_state_verification::SceneStateAssertion;
use crate::transactions::mutation_components::SceneComponentKey;

/// Which sub-system an operation touches.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransactionDomain {
    Scene,
    Sequence,
    Asset,
}

/// Whether a transaction may proceed without a human.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransactionApprovalPolicy {
    Automatic,
    RequiresApproval,
    Forbidden,
}

/// Where a transaction came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TransactionProvenance {
    Authored,
    Inferred,
    Proposal,
    Baked,
}

impl TransactionProvenance {
    /// The author kind recorded on the resulting `Edit`.
    pub const fn edit_author_kind(self) -> crate::planning::edit::EditAuthorKind {
        use crate::planning::edit::EditAuthorKind;
        match self {
            TransactionProvenance::Authored => EditAuthorKind::Human,
            TransactionProvenance::Proposal => EditAuthorKind::Ai,
            // Both an inferred and a baked change are the system's doing, not a person's.
            TransactionProvenance::Inferred | TransactionProvenance::Baked => {
                EditAuthorKind::System
            }
        }
    }
}

/// The revisions a transaction was authored against.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransactionBaseRevisions {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub scene_revision: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub sequence_revision_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub asset_revision_id: Option<String>,
}

impl TransactionBaseRevisions {
    pub fn new() -> Self {
        Self::default()
    }
}

/// What a preview predicted.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransactionPreviewResult {
    pub changed_domains: Vec<TransactionDomain>,
    pub created_entity_ids: Vec<u64>,
    pub deleted_entity_ids: Vec<u64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub scene_revision: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub sequence_revision_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub asset_entry_count: Option<usize>,
    pub mutation_summaries: Vec<String>,
}

impl TransactionPreviewResult {
    pub fn new(changed_domains: Vec<TransactionDomain>) -> Self {
        TransactionPreviewResult {
            changed_domains,
            created_entity_ids: Vec::new(),
            deleted_entity_ids: Vec::new(),
            scene_revision: None,
            sequence_revision_id: None,
            asset_entry_count: None,
            mutation_summaries: Vec::new(),
        }
    }
}

/// One edit to the scene.
///
/// Deliberately **not** `Serialize`: these carry runtime types (`LocalTransform`,
/// `ComponentValue`) exactly as Swift's non-`Codable` enum did. Only the envelope
/// (`TransactionIR`'s identity, policy and provenance) is persisted.
#[derive(Clone, Debug, PartialEq)]
pub enum SceneMutation {
    SpawnImportedMeshEntity {
        label: String,
        kind_label: String,
        mesh_index: i64,
        position: diffuse_math::simd::simd_compat::Float3,
        parent_id: Option<u64>,
    },
    SpawnEmptyEntity {
        label: String,
        position: diffuse_math::simd::simd_compat::Float3,
        parent_id: Option<u64>,
    },
    SpawnLightEntity {
        label: String,
        light_type: LightType,
        position: diffuse_math::simd::simd_compat::Float3,
        initial_intensity: Option<f32>,
        initial_color: Option<diffuse_math::simd::simd_compat::Float3>,
        initial_range: Option<f32>,
        initial_cast_shadows: Option<bool>,
        parent_id: Option<u64>,
    },
    SpawnCameraEntity {
        label: String,
        position: diffuse_math::simd::simd_compat::Float3,
        initial_fov_y_degrees: Option<f32>,
        parent_id: Option<u64>,
    },
    DeleteEntity {
        entity_id: u64,
    },
    DuplicateEntity {
        entity_id: u64,
    },
    /// Duplicate and immediately offset the copy in the source's local space.
    DuplicateEntityWithOffset {
        entity_id: u64,
        position_offset: diffuse_math::simd::simd_compat::Float3,
    },
    MoveEntity {
        entity_id: u64,
        parent_id: Option<u64>,
        index: i64,
    },
    SetLocalTransform {
        entity_id: u64,
        transform: LocalTransform,
    },
    SetSceneName {
        entity_id: u64,
        value: String,
    },
    /// Replace a component document, or merge field edits into it.
    SetComponentData {
        entity_id: u64,
        type_id: String,
        value: ComponentValue,
        mode: ComponentWriteMode,
    },
    AddComponent {
        entity_id: u64,
        type_id: String,
    },
    RemoveComponentData {
        entity_id: u64,
        type_id: String,
    },
}

impl SceneMutation {
    /// The entity this mutation targets, if it targets an existing one.
    ///
    /// The spawn variants return `None`: their entity does not exist yet.
    pub fn entity_id(&self) -> Option<u64> {
        match self {
            SceneMutation::SpawnImportedMeshEntity { .. }
            | SceneMutation::SpawnEmptyEntity { .. }
            | SceneMutation::SpawnLightEntity { .. }
            | SceneMutation::SpawnCameraEntity { .. } => None,
            SceneMutation::DeleteEntity { entity_id }
            | SceneMutation::DuplicateEntity { entity_id }
            | SceneMutation::DuplicateEntityWithOffset { entity_id, .. }
            | SceneMutation::MoveEntity { entity_id, .. }
            | SceneMutation::SetLocalTransform { entity_id, .. }
            | SceneMutation::SetSceneName { entity_id, .. }
            | SceneMutation::SetComponentData { entity_id, .. }
            | SceneMutation::AddComponent { entity_id, .. }
            | SceneMutation::RemoveComponentData { entity_id, .. } => Some(*entity_id),
        }
    }

    /// The component key this mutation touches, for undo grouping.
    pub fn component_key(&self) -> Option<SceneComponentKey> {
        match self {
            SceneMutation::SetComponentData {
                entity_id, type_id, ..
            }
            | SceneMutation::AddComponent { entity_id, type_id }
            | SceneMutation::RemoveComponentData { entity_id, type_id } => {
                Some(SceneComponentKey::new(*entity_id, type_id.clone()))
            }
            _ => None,
        }
    }
}

/// One edit to a sequence.
#[derive(Clone, Debug, PartialEq)]
pub enum SequenceMutation {
    /// Boxed because a whole sequence document dwarfs every other variant, and an
    /// unboxed variant would make every `TransactionOperation` that large.
    ReplaceDocument(Box<SequenceDocument>),
}

/// One edit to the asset library.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AssetMutation {
    ScanProject { root_path: String },
}

/// Any operation a transaction can carry.
#[derive(Clone, Debug, PartialEq)]
pub enum TransactionOperation {
    Scene(SceneMutation),
    Sequence(SequenceMutation),
    Asset(AssetMutation),
}

impl TransactionOperation {
    pub const fn domain(&self) -> TransactionDomain {
        match self {
            TransactionOperation::Scene(_) => TransactionDomain::Scene,
            TransactionOperation::Sequence(_) => TransactionDomain::Sequence,
            TransactionOperation::Asset(_) => TransactionDomain::Asset,
        }
    }
}

/// Exact capability provenance for an operation produced by AI or a plugin.
///
/// Carrying this record means policy never has to infer a verb from a lower-level
/// mutation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityInvocationRecord {
    pub capability_id: String,
    pub capability_version: i64,
    pub schema_hash: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub source_plugin_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub plugin_authority: Option<PluginCapabilityAuthority>,
    pub input_digest: String,
    pub argument_names: Vec<String>,
    pub target_references: Vec<String>,
    pub access: CapabilityAccess,
    /// An exposure snapshot id, uppercase 36-character UUID.
    pub exposure_snapshot_id: String,
}

impl CapabilityInvocationRecord {
    pub fn new(
        capability_id: impl Into<String>,
        capability_version: i64,
        schema_hash: impl Into<String>,
        input_digest: impl Into<String>,
        access: CapabilityAccess,
    ) -> Self {
        CapabilityInvocationRecord {
            capability_id: capability_id.into(),
            capability_version,
            schema_hash: schema_hash.into(),
            source_plugin_id: None,
            plugin_authority: None,
            input_digest: input_digest.into(),
            argument_names: Vec::new(),
            target_references: Vec::new(),
            access,
            exposure_snapshot_id: crate::planning::edit::new_uuid(),
        }
    }

    /// Swift's initializer **sorted** `argumentNames`. Keep that: the record is compared
    /// and hashed, so two invocations differing only in argument order must match.
    pub fn with_argument_names(mut self, mut names: Vec<String>) -> Self {
        names.sort();
        self.argument_names = names;
        self
    }
}

/// A host-owned, deterministic check evaluated after all operations are applied.
///
/// A failed assertion aborts the transaction and restores the in-memory snapshots.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum TransactionVerificationAssertion {
    EntityExists(u64),
    EntityIsAbsent(u64),
    CreatedEntityCount(usize),
    DeletedEntity(u64),
    SceneRevisionAdvanced {
        from: u64,
    },
    SceneState(SceneStateAssertion),
    ComponentData {
        entity_id: u64,
        type_id: String,
        value: ComponentValue,
        mode: ComponentWriteMode,
    },
    ComponentPresence {
        entity_id: u64,
        type_id: String,
        is_present: bool,
    },
}

/// A transaction: what to do, how it is checked, and what it is based on.
#[derive(Clone, Debug, PartialEq)]
pub struct TransactionIR {
    pub id: String,
    pub intent: Option<IntentIR>,
    pub summary: String,
    pub operations: Vec<TransactionOperation>,
    pub capability_invocations: Vec<CapabilityInvocationRecord>,
    pub verification_assertions: Vec<TransactionVerificationAssertion>,
    pub base_revisions: TransactionBaseRevisions,
    pub approval_policy: TransactionApprovalPolicy,
    pub preview: Option<TransactionPreviewResult>,
    pub rollback_handle: Option<String>,
    pub provenance: TransactionProvenance,
    /// Swift's `Date`, i.e. seconds since 2001-01-01.
    pub created_at: SwiftDate,
}

impl TransactionIR {
    /// Swift's memberwise initializer with its defaults applied.
    pub fn new(
        summary: impl Into<String>,
        operations: Vec<TransactionOperation>,
        provenance: TransactionProvenance,
    ) -> Self {
        TransactionIR {
            id: crate::planning::edit::new_uuid(),
            intent: None,
            summary: summary.into(),
            operations,
            capability_invocations: Vec::new(),
            verification_assertions: Vec::new(),
            base_revisions: TransactionBaseRevisions::new(),
            approval_policy: TransactionApprovalPolicy::Automatic,
            preview: None,
            rollback_handle: None,
            provenance,
            created_at: SwiftDate::now(),
        }
    }

    /// The distinct domains this transaction touches, in first-seen order.
    pub fn changed_domains(&self) -> Vec<TransactionDomain> {
        let mut domains: Vec<TransactionDomain> = Vec::new();
        for operation in &self.operations {
            let domain = operation.domain();
            if !domains.contains(&domain) {
                domains.push(domain);
            }
        }
        domains
    }

    /// Operations grouped by domain.
    pub fn operations_by_domain(&self) -> BTreeMap<TransactionDomain, Vec<&TransactionOperation>> {
        let mut grouped: BTreeMap<TransactionDomain, Vec<&TransactionOperation>> = BTreeMap::new();
        for operation in &self.operations {
            grouped
                .entry(operation.domain())
                .or_default()
                .push(operation);
        }
        grouped
    }

    /// Whether policy forbids running this transaction.
    #[inline]
    pub fn is_forbidden(&self) -> bool {
        self.approval_policy == TransactionApprovalPolicy::Forbidden
    }
}

/// Snapshot a collider's primary shape for a verification assertion.
pub fn collider_primary_shape_assertion(
    entity_id: u64,
    collider: &Collider,
) -> SceneStateAssertion {
    SceneStateAssertion::ColliderPrimaryShape {
        entity_id,
        value: crate::planning::scene_state_verification::SceneColliderShapeVerificationState::from_shape(
            &collider.shape(),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spawn() -> TransactionOperation {
        TransactionOperation::Scene(SceneMutation::SpawnEmptyEntity {
            label: "empty".to_string(),
            position: diffuse_math::simd::simd_compat::Float3::ZERO,
            parent_id: None,
        })
    }

    fn delete(entity_id: u64) -> TransactionOperation {
        TransactionOperation::Scene(SceneMutation::DeleteEntity { entity_id })
    }

    #[test]
    fn a_spawn_mutation_targets_no_existing_entity() {
        let TransactionOperation::Scene(mutation) = spawn() else {
            panic!("expected a scene operation");
        };
        assert_eq!(mutation.entity_id(), None, "a spawn creates its entity");
    }

    #[test]
    fn a_delete_mutation_targets_its_entity() {
        let TransactionOperation::Scene(mutation) = delete(7) else {
            panic!("expected a scene operation");
        };
        assert_eq!(mutation.entity_id(), Some(7));
    }

    #[test]
    fn component_mutations_expose_a_component_key() {
        let mutation = SceneMutation::AddComponent {
            entity_id: 4,
            type_id: "rigidBody".to_string(),
        };
        assert_eq!(
            mutation.component_key(),
            Some(SceneComponentKey::new(4, "rigidBody"))
        );
    }

    #[test]
    fn changed_domains_are_first_seen_and_deduplicated() {
        let transaction = TransactionIR::new(
            "mixed",
            vec![
                delete(1),
                TransactionOperation::Asset(AssetMutation::ScanProject {
                    root_path: "/tmp".to_string(),
                }),
                delete(2),
            ],
            TransactionProvenance::Authored,
        );
        assert_eq!(
            transaction.changed_domains(),
            vec![TransactionDomain::Scene, TransactionDomain::Asset]
        );
    }

    #[test]
    fn argument_names_are_sorted_when_set() {
        let record = CapabilityInvocationRecord::new(
            "cove.scene.spawn",
            1,
            "hash",
            "digest",
            CapabilityAccess::ReversibleWrite,
        )
        .with_argument_names(vec![
            "zeta".to_string(),
            "alpha".to_string(),
            "mid".to_string(),
        ]);
        assert_eq!(record.argument_names, vec!["alpha", "mid", "zeta"]);
    }

    #[test]
    fn provenance_maps_to_the_edit_author_kind() {
        use crate::planning::edit::EditAuthorKind;
        assert_eq!(
            TransactionProvenance::Authored.edit_author_kind(),
            EditAuthorKind::Human
        );
        assert_eq!(
            TransactionProvenance::Proposal.edit_author_kind(),
            EditAuthorKind::Ai
        );
        assert_eq!(
            TransactionProvenance::Inferred.edit_author_kind(),
            EditAuthorKind::System
        );
        assert_eq!(
            TransactionProvenance::Baked.edit_author_kind(),
            EditAuthorKind::System
        );
    }

    #[test]
    fn a_forbidden_transaction_is_reported() {
        let mut transaction =
            TransactionIR::new("x", vec![delete(1)], TransactionProvenance::Proposal);
        assert!(!transaction.is_forbidden());
        transaction.approval_policy = TransactionApprovalPolicy::Forbidden;
        assert!(transaction.is_forbidden());
    }

    #[test]
    fn the_serializable_envelope_round_trips() {
        // `TransactionIR` itself is not `Serialize` because its operations carry runtime
        // types; the persisted envelope is the base revisions, policy and provenance.
        let revisions = TransactionBaseRevisions {
            scene_revision: Some(12),
            sequence_revision_id: Some("seq-1".to_string()),
            asset_revision_id: None,
        };
        let json = serde_json::to_string(&revisions).expect("serialize");
        let restored: TransactionBaseRevisions = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(restored, revisions);
        assert!(
            !json.contains("assetRevisionId"),
            "absent ids are omitted: {json}"
        );
    }

    #[test]
    fn a_preview_omits_absent_optional_fields() {
        let preview = TransactionPreviewResult::new(vec![TransactionDomain::Scene]);
        let json = serde_json::to_string(&preview).expect("serialize");
        assert!(!json.contains("sceneRevision"));
        assert!(!json.contains("assetEntryCount"));
        assert!(json.contains("\"changedDomains\":[\"scene\"]"));
    }
}
