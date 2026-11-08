//! The only write-shaped value a plugin may return.
//!
//! Ported from `Engine/Sources/PluginRuntime/Host/HostCapabilityCall.swift`.
//! There is no public plugin API for SceneMutation, TransactionOperation,
//! pointers or runtime handles.

use diffuse_capability::capability_contract::CapabilitySourceKind;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::validate_capability_input;
use serde::{Deserialize, Serialize};

use crate::base64_data::Data;
use crate::contract::plugin_manifest::{
    CovePluginManifest, PluginManifestValidator, PluginResourceLimits,
};
use crate::contribution::registry::ContributionPointRegistry;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostCapabilityCall {
    /// Swift's synthesized key is `capabilityID`.
    #[serde(rename = "capabilityID")]
    pub capability_id: String,
    pub version: i64,
    pub arguments: Data,
}

impl HostCapabilityCall {
    pub fn new(capability_id: impl Into<String>, version: i64, arguments: Vec<u8>) -> Self {
        HostCapabilityCall {
            capability_id: capability_id.into(),
            version,
            arguments: Data::from_bytes(arguments),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginCompositionError {
    #[error("plugin composition returned too many host calls")]
    TooManyCalls,
    #[error("plugin composition output exceeds 1 MiB")]
    OutputTooLarge,
    #[error("host capability '{0}' was not granted to this plugin")]
    CapabilityNotGranted(String),
    #[error("host capability '{0}' changed version")]
    CapabilityChanged(String),
    #[error("plugin capability '{0}' cannot be used as a primitive")]
    PluginPrimitiveNotAllowed(String),
    #[error("external side-effect capability '{0}' is disabled")]
    ExternalSideEffectNotAllowed(String),
    #[error("invalid arguments for '{capability_id}': {reason}")]
    InvalidArguments {
        capability_id: String,
        reason: String,
    },
    #[error("a plugin write capability must return at least one host call")]
    EmptyWriteComposition,
    #[error("host capability '{0}' is not an AI-exposed strict write primitive")]
    UnsafeHostPrimitive(String),
}

pub enum PluginCompositionValidator {}

impl PluginCompositionValidator {
    pub fn validate(
        calls: &[HostCapabilityCall],
        manifest: &CovePluginManifest,
        registry: &CapabilityRegistry,
        limits: &PluginResourceLimits,
    ) -> Result<Vec<HostCapabilityCall>, crate::PluginError> {
        PluginManifestValidator::validate(
            manifest,
            registry,
            &ContributionPointRegistry::standard(),
        )?;
        if manifest.access.is_write() && calls.is_empty() {
            return Err(PluginCompositionError::EmptyWriteComposition.into());
        }
        if calls.len() as i64 > limits.maximum_capabilities {
            return Err(PluginCompositionError::TooManyCalls.into());
        }
        // Swift: `(try? JSONEncoder().encode(calls).count) ?? Int.max`.
        let encoded_size = serde_json::to_vec(calls)
            .map(|encoded| encoded.len())
            .unwrap_or(usize::MAX);
        if encoded_size as i64 > limits.maximum_output_bytes {
            return Err(PluginCompositionError::OutputTooLarge.into());
        }
        let granted: std::collections::BTreeSet<&String> =
            manifest.composable_host_capabilities.iter().collect();
        for call in calls {
            if !granted.contains(&call.capability_id) {
                return Err(PluginCompositionError::CapabilityNotGranted(
                    call.capability_id.clone(),
                )
                .into());
            }
            let Some(descriptor) = registry.descriptor(&call.capability_id) else {
                return Err(PluginCompositionError::CapabilityNotGranted(
                    call.capability_id.clone(),
                )
                .into());
            };
            let contract = descriptor.contract();
            if contract.source.kind != CapabilitySourceKind::Builtin {
                return Err(PluginCompositionError::PluginPrimitiveNotAllowed(
                    call.capability_id.clone(),
                )
                .into());
            }
            if !(descriptor.is_ai_exposed
                && contract.access.is_write()
                && contract.input_schema.is_strict_capability_input())
            {
                return Err(PluginCompositionError::UnsafeHostPrimitive(
                    call.capability_id.clone(),
                )
                .into());
            }
            if call.version != contract.version {
                return Err(
                    PluginCompositionError::CapabilityChanged(call.capability_id.clone()).into(),
                );
            }
            if contract.access
                == diffuse_capability::capability_contract::CapabilityAccess::ExternalSideEffect
            {
                return Err(PluginCompositionError::ExternalSideEffectNotAllowed(
                    call.capability_id.clone(),
                )
                .into());
            }
            let value: serde_json::Value = serde_json::from_slice(call.arguments.as_slice())
                .map_err(|error| PluginCompositionError::InvalidArguments {
                    capability_id: call.capability_id.clone(),
                    reason: error.to_string(),
                })?;
            validate_capability_input(&value, &contract.input_schema).map_err(|error| {
                PluginCompositionError::InvalidArguments {
                    capability_id: call.capability_id.clone(),
                    reason: error.to_string(),
                }
            })?;
        }
        Ok(calls.to_vec())
    }
}
