//! Ported from `Engine/Sources/AIRuntime/Session/Signal.swift`.

/// Unified input to the Session, covering all authoring modalities.
#[derive(Clone, Debug, PartialEq)]
pub enum Signal {
    NaturalLanguage {
        text: String,
        locale: String,
    },
    SelectionChanged {
        entity_refs: Vec<String>,
    },
    WorldChanged {
        edit_summary: String,
        revision: u64,
    },
    UserCorrection {
        proposal_id: String,
        accepted_step_ids: Vec<String>,
        rejected_step_ids: Vec<String>,
    },
    /// An image supplied as a reference for a scene entity or for scene
    /// creation. Perception results should already be applied to the WorldView
    /// before this signal is processed — Session uses the inferred properties in
    /// the entity index to produce a plan.
    ReferenceImage {
        url: String,
        entity_ref: Option<String>,
    },
}

impl Signal {
    pub fn kind(&self) -> &'static str {
        match self {
            Signal::NaturalLanguage { .. } => "naturalLanguage",
            Signal::SelectionChanged { .. } => "selectionChanged",
            Signal::WorldChanged { .. } => "worldChanged",
            Signal::UserCorrection { .. } => "userCorrection",
            Signal::ReferenceImage { .. } => "referenceImage",
        }
    }
}
