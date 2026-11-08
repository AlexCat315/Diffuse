//! AI's structured change proposal emitted by Session.

use diffuse_capability::capability_contract::CapabilityExposureSnapshot;
use diffuse_intent::transactions::transaction_ir::TransactionApprovalPolicy;
use diffuse_perception::SwiftDate;

use crate::planning::capability_draft_pipeline::CapabilityInvocationDraft;
use crate::planning::scene_edit_plan::SceneEditPlan;

/// AI's structured change intent produced by Session.
///
/// Callers convert a Proposal to a `TransactionIR` using `SceneEditPlanExecutor`,
/// which needs a live `SceneRuntime` — available in EditorCore but not inside AIRuntime.
#[derive(Clone, Debug, PartialEq)]
pub struct Proposal {
    pub id: String,
    pub session_id: String,
    pub semantic_intent: String,
    pub plan: SceneEditPlan,
    pub base_scene_revision: Option<u64>,
    pub reasoning: Option<String>,
    pub confidence: f64,
    pub approval_policy: TransactionApprovalPolicy,
    pub created_at: SwiftDate,
    pub tool_use_id: String,
    pub capability_exposure_snapshot: Option<CapabilityExposureSnapshot>,
    /// Validated write calls submitted through `submit_plan`. Plugin calls
    /// remain typed Drafts until EditorCore supplies a live SceneRuntime and
    /// expands them through `PluginCapabilityExecutor`.
    pub capability_drafts: Vec<CapabilityInvocationDraft>,
}

impl Proposal {
    pub fn new(session_id: String, semantic_intent: String, plan: SceneEditPlan) -> Self {
        Self {
            id: diffuse_kernel::codable::new_uuid(),
            session_id,
            semantic_intent,
            plan,
            base_scene_revision: None,
            reasoning: None,
            confidence: 0.85,
            approval_policy: TransactionApprovalPolicy::RequiresApproval,
            created_at: SwiftDate::now(),
            tool_use_id: String::new(),
            capability_exposure_snapshot: None,
            capability_drafts: Vec::new(),
        }
    }

    /// Swift's initializer with every argument explicit.
    #[allow(clippy::too_many_arguments)]
    pub fn with_options(
        id: String,
        session_id: String,
        semantic_intent: String,
        plan: SceneEditPlan,
        base_scene_revision: Option<u64>,
        reasoning: Option<String>,
        confidence: f64,
        approval_policy: TransactionApprovalPolicy,
        created_at: SwiftDate,
        tool_use_id: String,
        capability_exposure_snapshot: Option<CapabilityExposureSnapshot>,
        capability_drafts: Vec<CapabilityInvocationDraft>,
    ) -> Self {
        Self {
            id,
            session_id,
            semantic_intent,
            plan,
            base_scene_revision,
            reasoning,
            confidence,
            approval_policy,
            created_at,
            tool_use_id,
            capability_exposure_snapshot,
            capability_drafts,
        }
    }
}
