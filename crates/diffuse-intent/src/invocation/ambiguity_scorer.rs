//! Score how ambiguous an `IntentIR` is.
//!
//! The score decides whether an intent applies immediately, gets a brief summary, or
//! blocks for clarification — so the weights and thresholds below are behaviour, not
//! tunables to "clean up". Each signal contributes a fixed weight and the total is
//! clamped to `0...1`; the level is then the highest threshold the score reaches.
//!
//! The confidence contribution is **not** a flat penalty: it scales with how far below
//! the floor the confidence sits, and an AI intent is penalised more heavily (0.35) than
//! a human one (0.25) for the same shortfall.

use std::collections::BTreeSet;

use crate::invocation::capability_invocation::{
    ConfirmationOption, ConfirmationQuestion, ConfirmationQuestionKind, ConfirmationSeverity,
};
use crate::planning::intent_ir::{IntentIR, IntentSource};

/// How much ambiguity an intent carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum AmbiguityLevel {
    /// Fully specified; apply immediately.
    Clear,
    /// Some parameters inferred or defaulted.
    Low,
    /// Multiple interpretations are plausible.
    Medium,
    /// Target, scope or outcome genuinely unclear.
    High,
}

impl AmbiguityLevel {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            AmbiguityLevel::Clear => "clear",
            AmbiguityLevel::Low => "low",
            AmbiguityLevel::Medium => "medium",
            AmbiguityLevel::High => "high",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "clear" => Some(AmbiguityLevel::Clear),
            "low" => Some(AmbiguityLevel::Low),
            "medium" => Some(AmbiguityLevel::Medium),
            "high" => Some(AmbiguityLevel::High),
            _ => None,
        }
    }

    pub const ALL: [AmbiguityLevel; 4] = [
        AmbiguityLevel::Clear,
        AmbiguityLevel::Low,
        AmbiguityLevel::Medium,
        AmbiguityLevel::High,
    ];
}

/// The reasons a score went up.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum AmbiguitySignalKind {
    LowConfidence,
    NoTarget,
    MultipleTargets,
    MissingRequiredArgument,
    DestructiveVerb,
    AiLowConfidence,
    NoEvidence,
}

impl AmbiguitySignalKind {
    pub const fn raw_value(&self) -> &'static str {
        match self {
            AmbiguitySignalKind::LowConfidence => "low_confidence",
            AmbiguitySignalKind::NoTarget => "no_target",
            AmbiguitySignalKind::MultipleTargets => "multiple_targets",
            AmbiguitySignalKind::MissingRequiredArgument => "missing_required_argument",
            AmbiguitySignalKind::DestructiveVerb => "destructive_verb",
            AmbiguitySignalKind::AiLowConfidence => "ai_low_confidence",
            AmbiguitySignalKind::NoEvidence => "no_evidence",
        }
    }
}

/// One contributing factor.
#[derive(Clone, Debug, PartialEq)]
pub struct AmbiguitySignal {
    pub kind: AmbiguitySignalKind,
    /// A compact note surfaced in the confirmation UI or debug log.
    pub note: String,
    /// Contribution to the `0...1` score, before clamping.
    pub weight: f64,
}

impl AmbiguitySignal {
    pub fn new(kind: AmbiguitySignalKind, note: impl Into<String>, weight: f64) -> Self {
        AmbiguitySignal {
            kind,
            note: note.into(),
            weight,
        }
    }
}

/// The result of scoring one intent.
#[derive(Clone, Debug, PartialEq)]
pub struct AmbiguityScore {
    pub score: f64,
    pub level: AmbiguityLevel,
    pub signals: Vec<AmbiguitySignal>,
}

impl AmbiguityScore {
    pub fn new(score: f64, level: AmbiguityLevel, signals: Vec<AmbiguitySignal>) -> Self {
        AmbiguityScore {
            score,
            level,
            signals,
        }
    }
}

