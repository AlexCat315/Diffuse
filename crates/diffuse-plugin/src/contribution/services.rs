//! Package services and extension points.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Services.swift`.

use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_contract::{PluginContract, PluginInputField, PluginInputType};
use crate::contract::plugin_json::PluginJSON;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};
use crate::pattern::extension_id;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginServiceContribution {
    pub id: String,
    pub title: String,
    pub entry_point: String,
}

pub enum PluginServiceContributionPoint {}

impl ContributionPointSpec for PluginServiceContributionPoint {
    type Descriptor = PluginServiceContribution;

    const ID: &'static str = "cove.service/v1";

    fn validate(
        value: &PluginServiceContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        if !(extension_id(&value.id)
            && ContributionValidation::title(&value.title)
            && ContributionValidation::identifier(&value.entry_point))
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }

    fn validate_runtime(
        value: &PluginServiceContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        let matches = contract.is_some_and(|contract| {
            contract.capability_inputs.iter().any(|input| {
                input.name == value.entry_point
                    && input.input_type
                        == PluginInputType::Record(vec![PluginInputField::new(
                            "request",
                            PluginInputType::String,
                        )])
            })
        });
        if !matches {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginExtensionPointContribution {
    pub id: String,
    pub title: String,
}

pub enum PluginExtensionPointContributionPoint {}

impl ContributionPointSpec for PluginExtensionPointContributionPoint {
    type Descriptor = PluginExtensionPointContribution;

    const ID: &'static str = "cove.extensionPoint/v1";

    fn validate(
        value: &PluginExtensionPointContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        if !(extension_id(&value.id) && ContributionValidation::title(&value.title)) {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginExtensionContribution {
    pub id: String,
    pub point: String,
    pub data: PluginJSON,
}

pub enum PluginExtensionContributionPoint {}

impl ContributionPointSpec for PluginExtensionContributionPoint {
    type Descriptor = PluginExtensionContribution;

    const ID: &'static str = "cove.extension/v1";

    fn validate(
        value: &PluginExtensionContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        // Swift measured the encoded JSON's size; serde_json's compact encoding
        // is the same payload without Swift's escaping of "/".
        let encoded = serde_json::to_vec(&value.data).map_err(|_| {
            PluginManifestValidationError::InvalidContribution(Self::ID.to_string())
        })?;
        if !(ContributionValidation::identifier(&value.id)
            && extension_id(&value.point)
            && encoded.len() <= 65_536)
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}
