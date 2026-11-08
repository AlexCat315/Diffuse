//! Workflow context for Diffuse's document and media workspaces.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkstationContext {
    pub domain: WorkstationContextDomain,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkstationContextDomain {
    #[serde(rename = "documents")]
    Documents,
    #[serde(rename = "media")]
    Media,
}

impl WorkstationContextDomain {
    pub fn as_str(self) -> &'static str {
        match self {
            WorkstationContextDomain::Documents => "documents",
            WorkstationContextDomain::Media => "media",
        }
    }
}

impl WorkstationContext {
    pub fn new(domain: WorkstationContextDomain) -> Self {
        Self { domain }
    }

    pub(crate) fn system_prompt_section(&self) -> String {
        format!(
            "You are assisting in Diffuse's {} workspace.\n\
             Read project files before editing and preserve unsaved buffers. Use the\n\
             project tools to inspect actual results. Text and code documents are\n\
             ordinary files; opening or saving them does not execute code. Media\n\
             edits are authored clip ranges; export renders a new output file.\n\
             Do not invent scene operations for document or media tasks.\n\
             The project may be under Git or Lore version control: vcs_status and\n\
             vcs_diff show what changed, vcs_log shows history. Commit with\n\
             vcs_commit only when the user asks; never rewrite history.",
            self.domain.as_str()
        )
    }
}
