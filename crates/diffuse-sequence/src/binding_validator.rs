//! `BindingValidator` — blocks render submission while bindings are unresolved.

use thiserror::Error;

use crate::sequence_document::{
    Binding, BindingFallbackStrategy, BindingResolutionStatus, SceneTargetReference,
    SequenceDocument,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RenderValidationResult {
    Ok,
    Blocked(Vec<String>),
}

#[derive(Clone, Debug, PartialEq, Eq, Error)]
#[error("Binding '{binding_id}' is {status}; cannot resolve target for render.")]
pub struct BindingError {
    pub binding_id: String,
    pub status: &'static str,
}

pub enum BindingValidator {}

impl BindingValidator {
    /// Every binding across every shot must be `bound`; required before render
    /// submission.
    pub fn validate_for_render(document: &SequenceDocument) -> RenderValidationResult {
        let mut blocked_ids: Vec<String> = Vec::new();
        for shot in &document.shots {
            Self::collect_blocked_bindings(&shot.camera_binding, &mut blocked_ids);
            for track in &shot.tracks {
                for clip in &track.clips {
                    for binding in &clip.bindings {
                        Self::collect_blocked_bindings(binding, &mut blocked_ids);
                    }
                }
            }
        }
        if blocked_ids.is_empty() {
            RenderValidationResult::Ok
        } else {
            RenderValidationResult::Blocked(blocked_ids)
        }
    }

    /// Resolves a single binding at evaluation time. `None` means the binding is
    /// skipped; `.error` fallback raises on a stale or conflicting binding.
    pub fn resolved_target(
        binding: &Binding,
    ) -> Result<Option<SceneTargetReference>, BindingError> {
        match binding.resolution_status {
            BindingResolutionStatus::Bound => Ok(binding.resolved_target.clone()),
            BindingResolutionStatus::Unbound
            | BindingResolutionStatus::Stale
            | BindingResolutionStatus::Conflict => match binding.fallback_strategy {
                BindingFallbackStrategy::Skip => Ok(None),
                BindingFallbackStrategy::Proxy => Ok(None),
                BindingFallbackStrategy::Error => Err(BindingError {
                    binding_id: binding.id.clone(),
                    status: binding.resolution_status.raw_value(),
                }),
            },
        }
    }

    fn collect_blocked_bindings(binding: &Binding, ids: &mut Vec<String>) {
        match binding.resolution_status {
            BindingResolutionStatus::Bound => {}
            BindingResolutionStatus::Unbound
            | BindingResolutionStatus::Stale
            | BindingResolutionStatus::Conflict => ids.push(binding.id.clone()),
        }
    }
}
