//! `CapabilityValidator` — registry lookup, phase gating and preconditions.

use thiserror::Error;

fn format_violations(violations: &[PreconditionViolation]) -> String {
    violations
        .iter()
        .map(|violation| violation.detail.as_str())
        .collect::<Vec<_>>()
        .join("; ")
}

use crate::capability_descriptor::CapabilityDescriptor;
use crate::capability_registry::CapabilityRegistry;
use crate::drafts::precondition_checker::{
    PreconditionCheckInput, PreconditionChecker, PreconditionViolation,
};
use crate::release::release_phase_gate::ReleasePhaseGate;

#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum CapabilityValidationError {
    /// No descriptor is registered for this verb.
    #[error("unknown capability verb: '{0}'")]
    UnknownVerb(String),
    /// The capability exists but is blocked by the current release phase gate.
    #[error("{reason}")]
    PhaseDenied { verb: String, reason: String },
    /// One or more preconditions were not satisfied.
    #[error("precondition violations: {}", format_violations(.0))]
    PreconditionViolations(Vec<PreconditionViolation>),
}

/// Validated result returned on success.
#[derive(Clone, Debug, PartialEq)]
pub struct CapabilityValidationResult {
    pub descriptor: CapabilityDescriptor,
}

impl CapabilityValidationResult {
    #[inline]
    pub fn new(descriptor: CapabilityDescriptor) -> Self {
        CapabilityValidationResult { descriptor }
    }

    #[inline]
    pub fn requires_confirmation(&self) -> bool {
        self.descriptor.requires_confirmation
    }

    #[inline]
    pub fn is_destructive(&self) -> bool {
        self.descriptor.is_destructive
    }

    #[inline]
    pub fn domain(&self) -> &str {
        &self.descriptor.domain
    }
}

/// Combines registry lookup, phase gating and precondition evaluation.
#[derive(Clone, Debug)]
pub struct CapabilityValidator {
    registry: CapabilityRegistry,
    checker: PreconditionChecker,
    gate: ReleasePhaseGate,
}

impl CapabilityValidator {
    /// Swift defaults: the built-in registry and a `.stable` gate.
    pub fn new(registry: CapabilityRegistry, gate: ReleasePhaseGate) -> Self {
        CapabilityValidator {
            registry,
            checker: PreconditionChecker::new(),
            gate,
        }
    }

    pub fn with_defaults() -> Self {
        Self::new(
            CapabilityRegistry::default_registry(),
            ReleasePhaseGate::default(),
        )
    }

    /// Validates that `verb` is known, phase-allowed, and all preconditions pass.
    /// Phase denial takes priority over precondition violations.
    pub fn validate(
        &self,
        verb: &str,
        input: &PreconditionCheckInput,
    ) -> Result<CapabilityValidationResult, CapabilityValidationError> {
        let Some(descriptor) = self.registry.descriptor(verb) else {
            return Err(CapabilityValidationError::UnknownVerb(verb.to_string()));
        };
        if let Some(reason) = self.gate.denied_reason(&descriptor) {
            return Err(CapabilityValidationError::PhaseDenied {
                verb: verb.to_string(),
                reason,
            });
        }
        let violations = self.checker.check(&descriptor.preconditions, input);
        if !violations.is_empty() {
            return Err(CapabilityValidationError::PreconditionViolations(
                violations,
            ));
        }
        Ok(CapabilityValidationResult::new(descriptor))
    }

    /// Non-throwing variant for diagnostic UIs.
    pub fn probe(
        &self,
        verb: &str,
        input: &PreconditionCheckInput,
    ) -> (
        Option<CapabilityValidationResult>,
        Option<CapabilityValidationError>,
    ) {
        match self.validate(verb, input) {
            Ok(result) => (Some(result), None),
            Err(error) => (None, Some(error)),
        }
    }
}
