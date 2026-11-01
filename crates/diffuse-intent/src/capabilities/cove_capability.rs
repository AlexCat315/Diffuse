//! Typed, value-only preparation boundary shared by provider tools and the host.

use std::sync::Arc;

use diffuse_capability::capability_contract::{
    CapabilityAccess, CapabilityContract, CapabilitySource, ReleasePhase,
};
use diffuse_capability::capability_descriptor::CapabilityDescriptor;
use diffuse_capability::capsule_schema::{JsonSchema, JsonSchemaValidator};
use diffuse_scene::media::animation::AnimationPlayer;
use diffuse_scene::media::audio::AudioSource;
use diffuse_scene::physics::{collider::Collider, rigid_body::RigidBody};
use diffuse_scene::rendering::render_extraction::LightComponent;
use diffuse_script::core::script_component::ScriptBinding;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize};

use crate::invocation::capability_input_declaration::DeclaredCapabilityInput;
use crate::transactions::transaction_ir::{TransactionOperation, TransactionVerificationAssertion};

pub trait CoveCapabilityInput: Serialize + DeserializeOwned + Send + Sync {
    fn input_schema() -> JsonSchema;
}

#[derive(Debug, thiserror::Error)]
pub enum CapabilityPreparationError {
    #[error(transparent)]
    BuiltIn(#[from] super::built_in_typed_capabilities::BuiltInCapabilityPreparationError),
    #[error(transparent)]
    CameraMaterial(
        #[from]
        super::built_in_camera_material_capabilities::CameraMaterialCapabilityPreparationError,
    ),
    #[error(transparent)]
    Physics(#[from] super::built_in_physics_capabilities::PhysicsCapabilityPreparationError),
    #[error(transparent)]
    SceneUtility(
        #[from] super::built_in_scene_utility_capabilities::SceneUtilityCapabilityPreparationError,
    ),
    #[error(transparent)]
    ScriptParameters(#[from] diffuse_assets::swift_json::SwiftJsonError),
}

/// Rust's explicit declaration replaces Swift's nested Input and field wrappers.
macro_rules! declare_capability {
    ($capability:ident, $input_type:ident,
        $id:literal, $title:literal, $description:literal, $access:ident, $phase:ident,
        { $($field:ident: $type:ty => $schema:expr),* $(,)? },
        |$input:ident, $context:ident| $body:block
    ) => {
        #[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
        pub struct $input_type { $(pub $field: $type),* }

        impl Default for $input_type {
            fn default() -> Self {
                Self { $($field: <$type as $crate::invocation::capability_input_declaration::CapabilitySchemaValue>::capability_placeholder()),* }
            }
        }

        impl $input_type {
            pub fn new() -> Self { Self::default() }
        }

        impl $crate::invocation::capability_input_declaration::DeclaredCapabilityInput for $input_type {
            fn declared_fields() -> Vec<$crate::invocation::capability_input_declaration::DeclaredField> {
                vec![$($crate::invocation::capability_input_declaration::DeclaredField::new(
                    stringify!($field), $schema,
                    <$type as $crate::invocation::capability_input_declaration::CapabilitySchemaValue>::capability_is_optional(),
                )),*]
            }
        }

        #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
        pub struct $capability;

        impl $crate::capabilities::cove_capability::CoveCapability for $capability {
            type Input = $input_type;
            type Error = $crate::capabilities::cove_capability::CapabilityPreparationError;
            const ID: &'static str = $id;
            const TITLE: &'static str = $title;
            const DESCRIPTION: &'static str = $description;
            const DOMAIN: &'static str = "scene";
            const ACCESS: diffuse_capability::capability_contract::CapabilityAccess = diffuse_capability::capability_contract::CapabilityAccess::$access;
            const RELEASE_PHASE: diffuse_capability::capability_contract::ReleasePhase = diffuse_capability::capability_contract::ReleasePhase::$phase;
            fn prepare($input: Self::Input, $context: &$crate::capabilities::cove_capability::CapabilityPreparationContext) -> Result<$crate::capabilities::cove_capability::PreparedCapability, Self::Error> $body
        }
    };
}

pub(crate) use declare_capability;

impl<T: DeclaredCapabilityInput + Serialize + DeserializeOwned + Send + Sync> CoveCapabilityInput
    for T
{
    fn input_schema() -> JsonSchema {
        <Self as DeclaredCapabilityInput>::input_schema()
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(transparent)]
pub struct CapabilityPreparationTransform {
    pub column_major_matrix: Vec<f32>,
}

impl CapabilityPreparationTransform {
    pub fn new(column_major_matrix: Vec<f32>) -> Option<Self> {
        if column_major_matrix.len() != 16 || !column_major_matrix.iter().all(|v| v.is_finite()) {
            return None;
        }
        Some(Self {
            column_major_matrix,
        })
    }
}

impl<'de> Deserialize<'de> for CapabilityPreparationTransform {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let values = Vec::<f32>::deserialize(deserializer)?;
        Self::new(values).ok_or_else(|| {
            serde::de::Error::custom(
                "a capability preparation transform must contain 16 finite values",
            )
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityPreparationMaterial {
    pub base_color: Vec<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_color_texture_index: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub normal_texture_index: Option<i64>,
    pub metallic: f32,
    pub roughness: f32,
    pub emissive: Vec<f32>,
}

impl CapabilityPreparationMaterial {
    pub fn new(
        base_color: Vec<f32>,
        base_color_texture_index: Option<i64>,
        normal_texture_index: Option<i64>,
        metallic: f32,
        roughness: f32,
        emissive: Vec<f32>,
    ) -> Option<Self> {
        if base_color.len() != 4
            || emissive.len() != 3
            || !base_color.iter().all(|v| v.is_finite())
            || !emissive.iter().all(|v| v.is_finite())
            || !metallic.is_finite()
            || !roughness.is_finite()
        {
            return None;
        }
        Some(Self {
            base_color,
            base_color_texture_index,
            normal_texture_index,
            metallic,
            roughness,
            emissive,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CapabilityPreparationEntity {
    pub reference: String,
    pub component_types: Vec<String>,
    pub local_transform: Option<CapabilityPreparationTransform>,
    pub render_material: Option<CapabilityPreparationMaterial>,
    pub rigid_body: Option<RigidBody>,
    pub collider: Option<Collider>,
    pub light: Option<LightComponent>,
    pub audio_source: Option<AudioSource>,
    pub animation_player: Option<AnimationPlayer>,
    pub script_bindings: Vec<ScriptBinding>,
}

impl CapabilityPreparationEntity {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        reference: impl Into<String>,
        mut component_types: Vec<String>,
        local_transform: Option<CapabilityPreparationTransform>,
        render_material: Option<CapabilityPreparationMaterial>,
        rigid_body: Option<RigidBody>,
        collider: Option<Collider>,
        light: Option<LightComponent>,
        audio_source: Option<AudioSource>,
        animation_player: Option<AnimationPlayer>,
        script_bindings: Vec<ScriptBinding>,
    ) -> Self {
        component_types.sort();
        Self {
            reference: reference.into(),
            component_types,
            local_transform,
            render_material,
            rigid_body,
            collider,
            light,
            audio_source,
            animation_player,
            script_bindings,
        }
    }

    pub fn with_reference(reference: impl Into<String>) -> Self {
        Self::new(
            reference,
            Vec::new(),
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            Vec::new(),
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CapabilityPreparationContext {
    pub scene_revision: u64,
    pub entities: Vec<CapabilityPreparationEntity>,
}

impl CapabilityPreparationContext {
    pub fn new(scene_revision: u64, entities: Vec<CapabilityPreparationEntity>) -> Self {
        Self {
            scene_revision,
            entities,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityPreview {
    pub summary: String,
    pub target_references: Vec<String>,
}

impl CapabilityPreview {
    pub fn new(summary: impl Into<String>, target_references: Vec<String>) -> Self {
        Self {
            summary: summary.into(),
            target_references,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PreparedCapability {
    pub operations: Vec<TransactionOperation>,
    pub preview: CapabilityPreview,
    pub assertions: Vec<TransactionVerificationAssertion>,
}

impl PreparedCapability {
    pub fn new(
        operations: Vec<TransactionOperation>,
        preview: CapabilityPreview,
        assertions: Vec<TransactionVerificationAssertion>,
    ) -> Self {
        Self {
            operations,
            preview,
            assertions,
        }
    }
}

pub trait CoveCapability: Send + Sync + 'static {
    type Input: CoveCapabilityInput;
    type Error: std::error::Error + Send + Sync + 'static;
    const ID: &'static str;
    const VERSION: i64 = 1;
    const TITLE: &'static str;
    const DESCRIPTION: &'static str;
    const DOMAIN: &'static str;
    const ACCESS: CapabilityAccess;
    const RELEASE_PHASE: ReleasePhase;

    fn source() -> CapabilitySource {
        CapabilitySource::BUILTIN
    }

    fn contract() -> CapabilityContract {
        CapabilityContract::new(
            Self::ID,
            Self::VERSION,
            Self::TITLE,
            Self::DESCRIPTION,
            Self::DOMAIN,
            Self::ACCESS,
            Self::RELEASE_PHASE,
            Self::Input::input_schema(),
            Self::source(),
            None,
        )
    }

    fn prepare(
        input: Self::Input,
        context: &CapabilityPreparationContext,
    ) -> Result<PreparedCapability, Self::Error>;
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum CapabilityRegistrationError {
    #[error("write capability '{0}' must use additionalProperties=false")]
    WriteSchemaMustBeStrict(String),
    #[error("write capability '{0}' contains an open or unsupported schema type")]
    WriteSchemaContainsUnsupportedType(String),
    #[error("invalid input for '{capability_id}': {reason}")]
    InvalidInput {
        capability_id: String,
        reason: String,
    },
    #[error("write capability '{0}' prepared no operations")]
    WritePreparationHasNoOperations(String),
    #[error("write capability '{0}' prepared no preview")]
    WritePreparationHasNoPreview(String),
    #[error("write capability '{0}' prepared no verification assertions")]
    WritePreparationHasNoAssertions(String),
}

type Prepare = Arc<
    dyn Fn(
            &[u8],
            &CapabilityPreparationContext,
        ) -> Result<PreparedCapability, CapabilityRegistrationError>
        + Send
        + Sync,
>;

#[derive(Clone)]
pub struct AnyCapabilityRegistration {
    pub contract: CapabilityContract,
    prepare_closure: Prepare,
}

impl AnyCapabilityRegistration {
    pub fn new<C: CoveCapability>() -> Result<Self, CapabilityRegistrationError> {
        let contract = C::contract();
        if contract.access.is_write() && contract.input_schema.additional_properties != Some(false)
        {
            return Err(CapabilityRegistrationError::WriteSchemaMustBeStrict(
                contract.id,
            ));
        }
        if contract.access.is_write() && !contract.input_schema.is_strict_capability_input() {
            return Err(
                CapabilityRegistrationError::WriteSchemaContainsUnsupportedType(contract.id),
            );
        }
        let preparation_contract = contract.clone();
        let prepare_closure =
            Arc::new(move |data: &[u8], context: &CapabilityPreparationContext| {
                let contract = &preparation_contract;
                let invalid = |reason: String| CapabilityRegistrationError::InvalidInput {
                    capability_id: contract.id.clone(),
                    reason,
                };
                let value: serde_json::Value =
                    serde_json::from_slice(data).map_err(|e| invalid(e.to_string()))?;
                JsonSchemaValidator::validate(&value, &contract.input_schema)
                    .map_err(|e| invalid(e.to_string()))?;
                let input: C::Input =
                    serde_json::from_slice(data).map_err(|e| invalid(e.to_string()))?;
                let mut prepared = C::prepare(input, context).map_err(|error| {
                    // Swift preserves a CapabilityRegistrationError thrown by prepare.
                    let erased: &(dyn std::error::Error + 'static) = &error;
                    erased
                        .downcast_ref::<CapabilityRegistrationError>()
                        .cloned()
                        .unwrap_or_else(|| invalid(error.to_string()))
                })?;
                if contract.access.is_write() {
                    if prepared.operations.is_empty() {
                        return Err(
                            CapabilityRegistrationError::WritePreparationHasNoOperations(
                                contract.id.clone(),
                            ),
                        );
                    }
                    if prepared.preview.summary.trim().is_empty() {
                        return Err(CapabilityRegistrationError::WritePreparationHasNoPreview(
                            contract.id.clone(),
                        ));
                    }
                    if prepared.assertions.is_empty() {
                        return Err(
                            CapabilityRegistrationError::WritePreparationHasNoAssertions(
                                contract.id.clone(),
                            ),
                        );
                    }
                    for operation in &prepared.operations {
                        for assertion in
                            TransactionVerificationAssertion::exact_postconditions(operation)
                        {
                            if !prepared.assertions.contains(&assertion) {
                                prepared.assertions.push(assertion);
                            }
                        }
                    }
                }
                Ok(prepared)
            });
        Ok(Self {
            contract,
            prepare_closure,
        })
    }

    pub fn descriptor(&self) -> CapabilityDescriptor {
        let c = &self.contract;
        let mut descriptor = CapabilityDescriptor::new(&c.id);
        descriptor.release_phase = c.release_phase;
        descriptor.requires_confirmation = c.access.is_write();
        descriptor.is_destructive = c.access == CapabilityAccess::DestructiveWrite;
        descriptor.domain = c.domain.clone();
        descriptor.version = c.version;
        descriptor.title = c.title.clone();
        descriptor.capability_description = c.description.clone();
        descriptor.access = c.access;
        descriptor.input_schema = c.input_schema.clone();
        descriptor.source = c.source.clone();
        descriptor.is_ai_exposed = true;
        descriptor
    }

    pub fn prepare(
        &self,
        validated_input: &[u8],
        context: &CapabilityPreparationContext,
    ) -> Result<PreparedCapability, CapabilityRegistrationError> {
        (self.prepare_closure)(validated_input, context)
    }
}
