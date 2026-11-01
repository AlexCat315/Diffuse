//! `Core/Declarations.swift` — components declared by data rather than code.
//!
//! Declarations arrive from outside the process (plugin output, module manifests),
//! so they are validated before installation and never trap. Their storage is the
//! authored document, which means serialization, prefabs, saves, generated
//! inspector forms and `componentDescriptions` all work without native code.

use std::collections::BTreeSet;

use thiserror::Error;

use crate::components::core::document_schema::DocumentComponentSchema;
use crate::components::core::registry::{ComponentDependencyError, ComponentRegistry};
use crate::components::core::value::ComponentValue;
use crate::components::inspection::inspection::ComponentDescription;

/// Bounds applied to component declarations that arrive from outside the process.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ComponentDeclarationLimits {
    pub maximum_payload_bytes: usize,
    pub maximum_components: usize,
    pub maximum_fields_per_component: usize,
}

impl ComponentDeclarationLimits {
    pub fn new() -> Self {
        ComponentDeclarationLimits {
            maximum_payload_bytes: 1 << 20,
            maximum_components: 32,
            maximum_fields_per_component: 64,
        }
    }
}

impl Default for ComponentDeclarationLimits {
    fn default() -> Self {
        ComponentDeclarationLimits::new()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum ComponentDeclarationError {
    /// The payload is not a JSON array of component descriptions.
    #[error("payload is not a JSON array of component descriptions")]
    InvalidPayload,
    #[error("payload is {0} bytes, above the declaration limit")]
    PayloadTooLarge(usize),
    #[error("payload declares {0} components, above the declaration limit")]
    TooManyComponents(usize),
    #[error("component type ID is empty")]
    EmptyTypeID,
    #[error("duplicate component type ID: {0}")]
    DuplicateTypeID(String),
    /// Declared components must be namespaced, so they can never shadow a
    /// built-in type ID such as `collider`.
    #[error("component type ID is not namespaced: {0}")]
    UnnamespacedTypeID(String),
    #[error("component declaration has no object defaults: {0}")]
    MissingDefaults(String),
    #[error("component {0} declares {1} fields, above the declaration limit")]
    TooManyFields(String, usize),
}

/// The untyped `throws` surface of `register(contentsOf:)`: declaration validation
/// plus the dependency errors raised while checking requirement cycles.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum ComponentInstallError {
    #[error(transparent)]
    Declaration(#[from] ComponentDeclarationError),
    #[error(transparent)]
    Dependency(#[from] ComponentDependencyError),
}

/// Decodes component declarations that travel as data — plugin output, module
/// manifests — into descriptions the registry can install.
pub enum ComponentDeclarations {}

impl ComponentDeclarations {
    pub fn decode(
        data: &[u8],
        limits: &ComponentDeclarationLimits,
    ) -> Result<Vec<ComponentDescription>, ComponentDeclarationError> {
        if data.len() > limits.maximum_payload_bytes {
            return Err(ComponentDeclarationError::PayloadTooLarge(data.len()));
        }
        let decoded: Vec<ComponentDescription> =
            serde_json::from_slice(data).map_err(|_| ComponentDeclarationError::InvalidPayload)?;
        if decoded.len() > limits.maximum_components {
            return Err(ComponentDeclarationError::TooManyComponents(decoded.len()));
        }
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        for description in &decoded {
            if description.type_id.is_empty() {
                return Err(ComponentDeclarationError::EmptyTypeID);
            }
            let parts: Vec<&str> = description.type_id.split('.').collect();
            if parts.len() != 2 || parts[0].is_empty() || parts[1].is_empty() {
                return Err(ComponentDeclarationError::UnnamespacedTypeID(
                    description.type_id.clone(),
                ));
            }
            if !seen.insert(description.type_id.as_str()) {
                return Err(ComponentDeclarationError::DuplicateTypeID(
                    description.type_id.clone(),
                ));
            }
            let has_object_defaults =
                matches!(&description.defaults, Some(ComponentValue::Object(_)));
            if !has_object_defaults {
                return Err(ComponentDeclarationError::MissingDefaults(
                    description.type_id.clone(),
                ));
            }
            if description.fields.len() > limits.maximum_fields_per_component {
                return Err(ComponentDeclarationError::TooManyFields(
                    description.type_id.clone(),
                    description.fields.len(),
                ));
            }
        }
        Ok(decoded)
    }
}

impl ComponentRegistry {
    /// Installs components described by data. Their storage is the authored
    /// document, so serialization, prefabs, game saves, the generated inspector
    /// form and `componentDescriptions` all work without native code.
    ///
    /// Declarations are untrusted: this returns an error instead of trapping.
    /// Validate with [`ComponentDeclarations::decode`] before installing.
    pub fn register_contents_of(
        &mut self,
        declarations: &[ComponentDescription],
    ) -> Result<(), ComponentInstallError> {
        for description in declarations {
            if description.type_id.is_empty() {
                return Err(ComponentDeclarationError::EmptyTypeID.into());
            }
            if self.get(&description.type_id).is_some() {
                return Err(ComponentDeclarationError::DuplicateTypeID(
                    description.type_id.clone(),
                )
                .into());
            }
            let defaults = match &description.defaults {
                Some(defaults @ ComponentValue::Object(_)) => defaults.clone(),
                _ => {
                    return Err(ComponentDeclarationError::MissingDefaults(
                        description.type_id.clone(),
                    )
                    .into());
                }
            };
            let mut schema = DocumentComponentSchema::make_with_default(
                description.type_id.clone(),
                description.display_name.clone(),
                description.category,
                defaults,
            );
            schema.requires = description.requires.clone();
            schema.is_user_addable = description.is_user_addable;
            schema.inspection.fields = description.fields.clone();
            self.register(schema);
        }
        for description in declarations {
            let _ = self.required_schemas(&description.type_id)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentCategory;

    fn description(type_id: &str, defaults: Option<ComponentValue>) -> ComponentDescription {
        ComponentDescription {
            type_id: type_id.to_string(),
            display_name: type_id.to_string(),
            category: ComponentCategory::Gameplay,
            requires: Vec::new(),
            is_user_addable: true,
            fields: Vec::new(),
            defaults,
        }
    }

    fn object_defaults() -> ComponentValue {
        ComponentValue::Object(Default::default())
    }

    fn encode(descriptions: &[ComponentDescription]) -> Vec<u8> {
        serde_json::to_vec(descriptions).expect("encode")
    }

    #[test]
    fn a_namespaced_object_declaration_is_accepted() {
        let payload = encode(&[description("mod.health", Some(object_defaults()))]);
        let decoded = ComponentDeclarations::decode(&payload, &ComponentDeclarationLimits::new())
            .expect("decoded");
        assert_eq!(decoded.len(), 1);
        assert_eq!(decoded[0].type_id, "mod.health");
    }

    #[test]
    fn limits_and_validation_order_match_the_swift_checks() {
        let limits = ComponentDeclarationLimits {
            maximum_payload_bytes: 4,
            maximum_components: 1,
            maximum_fields_per_component: 0,
        };
        let payload = encode(&[description("mod.health", Some(object_defaults()))]);
        assert_eq!(
            ComponentDeclarations::decode(&payload, &limits),
            Err(ComponentDeclarationError::PayloadTooLarge(payload.len()))
        );

        let limits = ComponentDeclarationLimits::new();
        let unnamespaced = encode(&[description("health", Some(object_defaults()))]);
        assert_eq!(
            ComponentDeclarations::decode(&unnamespaced, &limits),
            Err(ComponentDeclarationError::UnnamespacedTypeID(
                "health".to_string()
            ))
        );
        let no_defaults = encode(&[description("mod.health", None)]);
        assert_eq!(
            ComponentDeclarations::decode(&no_defaults, &limits),
            Err(ComponentDeclarationError::MissingDefaults(
                "mod.health".to_string()
            ))
        );
        let not_json = b"not json".to_vec();
        assert_eq!(
            ComponentDeclarations::decode(&not_json, &limits),
            Err(ComponentDeclarationError::InvalidPayload)
        );
    }

    #[test]
    fn installing_rejects_duplicates_and_resolves_requirements() {
        let mut registry = ComponentRegistry::new();
        let health = description("mod.health", Some(object_defaults()));
        registry
            .register_contents_of(std::slice::from_ref(&health))
            .expect("installs");
        assert_eq!(
            registry.register_contents_of(std::slice::from_ref(&health)),
            Err(ComponentInstallError::Declaration(
                ComponentDeclarationError::DuplicateTypeID("mod.health".to_string())
            ))
        );

        let mut armor = description("mod.armor", Some(object_defaults()));
        armor.requires = vec!["mod.health".to_string()];
        registry
            .register_contents_of(&[armor])
            .expect("installs with dependency");
        assert_eq!(
            registry
                .required_schemas("mod.armor")
                .map(|schemas| schemas.len()),
            Ok(1)
        );
    }
}
