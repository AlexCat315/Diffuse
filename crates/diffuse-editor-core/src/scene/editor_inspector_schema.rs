//! `Editor/Sources/EditorCore/Scene/EditorInspectorSchema.swift`.
//!
//! The value model the property grid renders: sections, fields and the typed
//! control value behind each field. Bindings are Cove's two-way references, so
//! a field reads and writes the component document directly.

use std::collections::BTreeSet;
use std::rc::Rc;

use cove_ui_compose::scene_core::{Binding, Color};
use diffuse_scene::particles::particle_curve::ParticleCurve;
use diffuse_scene::particles::particle_events::ParticleSubEmitter;
use diffuse_scene::particles::particle_modules::ParticleModuleStack;
use diffuse_scene::physics::collider::ColliderShapeInstance;

#[derive(Clone, Debug)]
pub struct EditorInspectorSection {
    pub id: String,
    pub title: String,
    pub fields: Vec<EditorInspectorField>,
    pub groups: Vec<EditorInspectorFieldGroup>,
    pub component_type_id: Option<String>,
    pub supports_multi_selection: bool,
}

impl EditorInspectorSection {
    /// Swift's memberwise initializer; `groups` defaults to empty.
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        fields: Vec<EditorInspectorField>,
    ) -> Self {
        EditorInspectorSection {
            id: id.into(),
            title: title.into(),
            fields,
            groups: Vec::new(),
            component_type_id: None,
            supports_multi_selection: true,
        }
    }

    /// The full memberwise initializer.
    pub fn with_groups(
        id: impl Into<String>,
        title: impl Into<String>,
        fields: Vec<EditorInspectorField>,
        groups: Vec<EditorInspectorFieldGroup>,
        component_type_id: Option<String>,
        supports_multi_selection: bool,
    ) -> Self {
        EditorInspectorSection {
            id: id.into(),
            title: title.into(),
            fields,
            groups,
            component_type_id,
            supports_multi_selection,
        }
    }
}

/// Presentation of one behavior instance. Fields remain the canonical bindings;
/// the group identifies which belong in its header, menu and property form.
#[derive(Clone, Debug)]
pub struct EditorInspectorFieldGroup {
    pub id: String,
    pub title: String,
    pub field_ids: Vec<String>,
    pub enabled_field_id: String,
    pub status_field_id: String,
    pub selector_field_id: String,
    pub action_field_ids: Vec<String>,
    pub source_identifier: Option<String>,
}

impl EditorInspectorFieldGroup {
    /// Swift's memberwise initializer; `sourceIdentifier` defaults to `nil`.
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        field_ids: Vec<String>,
        enabled_field_id: impl Into<String>,
        status_field_id: impl Into<String>,
        selector_field_id: impl Into<String>,
        action_field_ids: Vec<String>,
    ) -> Self {
        EditorInspectorFieldGroup {
            id: id.into(),
            title: title.into(),
            field_ids,
            enabled_field_id: enabled_field_id.into(),
            status_field_id: status_field_id.into(),
            selector_field_id: selector_field_id.into(),
            action_field_ids,
            source_identifier: None,
        }
    }

    /// The full memberwise initializer.
    #[allow(clippy::too_many_arguments)]
    pub fn with_source_identifier(
        id: impl Into<String>,
        title: impl Into<String>,
        field_ids: Vec<String>,
        enabled_field_id: impl Into<String>,
        status_field_id: impl Into<String>,
        selector_field_id: impl Into<String>,
        action_field_ids: Vec<String>,
        source_identifier: Option<String>,
    ) -> Self {
        EditorInspectorFieldGroup {
            id: id.into(),
            title: title.into(),
            field_ids,
            enabled_field_id: enabled_field_id.into(),
            status_field_id: status_field_id.into(),
            selector_field_id: selector_field_id.into(),
            action_field_ids,
            source_identifier,
        }
    }
}

/// How the property grid lays out one section. Registered renderers declare the
/// layout their fields are shaped for, so panels dispatch on this value instead
/// of comparing section identifiers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditorInspectorSectionLayout {
    /// One row per field, in the order the renderer produced them.
    Standard,
    /// One collapsible child section per script binding, each with its own header actions.
    ScriptBindings,
    /// Fixed module groups owned by the particle emitter form.
    ParticleModules,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditorInspectorFieldPresentation {
    Standard,
    /// Expert/raw-data access is available, but not part of the default form.
    Advanced,
}

#[derive(Clone)]
pub struct EditorInspectorField {
    pub id: String,
    pub label: String,
    pub value: EditorInspectorFieldValue,
    pub presentation: EditorInspectorFieldPresentation,
    pub group: Option<String>,
    pub is_mixed: bool,
    pub mixed_axes: BTreeSet<String>,
    pub apply_primary_value: Option<Rc<dyn Fn()>>,
}

impl EditorInspectorField {
    /// Swift's memberwise initializer with its default arguments.
    pub fn new(
        id: impl Into<String>,
        label: impl Into<String>,
        value: EditorInspectorFieldValue,
    ) -> Self {
        EditorInspectorField {
            id: id.into(),
            label: label.into(),
            value,
            presentation: EditorInspectorFieldPresentation::Standard,
            group: None,
            is_mixed: false,
            mixed_axes: BTreeSet::new(),
            apply_primary_value: None,
        }
    }

