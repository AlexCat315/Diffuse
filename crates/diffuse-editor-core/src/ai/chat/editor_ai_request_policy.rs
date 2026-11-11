//! `Editor/Sources/EditorCore/AI/Chat/EditorAIRequestPolicy.swift`.

/// Why an AI action was rejected before it started.
pub(crate) struct EditorAIRequestPolicy;

impl EditorAIRequestPolicy {
    pub(crate) const PENDING_CONFIRMATION_MESSAGE: &'static str =
        "Resolve the pending confirmation before submitting another AI action.";
    pub(crate) const REQUEST_IN_FLIGHT_MESSAGE: &'static str =
        "Wait for the current AI request to finish before submitting another.";

    pub(crate) fn rejection_message(
        has_pending_confirmation: bool,
        request_in_flight: bool,
    ) -> Option<&'static str> {
        if has_pending_confirmation {
            return Some(Self::PENDING_CONFIRMATION_MESSAGE);
        }
        if request_in_flight {
            return Some(Self::REQUEST_IN_FLIGHT_MESSAGE);
        }
        None
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub(crate) enum EditorPlanSubmissionError {
    #[error("{}", EditorAIRequestPolicy::PENDING_CONFIRMATION_MESSAGE)]
    PendingConfirmation,
    #[error(
        "The plan targets locked entities: {}. Unlock them before applying the action.",
        locked_entity_labels(.0)
    )]
    LockedEntities(Vec<u64>),
}

fn locked_entity_labels(entity_ids: &[u64]) -> String {
    let mut sorted = entity_ids.to_vec();
    sorted.sort_unstable();
    sorted
        .iter()
        .map(u64::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}
