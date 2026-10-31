//! Contribution point identifiers, the domain registry and descriptor storage.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Registry.swift`.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::PluginError;
use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_contract::PluginContract;
use crate::contract::plugin_json::PluginJSON;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::pattern::{contribution_point_id, lower_dash};

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ContributionPointID(String);

impl ContributionPointID {
    pub fn new(raw_value: &str) -> Option<ContributionPointID> {
        if contribution_point_id(raw_value) {
            Some(ContributionPointID(raw_value.to_string()))
        } else {
            None
        }
    }

    pub fn raw_value(&self) -> &str {
        &self.0
    }
}

impl Serialize for ContributionPointID {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for ContributionPointID {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = String::deserialize(deserializer)?;
        ContributionPointID::new(&value).ok_or_else(|| {
            serde::de::Error::custom(format!("invalid contribution point '{value}'"))
        })
    }
}

impl fmt::Display for ContributionPointID {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// Domains implement their own descriptor and validation. Plugin authors only
/// supply JSON and ordinary capability functions.
pub trait ContributionPointSpec {
    type Descriptor: Serialize + DeserializeOwned + Clone + PartialEq + fmt::Debug;

    const ID: &'static str;

    fn validate(
        descriptor: &Self::Descriptor,
        host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError>;

    /// Swift's protocol extension supplied an empty default.
    fn validate_runtime(
        _descriptor: &Self::Descriptor,
        _contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        Ok(())
    }
}

/// `contributes` is a bare JSON object keyed by contribution point id; Swift
/// encoded it through a `singleValueContainer`, so `#[serde(transparent)]` is
/// the same wire shape.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ContributionDescriptor {
    declarations: BTreeMap<String, PluginJSON>,
}

impl ContributionDescriptor {
    pub fn new() -> Self {
        ContributionDescriptor {
            declarations: BTreeMap::new(),
        }
    }

    pub fn point_ids(&self) -> Vec<String> {
        // Swift sorted `declarations.keys`; the `BTreeMap` is already sorted.
        self.declarations.keys().cloned().collect()
    }

    /// `contributions.decode(Point.self)`: Swift re-encoded the stored JSON and
    /// decoded the descriptor list from it, so incompatible declarations throw at
    /// this point rather than at manifest load.
    pub fn decode<Spec: ContributionPointSpec>(
        &self,
    ) -> Result<Vec<Spec::Descriptor>, PluginError> {
        let Some(value) = self.declarations.get(Spec::ID) else {
            return Ok(Vec::new());
        };
        let encoded = serde_json::to_vec(value)?;
        Ok(serde_json::from_slice(&encoded)?)
    }

    /// Decodes and swallows a failure, matching Swift's
    /// `(try? contributes.decode(…)) ?? []`.
    pub fn decode_lossy<Spec: ContributionPointSpec>(&self) -> Vec<Spec::Descriptor> {
        self.decode::<Spec>().unwrap_or_default()
    }

    pub fn set<Spec: ContributionPointSpec>(
        &mut self,
        descriptors: &[Spec::Descriptor],
    ) -> Result<(), PluginError> {
        let encoded = serde_json::to_vec(descriptors)?;
        let value: PluginJSON = serde_json::from_slice(&encoded)?;
        self.declarations.insert(Spec::ID.to_string(), value);
        Ok(())
    }

    pub(crate) fn validate(
        &self,
        registry: &ContributionPointRegistry,
        host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        for id in self.point_ids() {
            let Some(point) = registry.points.get(&id) else {
                return Err(PluginManifestValidationError::InvalidContribution(id));
            };
            if ContributionPointID::new(&id).is_none() {
                return Err(PluginManifestValidationError::InvalidContribution(id));
            }
            if let Some(PluginJSON::Array(values)) = self.declarations.get(&id) {
                if values.len() > 256 {
                    return Err(PluginManifestValidationError::InvalidContribution(id));
                }
                let mut identifiers: BTreeSet<String> = BTreeSet::new();
                for value in values {
                    if let PluginJSON::Object(fields) = value
                        && let Some(PluginJSON::String(identifier)) = fields.get("id")
                        && !identifiers.insert(identifier.clone())
                    {
                        return Err(PluginManifestValidationError::InvalidContribution(id));
                    }
                }
            }
            (point.validate)(self, host)?;
        }
        Ok(())
    }

    pub(crate) fn validate_runtime(
        &self,
        contract: Option<&PluginContract>,
        registry: &ContributionPointRegistry,
    ) -> Result<(), PluginError> {
        for id in self.point_ids() {
            let Some(point) = registry.points.get(&id) else {
                return Err(PluginManifestValidationError::InvalidContribution(id).into());
            };
            (point.validate_runtime)(self, contract)?;
        }
        Ok(())
    }
}

type ValidateFn = Box<
    dyn Fn(
            &ContributionDescriptor,
            &PluginHostPermissions,
        ) -> Result<(), PluginManifestValidationError>
        + Send
        + Sync,
>;
type ValidateRuntimeFn = Box<
    dyn Fn(&ContributionDescriptor, Option<&PluginContract>) -> Result<(), PluginError>
        + Send
        + Sync,
>;

pub struct Point {
    validate: ValidateFn,
    validate_runtime: ValidateRuntimeFn,
}

#[derive(Clone)]
pub struct ContributionPointRegistry {
    points: BTreeMap<String, std::sync::Arc<Point>>,
}

impl std::fmt::Debug for ContributionPointRegistry {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ContributionPointRegistry")
            .field("points", &self.points.keys().collect::<Vec<_>>())
            .finish()
    }
}

