//! Language contribution validation.
//!
//! Ported from
//! `Engine/Sources/PluginRuntime/Contribution/Languages/LanguagePoint.swift`.
//!
//! This is the only place in the crate that compiles a pattern the package
//! supplies at run time: `grammar.rules[].pattern` (colouring) and
//! `outline.rules[].pattern` (headings), both with `anchorsMatchLines`, the
//! latter also requiring a capture group. See `crate::pattern::plugin_pattern`
//! for the supported subset and why a rejection there is fail-closed.

use std::collections::BTreeSet;

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_contract::PluginContract;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::languages::language::{
    LanguageContribution, OutlineContribution, SyntaxGrammarContribution, SyntaxToken,
};
use crate::contribution::processes::inputs::document_format_input_type;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};
use crate::pattern::plugin_pattern;
use crate::pattern::{file_extension, grapheme_count};

pub enum LanguageContributionPoint {}

impl LanguageContributionPoint {
    fn valid_grammar(grammar: &SyntaxGrammarContribution) -> bool {
        if grammar.rules.is_empty() || grammar.rules.len() > 64 {
            return false;
        }
        grammar.rules.iter().all(|rule| {
            !rule.pattern.is_empty()
                && grapheme_count(&rule.pattern) <= 512
                && SyntaxToken::from_raw_value(&rule.token).is_some()
                && plugin_pattern::compile(&rule.pattern).is_ok()
        })
    }

    fn valid_outline(outline: &OutlineContribution) -> bool {
        if outline.rules.is_empty() || outline.rules.len() > 32 {
            return false;
        }
        outline.rules.iter().all(|rule| {
            !rule.pattern.is_empty()
                && grapheme_count(&rule.pattern) <= 512
                && (1..=6).contains(&rule.level)
                // `expression.numberOfCaptureGroups >= 1`
                && plugin_pattern::compile(&rule.pattern)
                    .is_ok_and(|compiled| compiled.capture_groups >= 1)
        })
    }
}

impl ContributionPointSpec for LanguageContributionPoint {
    type Descriptor = LanguageContribution;

    const ID: &'static str = "cove.language/v1";

    fn validate(
        language: &LanguageContribution,
        host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        let unique: BTreeSet<&String> = language.extensions.iter().collect();
        let server_ok = language.server.as_ref().is_none_or(|server| {
            host.processes
                .iter()
                .any(|permission| permission.id == server.process)
        });
        if !(ContributionValidation::identifier(&language.id)
            && ContributionValidation::title(&language.title)
            && !language.extensions.is_empty()
            && unique.len() == language.extensions.len()
            && language
                .extensions
                .iter()
                .all(|extension| file_extension(extension, true))
            && language
                .icon
                .as_ref()
                .is_none_or(|icon| crate::pattern::icon(icon, 1, 32))
            && server_ok
            && language
                .grammar
                .as_ref()
                .is_none_or(LanguageContributionPoint::valid_grammar)
            && language
                .outline
                .as_ref()
                .is_none_or(LanguageContributionPoint::valid_outline)
            && language
                .format
                .as_ref()
                .is_none_or(|format| ContributionValidation::identifier(&format.entry_point)))
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }

    fn validate_runtime(
        language: &LanguageContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        if let Some(format) = &language.format {
            let matches = contract
                .and_then(|contract| {
                    contract
                        .capability_inputs
                        .iter()
                        .find(|input| input.name == format.entry_point)
                })
                .is_some_and(|input| input.input_type == document_format_input_type());
            if !matches {
                return Err(PluginManifestValidationError::InvalidContribution(
                    Self::ID.to_string(),
                ));
            }
        }
        // Swift threw `PluginPackageError.runtimeRequired` here — a different
        // error family from the validation enum, so `validate_runtime_error`
        // below is the faithful form and this signature keeps the enum's case.
        if language.server.is_some() && contract.is_none() {
            return Err(PluginManifestValidationError::InvalidContribution(
                crate::contract::plugin_package::PluginPackageError::RuntimeRequired.to_string(),
            ));
        }
        Ok(())
    }
}

impl LanguageContributionPoint {
    /// The typed form of `validateRuntime`, used where the caller needs to
    /// distinguish the package error from a contribution error.
    pub fn validate_runtime_error(
        language: &LanguageContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), crate::PluginError> {
        if let Some(format) = &language.format {
            let matches = contract
                .and_then(|contract| {
                    contract
                        .capability_inputs
                        .iter()
                        .find(|input| input.name == format.entry_point)
                })
                .is_some_and(|input| input.input_type == document_format_input_type());
            if !matches {
                return Err(PluginManifestValidationError::InvalidContribution(
                    Self::ID.to_string(),
                )
                .into());
            }
        }
        if language.server.is_some() && contract.is_none() {
            return Err(
                crate::contract::plugin_package::PluginPackageError::RuntimeRequired.into(),
            );
        }
        Ok(())
    }
}