/// Weights and thresholds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AmbiguityScorerConfig {
    pub high_threshold: f64,
    pub medium_threshold: f64,
    pub low_threshold: f64,
    pub confidence_floor: f64,
}

impl AmbiguityScorerConfig {
    /// Swift's `AmbiguityScorerConfig.default`.
    pub const fn default_config() -> Self {
        AmbiguityScorerConfig {
            high_threshold: 0.65,
            medium_threshold: 0.40,
            low_threshold: 0.15,
            confidence_floor: 0.75,
        }
    }
}

impl Default for AmbiguityScorerConfig {
    fn default() -> Self {
        Self::default_config()
    }
}

/// What the caller knows about the intent's surroundings.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AmbiguityScoringContext {
    pub candidate_entity_ids: Vec<u64>,
    pub selected_entity_id: Option<u64>,
    pub requires_target: bool,
    pub is_verb_destructive: bool,
    pub required_argument_names: BTreeSet<String>,
}

/// Stateless scorer.
#[derive(Clone, Debug, Default)]
pub struct AmbiguityScorer {
    pub config: AmbiguityScorerConfig,
}

impl AmbiguityScorer {
    pub fn new(config: AmbiguityScorerConfig) -> Self {
        AmbiguityScorer { config }
    }

    /// Score one intent.
    pub fn score(&self, intent: &IntentIR, context: &AmbiguityScoringContext) -> AmbiguityScore {
        let mut signals: Vec<AmbiguitySignal> = Vec::new();
        let mut raw = 0.0f64;

        let confidence_floor = self.config.confidence_floor.max(f64::EPSILON);
        let confidence = intent.confidence.clamp(0.0, 1.0);

        // Confidence: the shortfall below the floor, weighted by author kind.
        if confidence < confidence_floor {
            let shortfall = 1.0 - confidence / confidence_floor;
            if intent.source == IntentSource::Ai {
                let weight = 0.35 * shortfall;
                signals.push(AmbiguitySignal::new(
                    AmbiguitySignalKind::AiLowConfidence,
                    format!(
                        "AI confidence {:.0}% < floor {:.0}%",
                        confidence * 100.0,
                        confidence_floor * 100.0
                    ),
                    weight,
                ));
                raw += weight;
            } else {
                let weight = 0.25 * shortfall;
                signals.push(AmbiguitySignal::new(
                    AmbiguitySignalKind::LowConfidence,
                    format!("confidence {:.0}% < floor", confidence * 100.0),
                    weight,
                ));
                raw += weight;
            }
        }

        // Target selection.
        if intent.target_object_ids.len() > 1 {
            let weight = 0.20;
            signals.push(AmbiguitySignal::new(
                AmbiguitySignalKind::MultipleTargets,
                format!(
                    "{} explicit targetObjectIDs",
                    intent.target_object_ids.len()
                ),
                weight,
            ));
            raw += weight;
        } else if context.requires_target
            && intent.target_object_ids.is_empty()
            && context.selected_entity_id.is_none()
        {
            if context.candidate_entity_ids.len() > 1 {
                let weight = 0.25;
                signals.push(AmbiguitySignal::new(
                    AmbiguitySignalKind::MultipleTargets,
                    format!("{} candidate targets", context.candidate_entity_ids.len()),
                    weight,
                ));
                raw += weight;
            } else if context.candidate_entity_ids.len() == 1 {
                let weight = 0.10;
                signals.push(AmbiguitySignal::new(
                    AmbiguitySignalKind::NoTarget,
                    "target must be inferred from one candidate",
                    weight,
                ));
                raw += weight;
            } else {
                let weight = 0.30;
                signals.push(AmbiguitySignal::new(
                    AmbiguitySignalKind::NoTarget,
                    "no targetObjectIDs specified",
                    weight,
                ));
                raw += weight;
            }
        }

        // Missing required arguments: 0.20 each.
        let provided: BTreeSet<&str> = intent.arguments.keys().map(String::as_str).collect();
        let missing: Vec<&String> = context
            .required_argument_names
            .iter()
            .filter(|name| !provided.contains(name.as_str()))
            .collect();
        if !missing.is_empty() {
            let weight = 0.20 * missing.len() as f64;
            let joined = missing
                .iter()
                .map(|name| name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            signals.push(AmbiguitySignal::new(
                AmbiguitySignalKind::MissingRequiredArgument,
                format!("missing: {joined}"),
                weight,
            ));
            raw += weight;
        }

        // A destructive verb always adds a confirmation affordance.
        if context.is_verb_destructive {
            signals.push(AmbiguitySignal::new(
                AmbiguitySignalKind::DestructiveVerb,
                format!("verb '{}' is marked destructive", intent.verb),
                0.15,
            ));
            raw += 0.15;
        }

        // Evidence is only required of AI-authored intents.
        if intent.source == IntentSource::Ai && intent.evidence.is_empty() {
            signals.push(AmbiguitySignal::new(
                AmbiguitySignalKind::NoEvidence,
                "no evidence attached to intent",
                0.10,
            ));
            raw += 0.10;
        }

        let clamped = raw.clamp(0.0, 1.0);
        let level = if clamped >= self.config.high_threshold {
            AmbiguityLevel::High
        } else if clamped >= self.config.medium_threshold {
            AmbiguityLevel::Medium
        } else if clamped >= self.config.low_threshold {
            AmbiguityLevel::Low
        } else {
            AmbiguityLevel::Clear
        };

        AmbiguityScore::new(clamped, level, signals)
    }

    /// Build a confirmation question for a non-clear score.
    ///
    /// Returns `None` for `Clear`: an unambiguous intent needs no confirmation beyond
    /// whatever policy already requires.
    pub fn make_question(
        &self,
        intent: &IntentIR,
        score: &AmbiguityScore,
        options: Vec<ConfirmationOption>,
    ) -> Option<ConfirmationQuestion> {
        if score.level < AmbiguityLevel::Low {
            return None;
        }

        let note_lines = score
            .signals
            .iter()
            .map(|signal| format!("- {}", signal.note))
            .collect::<Vec<_>>()
            .join("\n");
        let has_destructive = score
            .signals
            .iter()
            .any(|signal| signal.kind == AmbiguitySignalKind::DestructiveVerb);

        let prompt_detail = if note_lines.is_empty() {
            format!("Ambiguity: {}", score.level.raw_value())
        } else {
            format!("Ambiguity: {}\n{}", score.level.raw_value(), note_lines)
        };

        let options = if options.is_empty() {
            self.default_options(intent)
        } else {
            options
        };

        let mut question = ConfirmationQuestion::new(
            format!("ambiguity:{}", intent.id),
            if has_destructive {
                ConfirmationQuestionKind::ApproveDestructive
            } else {
                ConfirmationQuestionKind::ChooseOne
            },
            if intent.summary.is_empty() {
                format!("Confirm: {}", intent.verb)
            } else {
                intent.summary.clone()
            },
            if has_destructive {
                ConfirmationSeverity::Destructive
            } else if score.level >= AmbiguityLevel::High {
                ConfirmationSeverity::Warn
            } else {
                ConfirmationSeverity::Info
            },
            true,
            score.score,
        );
        question.prompt_detail = Some(prompt_detail);
        question.options = options;
        question.default_option_id = Some("confirm".to_string());
        question.source_proposal_ids = vec![intent.id.clone()];
        Some(question)
    }

    fn default_options(&self, intent: &IntentIR) -> Vec<ConfirmationOption> {
        let mut apply = ConfirmationOption::new("confirm", "Apply");
        apply.label_detail = Some(format!("Proceed with '{}'", intent.verb));
        let mut reject = ConfirmationOption::new("skip", "Reject");
        reject.label_detail = Some("Discard this intent".to_string());
        vec![apply, reject]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::planning::intent_ir::IntentEvidence;

    fn context(requires_target: bool) -> AmbiguityScoringContext {
        AmbiguityScoringContext {
            requires_target,
            ..Default::default()
        }
    }

    #[test]
    fn a_fully_specified_intent_scores_clear() {
        let mut intent = IntentIR::new("scene.delete", "delete it", IntentSource::Human);
        intent.target_object_ids.push("scene:1".to_string());
        let score = AmbiguityScorer::new(AmbiguityScorerConfig::default_config())
            .score(&intent, &context(true));
        assert_eq!(score.level, AmbiguityLevel::Clear);
        assert_eq!(score.score, 0.0);
        assert!(score.signals.is_empty());
    }

    #[test]
    fn an_ai_intent_without_evidence_is_penalised() {
        let intent = IntentIR::new("scene.delete", "delete it", IntentSource::Ai);
        let score = AmbiguityScorer::new(AmbiguityScorerConfig::default_config())
            .score(&intent, &context(false));
        // No evidence (0.10) only; confidence is at its default of 1.0.
        assert!((score.score - 0.10).abs() < 1e-9, "got {}", score.score);
        assert!(
            score
                .signals
                .iter()
                .any(|signal| signal.kind == AmbiguitySignalKind::NoEvidence)
        );
    }

    #[test]
    fn a_human_intent_is_not_penalised_for_missing_evidence() {
        let intent = IntentIR::new("scene.delete", "delete it", IntentSource::Human);
        let score = AmbiguityScorer::new(AmbiguityScorerConfig::default_config())
            .score(&intent, &context(false));
        assert_eq!(score.score, 0.0);
    }

    #[test]
    fn ai_confidence_shortfall_weighs_more_than_a_human_one() {
        let mut ai = IntentIR::new("v", "s", IntentSource::Ai);
        ai.confidence = 0.0;
        ai.evidence.push(IntentEvidence::new("e", "e"));
        let mut human = IntentIR::new("v", "s", IntentSource::Human);
        human.confidence = 0.0;

        let scorer = AmbiguityScorer::new(AmbiguityScorerConfig::default_config());
        let ai_score = scorer.score(&ai, &context(false)).score;
        let human_score = scorer.score(&human, &context(false)).score;
        assert!(
            ai_score > human_score,
            "ai {ai_score} must exceed human {human_score}"
        );
        assert!((ai_score - 0.35).abs() < 1e-9);
        assert!((human_score - 0.25).abs() < 1e-9);
    }

    #[test]
    fn multiple_explicit_targets_score_higher_than_one() {
        let mut intent = IntentIR::new("v", "s", IntentSource::Human);
        intent.target_object_ids.push("a".to_string());
        intent.target_object_ids.push("b".to_string());
        let score = AmbiguityScorer::new(AmbiguityScorerConfig::default_config())
            .score(&intent, &context(false));
        assert!((score.score - 0.20).abs() < 1e-9);
    }

    #[test]
    fn no_candidates_scores_higher_than_one_candidate() {
        let scorer = AmbiguityScorer::new(AmbiguityScorerConfig::default_config());
        let intent = IntentIR::new("v", "s", IntentSource::Human);

        let none = scorer.score(&intent, &context(true)).score;
        let mut one = context(true);
        one.candidate_entity_ids.push(7);
        let single = scorer.score(&intent, &one).score;
        assert!((none - 0.30).abs() < 1e-9, "no candidates: {none}");
        assert!((single - 0.10).abs() < 1e-9, "one candidate: {single}");
    }

    #[test]
    fn a_selection_suppresses_the_target_signal() {
        let mut ctx = context(true);
        ctx.selected_entity_id = Some(3);
        ctx.candidate_entity_ids = vec![1, 2, 3];
        let intent = IntentIR::new("v", "s", IntentSource::Human);
        let score =
            AmbiguityScorer::new(AmbiguityScorerConfig::default_config()).score(&intent, &ctx);
        assert_eq!(score.score, 0.0, "a selection resolves the target");
    }

    #[test]
    fn each_missing_argument_adds_weight() {
        let mut ctx = context(false);
        ctx.required_argument_names.insert("a".to_string());
        ctx.required_argument_names.insert("b".to_string());
        let intent = IntentIR::new("v", "s", IntentSource::Human);
        let score =
            AmbiguityScorer::new(AmbiguityScorerConfig::default_config()).score(&intent, &ctx);
        assert!((score.score - 0.40).abs() < 1e-9);
    }

    #[test]
    fn the_score_is_clamped_to_one() {
        let mut ctx = context(true);
        ctx.is_verb_destructive = true;
        for name in ["a", "b", "c", "d", "e"] {
            ctx.required_argument_names.insert(name.to_string());
        }
        let mut intent = IntentIR::new("v", "s", IntentSource::Ai);
        intent.confidence = 0.0;
        let score =
            AmbiguityScorer::new(AmbiguityScorerConfig::default_config()).score(&intent, &ctx);
        assert_eq!(score.score, 1.0, "weights must be clamped");
        assert_eq!(score.level, AmbiguityLevel::High);
    }

    #[test]
    fn thresholds_map_to_levels() {
        let config = AmbiguityScorerConfig::default_config();
        let scorer = AmbiguityScorer::new(config);
        let mut ctx = context(false);

        // 0.15 destructive-only -> Low, exactly at the low threshold.
        ctx.is_verb_destructive = true;
        let intent = IntentIR::new("v", "s", IntentSource::Human);
        assert_eq!(scorer.score(&intent, &ctx).level, AmbiguityLevel::Low);
    }

    #[test]
    fn a_clear_score_produces_no_question() {
        let intent = IntentIR::new("v", "s", IntentSource::Human);
        let score = AmbiguityScore::new(0.0, AmbiguityLevel::Clear, Vec::new());
        assert!(
            AmbiguityScorer::default()
                .make_question(&intent, &score, Vec::new())
                .is_none()
        );
    }

    #[test]
    fn a_destructive_signal_selects_the_destructive_question_kind() {
        let mut ctx = context(false);
        ctx.is_verb_destructive = true;
        let intent = IntentIR::new("scene.delete", "", IntentSource::Human);
        let scorer = AmbiguityScorer::new(AmbiguityScorerConfig::default_config());
        let score = scorer.score(&intent, &ctx);
        let question = scorer
            .make_question(&intent, &score, Vec::new())
            .expect("a question");

        assert_eq!(question.kind, ConfirmationQuestionKind::ApproveDestructive);
        assert_eq!(question.severity, ConfirmationSeverity::Destructive);
        assert_eq!(question.id, format!("ambiguity:{}", intent.id));
        assert_eq!(question.prompt_short, "Confirm: scene.delete");
        assert_eq!(question.default_option_id.as_deref(), Some("confirm"));
        assert_eq!(question.options.len(), 2);
    }

    #[test]
    fn a_high_score_without_destruction_warns() {
        let mut ctx = context(true);
        for name in ["a", "b", "c"] {
            ctx.required_argument_names.insert(name.to_string());
        }
        let intent = IntentIR::new("v", "s", IntentSource::Human);
        let scorer = AmbiguityScorer::new(AmbiguityScorerConfig::default_config());
        let score = scorer.score(&intent, &ctx);
        assert_eq!(score.level, AmbiguityLevel::High);
        let question = scorer
            .make_question(&intent, &score, Vec::new())
            .expect("a question");
        assert_eq!(question.severity, ConfirmationSeverity::Warn);
        assert_eq!(question.kind, ConfirmationQuestionKind::ChooseOne);
        assert!(question.prompt_detail.expect("detail").contains("missing:"));
    }
}
