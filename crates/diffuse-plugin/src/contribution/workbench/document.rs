//! Another way to show a text document.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Workbench/Document.swift`.
//! The editor keeps the text and offers the view beside it; the entry point
//! serves it through the view protocol, with the path and current text as
//! context.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_contract::PluginContract;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};
use crate::contribution::workbench::view::view_input_type;
use crate::pattern::file_extension;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentViewContribution {
    pub id: String,
    pub title: String,
    /// File extensions the view applies to, without the dot.
    pub extensions: Vec<String>,
    /// `func(input: record { view: string, state: string, event: string, context: string }) -> string`.
    pub entry_point: String,
}

impl DocumentViewContribution {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        extensions: Vec<String>,
        entry_point: impl Into<String>,
    ) -> Self {
        DocumentViewContribution {
            id: id.into(),
            title: title.into(),
            extensions,
            entry_point: entry_point.into(),
        }
    }

    /// The largest document text the host hands to a view; with JSON escaping the
    /// context stays within the runtime's 65 536-character string inputs.
    pub const MAXIMUM_TEXT_BYTES: usize = 48 * 1_024;
}

pub enum DocumentViewContributionPoint {}

impl ContributionPointSpec for DocumentViewContributionPoint {
    type Descriptor = DocumentViewContribution;

    const ID: &'static str = "cove.ui.documentView/v1";

    fn validate(
        view: &DocumentViewContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        let unique: BTreeSet<&String> = view.extensions.iter().collect();
        if !(ContributionValidation::identifier(&view.id)
            && ContributionValidation::title(&view.title)
            && !view.extensions.is_empty()
            && view.extensions.len() <= 16
            && unique.len() == view.extensions.len()
            && view
                .extensions
                .iter()
                .all(|extension| file_extension(extension, false))
            && ContributionValidation::identifier(&view.entry_point))
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }

    fn validate_runtime(
        view: &DocumentViewContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        let matches = contract
            .and_then(|contract| {
                contract
                    .capability_inputs
                    .iter()
                    .find(|input| input.name == view.entry_point)
            })
            .is_some_and(|input| input.input_type == view_input_type());
        if !matches {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}