    /// The full memberwise initializer.
    #[allow(clippy::too_many_arguments)]
    pub fn with_options(
        id: impl Into<String>,
        label: impl Into<String>,
        value: EditorInspectorFieldValue,
        presentation: EditorInspectorFieldPresentation,
        is_mixed: bool,
        mixed_axes: BTreeSet<String>,
        apply_primary_value: Option<Rc<dyn Fn()>>,
        group: Option<String>,
    ) -> Self {
        EditorInspectorField {
            id: id.into(),
            label: label.into(),
            value,
            presentation,
            group,
            is_mixed,
            mixed_axes,
            apply_primary_value,
        }
    }
}

impl std::fmt::Debug for EditorInspectorField {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("EditorInspectorField")
            .field("id", &self.id)
            .field("label", &self.label)
            .field("value", &self.value)
            .field("presentation", &self.presentation)
            .field("group", &self.group)
            .field("is_mixed", &self.is_mixed)
            .field("mixed_axes", &self.mixed_axes)
            .field(
                "has_apply_primary_value",
                &self.apply_primary_value.is_some(),
            )
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorInspectorEntityOption {
    pub id: u64,
    pub name: String,
}

impl EditorInspectorEntityOption {
    pub fn new(id: u64, name: impl Into<String>) -> Self {
        EditorInspectorEntityOption {
            id,
            name: name.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorInspectorStringOption {
    pub value: String,
    pub label: String,
}

impl EditorInspectorStringOption {
    pub fn new(value: impl Into<String>, label: impl Into<String>) -> Self {
        EditorInspectorStringOption {
            value: value.into(),
            label: label.into(),
        }
    }
}

#[derive(Clone)]
pub enum EditorInspectorFieldValue {
    ReadOnly(String),
    Text(Binding<String>),
    StringOptions {
        binding: Binding<String>,
        options: Vec<EditorInspectorStringOption>,
    },
    Action {
        title: String,
        is_destructive: bool,
        action: Rc<dyn Fn()>,
    },
    Bool(Binding<bool>),
    Number(Binding<f32>),
    ConstrainedNumber {
        binding: Binding<f32>,
        min: Option<f32>,
        max: Option<f32>,
        step: Option<f32>,
        shows_stepper: bool,
    },
    Vector3 {
        x: Binding<f32>,
        y: Binding<f32>,
        z: Binding<f32>,
    },
    Color(Binding<Color>),
    Json {
        binding: Binding<String>,
        min_height: f32,
    },
    ColliderShapeInstances(Binding<Vec<ColliderShapeInstance>>),
    EntityReference {
        binding: Binding<u64>,
        options: Vec<EditorInspectorEntityOption>,
    },
    ParticleCurve(Binding<ParticleCurve>),
    ParticleSubEmitters(Binding<Vec<ParticleSubEmitter>>),
    ParticleModuleStack(Binding<ParticleModuleStack>),
    Asset {
        binding: Binding<Option<EditorInspectorAssetRef>>,
        accepted_kinds: BTreeSet<String>,
        placeholder: String,
    },
}

impl std::fmt::Debug for EditorInspectorFieldValue {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let name = match self {
            EditorInspectorFieldValue::ReadOnly(_) => "readOnly",
            EditorInspectorFieldValue::Text(_) => "text",
            EditorInspectorFieldValue::StringOptions { .. } => "stringOptions",
            EditorInspectorFieldValue::Action { .. } => "action",
            EditorInspectorFieldValue::Bool(_) => "bool",
            EditorInspectorFieldValue::Number(_) => "number",
            EditorInspectorFieldValue::ConstrainedNumber { .. } => "constrainedNumber",
            EditorInspectorFieldValue::Vector3 { .. } => "vector3",
            EditorInspectorFieldValue::Color(_) => "color",
            EditorInspectorFieldValue::Json { .. } => "json",
            EditorInspectorFieldValue::ColliderShapeInstances(_) => "colliderShapeInstances",
            EditorInspectorFieldValue::EntityReference { .. } => "entityReference",
            EditorInspectorFieldValue::ParticleCurve(_) => "particleCurve",
            EditorInspectorFieldValue::ParticleSubEmitters(_) => "particleSubEmitters",
            EditorInspectorFieldValue::ParticleModuleStack(_) => "particleModuleStack",
            EditorInspectorFieldValue::Asset { .. } => "asset",
        };
        formatter.write_str(name)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorInspectorAssetRef {
    pub id: String,
    pub name: String,
    pub subtitle: Option<String>,
    pub kind: String,
    pub preview_path: Option<String>,
}

impl EditorInspectorAssetRef {
    /// Swift's memberwise initializer; both optional fields default to `nil`.
    pub fn new(id: impl Into<String>, name: impl Into<String>, kind: impl Into<String>) -> Self {
        EditorInspectorAssetRef {
            id: id.into(),
            name: name.into(),
            subtitle: None,
            kind: kind.into(),
            preview_path: None,
        }
    }

    /// The full memberwise initializer.
    pub fn with_options(
        id: impl Into<String>,
        name: impl Into<String>,
        subtitle: Option<String>,
        kind: impl Into<String>,
        preview_path: Option<String>,
    ) -> Self {
        EditorInspectorAssetRef {
            id: id.into(),
            name: name.into(),
            subtitle,
            kind: kind.into(),
            preview_path,
        }
    }
}