impl Default for ContributionPointRegistry {
    /// Swift's `.standard` was the default registry everywhere the manifest
    /// validator declared `contributions: ContributionPointRegistry = .standard`.
    fn default() -> Self {
        Self::standard()
    }
}

impl ContributionPointRegistry {
    pub fn new() -> Self {
        ContributionPointRegistry {
            points: BTreeMap::new(),
        }
    }

    pub fn register<Spec: ContributionPointSpec>(
        &mut self,
    ) -> Result<(), PluginManifestValidationError> {
        if ContributionPointID::new(Spec::ID).is_none() || self.points.contains_key(Spec::ID) {
            return Err(PluginManifestValidationError::InvalidContribution(
                Spec::ID.to_string(),
            ));
        }
        self.points.insert(
            Spec::ID.to_string(),
            std::sync::Arc::new(Point {
                validate: Box::new(|contributions, host| {
                    for descriptor in contributions.decode::<Spec>().map_err(manifest_error)? {
                        Spec::validate(&descriptor, host)?;
                    }
                    Ok(())
                }),
                validate_runtime: Box::new(|contributions, contract| {
                    for descriptor in contributions.decode::<Spec>()? {
                        Spec::validate_runtime(&descriptor, contract)?;
                    }
                    Ok(())
                }),
            }),
        );
        Ok(())
    }

    /// Swift's `try!` on each registration: the ids are constants and unique, so
    /// a failure here is a programming error.
    pub fn standard() -> ContributionPointRegistry {
        let mut registry = ContributionPointRegistry::new();
        registry
            .register::<crate::contribution::languages::language_point::LanguageContributionPoint>()
            .expect("standard language contribution point registers");
        registry
            .register::<crate::contribution::processes::process_points::VersionControlContributionPoint>()
            .expect("standard version control contribution point registers");
        registry
            .register::<crate::contribution::processes::process_points::TaskContributionPoint>()
            .expect("standard task contribution point registers");
        registry
            .register::<crate::contribution::ai::provider_point::AIProviderContributionPoint>()
            .expect("standard AI provider contribution point registers");
        registry
            .register::<crate::contribution::ai::agent::AgentContributionPoint>()
            .expect("standard agent contribution point registers");
        registry
            .register::<crate::contribution::themes::descriptor::ThemeContributionPoint>()
            .expect("standard theme contribution point registers");
        registry
            .register::<crate::contribution::workbench::command::CommandContributionPoint>()
            .expect("standard command contribution point registers");
        registry
            .register::<crate::contribution::workbench::panel::PanelContributionPoint>()
            .expect("standard panel contribution point registers");
        registry
            .register::<crate::contribution::workbench::placement::MenuContributionPoint>()
            .expect("standard menu contribution point registers");
        registry
            .register::<crate::contribution::workbench::placement::ToolbarContributionPoint>()
            .expect("standard toolbar contribution point registers");
        registry
            .register::<crate::contribution::workbench::document::DocumentViewContributionPoint>()
            .expect("standard document view contribution point registers");
        registry
            .register::<crate::contribution::ai::tool::AIToolContributionPoint>()
            .expect("standard AI tool contribution point registers");
        registry
            .register::<crate::contribution::ai::context::AIContextContributionPoint>()
            .expect("standard AI context contribution point registers");
        registry
            .register::<crate::contribution::ai::harness::AIHarnessContributionPoint>()
            .expect("standard AI harness contribution point registers");
        registry
            .register::<crate::contribution::services::PluginServiceContributionPoint>()
            .expect("standard plugin service contribution point registers");
        registry
            .register::<crate::contribution::services::PluginExtensionPointContributionPoint>()
            .expect("standard plugin extension point contribution point registers");
        registry
            .register::<crate::contribution::services::PluginExtensionContributionPoint>()
            .expect("standard plugin extension contribution point registers");
        registry
    }
}

pub enum ContributionValidation {}

impl ContributionValidation {
    pub fn identifier(value: &str) -> bool {
        lower_dash(value, 1, 32)
    }

    pub fn title(value: &str) -> bool {
        !is_blank(value) && grapheme_count(value) <= 80
    }

    pub fn file_name(name: &str) -> bool {
        !name.is_empty()
            && grapheme_count(name) <= 64
            && name != "."
            && name != ".."
            && !name
                .chars()
                .any(|character| matches!(character, '/' | '\\' | ':' | '\0'))
    }
}

use crate::pattern::{grapheme_count, is_blank};

/// `Contributions.validate` reports a decode failure as an invalid
/// contribution, which is what Swift's throwing `decode` reached through the
/// registry closure.
fn manifest_error(error: PluginError) -> PluginManifestValidationError {
    match error {
        PluginError::Json(error) => {
            PluginManifestValidationError::InvalidContribution(error.to_string())
        }
        PluginError::Manifest(error) => error,
        other => PluginManifestValidationError::InvalidContribution(other.to_string()),
    }
}
