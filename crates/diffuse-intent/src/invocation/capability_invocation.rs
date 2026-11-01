//! Confirmation prompts and answers — the data a destructive or ambiguous action
//! produces before it is allowed to run.
//!
//! Every type here is `Codable` in Swift and part of the persisted wire format, so the
//! enum raw values are written out explicitly rather than derived (`choose_one`,
//! `approve_destructive`).

use diffuse_capability::support::swift_date::SwiftDate;
use serde::{Deserialize, Serialize};

/// What kind of decision a question asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum ConfirmationQuestionKind {
    #[serde(rename = "choose_one")]
    ChooseOne,
    #[serde(rename = "approve_destructive")]
    ApproveDestructive,
}

impl ConfirmationQuestionKind {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            ConfirmationQuestionKind::ChooseOne => "choose_one",
            ConfirmationQuestionKind::ApproveDestructive => "approve_destructive",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "choose_one" => Some(ConfirmationQuestionKind::ChooseOne),
            "approve_destructive" => Some(ConfirmationQuestionKind::ApproveDestructive),
            _ => None,
        }
    }
}

/// How alarming a question is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConfirmationSeverity {
    Info,
    Warn,
    Destructive,
}

/// One selectable answer.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfirmationOption {
    pub id: String,
    pub label_short: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub label_detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub side_effect_summary: Option<String>,
}

impl ConfirmationOption {
    pub fn new(id: impl Into<String>, label_short: impl Into<String>) -> Self {
        ConfirmationOption {
            id: id.into(),
            label_short: label_short.into(),
            label_detail: None,
            side_effect_summary: None,
        }
    }
}

/// One question put to a human.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfirmationQuestion {
    pub id: String,
    pub kind: ConfirmationQuestionKind,
    pub prompt_short: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub prompt_detail: Option<String>,
    pub options: Vec<ConfirmationOption>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub default_option_id: Option<String>,
    pub severity: ConfirmationSeverity,
    pub reversible: bool,
    pub ambiguity_score: f64,
    pub source_proposal_ids: Vec<String>,
}

impl ConfirmationQuestion {
    pub fn new(
        id: impl Into<String>,
        kind: ConfirmationQuestionKind,
        prompt_short: impl Into<String>,
        severity: ConfirmationSeverity,
        reversible: bool,
        ambiguity_score: f64,
    ) -> Self {
        ConfirmationQuestion {
            id: id.into(),
            kind,
            prompt_short: prompt_short.into(),
            prompt_detail: None,
            options: Vec::new(),
            default_option_id: None,
            severity,
            reversible,
            ambiguity_score,
            source_proposal_ids: Vec::new(),
        }
    }
}

/// A group of questions answered together.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfirmationRequestBatch {
    pub batch_id: String,
    pub origin: String,
    pub correlation_id: String,
    pub questions: Vec<ConfirmationQuestion>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub context_snapshot_uri: Option<String>,
}

impl ConfirmationRequestBatch {
    pub fn new(
        batch_id: impl Into<String>,
        origin: impl Into<String>,
        correlation_id: impl Into<String>,
        questions: Vec<ConfirmationQuestion>,
    ) -> Self {
        ConfirmationRequestBatch {
            batch_id: batch_id.into(),
            origin: origin.into(),
            correlation_id: correlation_id.into(),
            questions,
            context_snapshot_uri: None,
        }
    }
}

/// What the human did with a question.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConfirmationAnswerOutcome {
    Accepted,
    Rejected,
    Skipped,
    Renamed,
    Scoped,
    Adjusted,
}

/// One answer.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfirmationAnswer {
    pub question_id: String,
    pub outcome: ConfirmationAnswerOutcome,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub picked_option_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub note: Option<String>,
}

impl ConfirmationAnswer {
    pub fn new(question_id: impl Into<String>, outcome: ConfirmationAnswerOutcome) -> Self {
        ConfirmationAnswer {
            question_id: question_id.into(),
            outcome,
            picked_option_id: None,
            note: None,
        }
    }
}

