//! Crate root. See MIGRATION.md §5.
pub mod context;
pub mod planning;
pub mod semantic;
pub mod session;
#[cfg(test)]
pub mod tests;
pub mod tools;

pub use context::ai_world_context::AIWorldContext;
pub use context::asset_workflow_context::AssetWorkflowContext;
pub use context::workflow_context::{
    FilmNarrativePhase, FilmWorkflowContext, GameKnownConstraints, GameLevelPhase,
    GameWorkflowContext, GameplayIntent, PlaytestSummary, ReferenceAnchor,
    ScriptParameterDescriptor, ScriptSchema, WorkflowContext,
};
pub use context::workstation_context::{WorkstationContext, WorkstationContextDomain};
pub use context::world_view::{
    InferredDisplayValue, InferredProperty, WorldEntityRecord, WorldView, WorldViewEdit,
};
pub use semantic::scene_semantic_snapshot::{
    SceneSemanticSnapshot, SceneSemanticSnapshotEntity, SceneSemanticSnapshotScriptBindingRecord,
};
