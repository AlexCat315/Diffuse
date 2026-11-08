//! `PerceptionSchemaValidator.swift` — supported schema versions and manifest invariants.

use crate::core::perception_contracts::{PerceptionModelManifest, PerceptionResult};

const SUPPORTED_RESULT_SCHEMAS: [&str; 1] = ["cove.perception.result.v1"];
const SUPPORTED_MANIFEST_SCHEMAS: [&str; 1] = ["cove.perception.model_manifest.v1"];

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ValidationError {
    #[error("Unsupported schema version '{0}'")]
    UnsupportedSchemaVersion(String),
    #[error("Manifest modelID must not be empty")]
    EmptyModelID,
    #[error("Manifest inputContract must not be empty")]
    EmptyInputContract,
    #[error("Manifest outputContract must not be empty")]
    EmptyOutputContract,
}

pub struct PerceptionSchemaValidator;

impl PerceptionSchemaValidator {
    pub fn validate_result(result: &PerceptionResult) -> Result<(), ValidationError> {
        if SUPPORTED_RESULT_SCHEMAS.contains(&result.schema_version.as_str()) {
            Ok(())
        } else {
            Err(ValidationError::UnsupportedSchemaVersion(
                result.schema_version.clone(),
            ))
        }
    }

    pub fn validate_manifest(manifest: &PerceptionModelManifest) -> Result<(), ValidationError> {
        if !SUPPORTED_MANIFEST_SCHEMAS.contains(&manifest.schema_version.as_str()) {
            return Err(ValidationError::UnsupportedSchemaVersion(
                manifest.schema_version.clone(),
            ));
        }
        if manifest.model_id.is_empty() {
            return Err(ValidationError::EmptyModelID);
        }
        if manifest.input_contract.is_empty() {
            return Err(ValidationError::EmptyInputContract);
        }
        if manifest.output_contract.is_empty() {
            return Err(ValidationError::EmptyOutputContract);
        }
        Ok(())
    }
}
