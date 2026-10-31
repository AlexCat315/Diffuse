//! Theme declarations and the resource they point at.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Themes/Descriptor.swift`.

use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contract::resources::PluginResource;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};
use crate::pattern::lower_dot;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThemeContribution {
    pub id: String,
    pub title: String,
    #[serde(default = "default_appearance")]
    pub appearance: String,
    pub path: String,
}

fn default_appearance() -> String {
    "dual".to_string()
}

impl ThemeContribution {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        appearance: impl Into<String>,
        path: impl Into<String>,
    ) -> Self {
        ThemeContribution {
            id: id.into(),
            title: title.into(),
            appearance: appearance.into(),
            path: path.into(),
        }
    }
}

pub enum ThemeContributionPoint {}

impl ContributionPointSpec for ThemeContributionPoint {
    type Descriptor = ThemeContribution;

    const ID: &'static str = "cove.theme/v1";

    fn validate(
        descriptor: &ThemeContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        if !(lower_dot(&descriptor.id, 3, 64)
            && ContributionValidation::title(&descriptor.title)
            && ["light", "dark", "dual"].contains(&descriptor.appearance.as_str())
            && PluginResource::is_valid_path(&descriptor.path))
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}
