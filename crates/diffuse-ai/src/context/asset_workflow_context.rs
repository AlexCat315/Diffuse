//! Workflow context for 3D asset authoring.

use serde::{Deserialize, Serialize};

/// Asset authoring does not imply a film sequence or interactive gameplay.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AssetWorkflowContext {
    pub intent: String,
}

impl AssetWorkflowContext {
    pub fn new(intent: String) -> Self {
        Self { intent }
    }

    pub(crate) fn system_prompt_section(&self) -> String {
        format!(
            "Workflow: 3D asset creation\nAuthoring intent: {}\n\
             Focus on scene composition, materials, lighting and asset quality. \
             Only use available capabilities; do not claim geometry, UV or rig \
             editing tools that are not registered.",
            self.intent
        )
    }
}

impl Default for AssetWorkflowContext {
    fn default() -> Self {
        Self {
            intent: "Create and render reusable 3D assets".to_string(),
        }
    }
}