/// The answers to a whole batch.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfirmationResolution {
    pub batch_id: String,
    pub correlation_id: String,
    pub answers: Vec<ConfirmationAnswer>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub user_id: Option<String>,
    /// Swift's `Date`, i.e. seconds since 2001-01-01.
    pub decided_at: SwiftDate,
    pub partial: bool,
}

impl ConfirmationResolution {
    pub fn new(
        batch_id: impl Into<String>,
        correlation_id: impl Into<String>,
        answers: Vec<ConfirmationAnswer>,
        partial: bool,
    ) -> Self {
        ConfirmationResolution {
            batch_id: batch_id.into(),
            correlation_id: correlation_id.into(),
            answers,
            user_id: None,
            decided_at: SwiftDate::now(),
            partial,
        }
    }
}

/// Why a capability invocation could not be planned.
///
/// The `capabilityDenied` case is added by the invocation planner, which owns
/// `CapabilityValidationFailure`; it is not duplicated here.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum CapabilityInvocationPlannerError {
    #[error("transaction is missing IntentIR")]
    MissingIntent,
    #[error("transaction {0} is forbidden by approval policy")]
    ApprovalForbidden(String),
    #[error("capability validation failed: {}", .0.iter().map(|failure| format!("{}: {}", failure.verb, failure.reason)).collect::<Vec<_>>().join("; "))]
    CapabilityDenied(Vec<super::capability_invocation_planning::CapabilityValidationFailure>),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn question_kinds_use_their_snake_case_raw_values() {
        assert_eq!(
            ConfirmationQuestionKind::ChooseOne.raw_value(),
            "choose_one"
        );
        assert_eq!(
            ConfirmationQuestionKind::ApproveDestructive.raw_value(),
            "approve_destructive"
        );
        let json = serde_json::to_string(&ConfirmationQuestionKind::ApproveDestructive)
            .expect("serialize");
        assert_eq!(json, "\"approve_destructive\"");
    }

    #[test]
    fn an_unknown_kind_does_not_decode() {
        assert!(ConfirmationQuestionKind::from_raw_value("approveDestructive").is_none());
    }

    #[test]
    fn a_question_omits_absent_optional_fields() {
        let question = ConfirmationQuestion::new(
            "q1",
            ConfirmationQuestionKind::ChooseOne,
            "Which one?",
            ConfirmationSeverity::Warn,
            true,
            0.5,
        );
        let json = serde_json::to_string(&question).expect("serialize");
        assert!(!json.contains("promptDetail"), "got {json}");
        assert!(!json.contains("defaultOptionId"));
        assert!(json.contains("\"severity\":\"warn\""));
    }

    #[test]
    fn a_batch_round_trips() {
        let batch = ConfirmationRequestBatch::new("b1", "editor", "corr-1", Vec::new());
        let json = serde_json::to_string(&batch).expect("serialize");
        let restored: ConfirmationRequestBatch = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(restored, batch);
    }

    #[test]
    fn a_resolution_records_the_swift_date() {
        let resolution = ConfirmationResolution::new("b1", "corr-1", Vec::new(), true);
        let json = serde_json::to_string(&resolution).expect("serialize");
        assert!(json.contains("\"partial\":true"));
        assert!(json.contains("decidedAt"));
        let restored: ConfirmationResolution = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(restored, resolution);
    }

    #[test]
    fn planner_errors_describe_themselves_as_swift_did() {
        assert_eq!(
            CapabilityInvocationPlannerError::MissingIntent.to_string(),
            "transaction is missing IntentIR"
        );
        assert_eq!(
            CapabilityInvocationPlannerError::ApprovalForbidden("tx-9".to_string()).to_string(),
            "transaction tx-9 is forbidden by approval policy"
        );
    }
}
