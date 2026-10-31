//! Commands a package adds to the palette, menus and toolbar.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Workbench/Command.swift`.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_contract::{PluginContract, PluginInputField, PluginInputType};
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};
use crate::contribution::workbench::view::UIEffect;
use crate::pattern::grapheme_count;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandContribution {
    /// Unique within the package; the host qualifies it with the package ID.
    pub id: String,
    pub title: String,
    /// Extra words the palette matches, such as synonyms or translations.
    #[serde(default)]
    pub keywords: Option<String>,
    /// The capability that runs the command:
    /// `func(input: record { command: string, arguments: string }) -> string`.
    pub entry_point: String,
    /// False keeps a command out of the palette, for one that only menus or
    /// other commands use.
    #[serde(default)]
    pub palette: Option<bool>,
}

impl CommandContribution {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        entry_point: impl Into<String>,
    ) -> Self {
        CommandContribution {
            id: id.into(),
            title: title.into(),
            keywords: None,
            entry_point: entry_point.into(),
            palette: None,
        }
    }
}

pub enum CommandContributionPoint {}

impl ContributionPointSpec for CommandContributionPoint {
    type Descriptor = CommandContribution;

    const ID: &'static str = "cove.command/v1";

    fn validate(
        command: &CommandContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        if !(ContributionValidation::identifier(&command.id)
            && ContributionValidation::title(&command.title)
            && command
                .keywords
                .as_ref()
                .is_none_or(|keywords| grapheme_count(keywords) <= 160)
            && ContributionValidation::identifier(&command.entry_point))
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }

    fn validate_runtime(
        command: &CommandContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        let matches = contract
            .and_then(|contract| {
                contract
                    .capability_inputs
                    .iter()
                    .find(|input| input.name == command.entry_point)
            })
            .is_some_and(|input| input.input_type == command_input_type());
        if !matches {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}

/// What a command entry point returns: the effects for the host to carry out.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PluginCommandResult {
    pub effects: Vec<UIEffect>,
}

impl PluginCommandResult {
    pub fn new() -> Self {
        PluginCommandResult::default()
    }

    /// Reads the JSON object a command entry point returned. `panels` are the
    /// package's own panel identifiers.
    pub fn from_json(
        json: &[u8],
        panels: &BTreeSet<String>,
    ) -> Result<Self, PluginWorkbenchResultError> {
        #[derive(Deserialize)]
        struct Coding {
            #[serde(default)]
            effects: Option<Vec<UIEffect>>,
        }
        if json.len() > 64 * 1_024 {
            return Err(PluginWorkbenchResultError::InvalidCommandResult);
        }
        // Swift decoded a keyed container, so a top-level array is not a command
        // result even when it is valid JSON.
        let value: serde_json::Value = serde_json::from_slice(json)
            .map_err(|_| PluginWorkbenchResultError::InvalidCommandResult)?;
        if !value.is_object() {
            return Err(PluginWorkbenchResultError::InvalidCommandResult);
        }
        let decoded: Coding = serde_json::from_value(value)
            .map_err(|_| PluginWorkbenchResultError::InvalidCommandResult)?;
        let effects = decoded.effects.unwrap_or_default();
        if effects.len() > 16 || !effects.iter().all(|effect| effect.is_valid(panels)) {
            return Err(PluginWorkbenchResultError::InvalidCommandResult);
        }
        Ok(PluginCommandResult { effects })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginWorkbenchResultError {
    #[error("The plugin returned a command result the editor cannot use.")]
    InvalidCommandResult,
    #[error("The plugin returned a view the editor cannot show.")]
    InvalidView,
}

/// `record { command: string, arguments: string }`: the command's identifier and
/// its arguments as a JSON object.
pub fn command_input_type() -> PluginInputType {
    PluginInputType::Record(vec![
        PluginInputField::new("arguments", PluginInputType::String),
        PluginInputField::new("command", PluginInputType::String),
    ])
}
