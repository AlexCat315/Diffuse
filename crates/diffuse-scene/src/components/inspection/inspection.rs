//! Component inspection metadata: the editor-facing description of a component's
//! authored document. Presentation metadata addresses the codec document, never a
//! second copy of the runtime model.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::components::core::registry::{ComponentEncodeContext, ComponentSchema};
use crate::components::core::value::ComponentValue;
use crate::components::required_components::make_default_component;
use crate::runtime_world::RuntimeWorld;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ComponentFieldKind {
    Automatic,
    Boolean,
    String,
    Number,
    Integer,
    Vector3,
    Color,
    Json,
    Options,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComponentNumericPresentation {
    pub minimum: Option<f64>,
    pub maximum: Option<f64>,
    pub step: Option<f64>,
    pub maximum_path: Option<Vec<String>>,
    /// Display value = stored value * scale (for example radians to degrees).
    #[serde(default = "ComponentNumericPresentation::default_scale")]
    pub scale: f64,
}

impl ComponentNumericPresentation {
    fn default_scale() -> f64 {
        1.0
    }

    #[inline]
    pub fn new() -> Self {
        Self::default()
    }
}

impl Default for ComponentNumericPresentation {
    fn default() -> Self {
        ComponentNumericPresentation {
            minimum: None,
            maximum: None,
            step: None,
            maximum_path: None,
            scale: 1.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComponentColorPresentation {
    #[serde(default)]
    pub minimum: f64,
    /// RGB channel limit; `None` permits HDR values. Alpha remains in 0...1.
    #[serde(default = "ComponentColorPresentation::default_maximum")]
    pub maximum: Option<f64>,
}

impl ComponentColorPresentation {
    fn default_maximum() -> Option<f64> {
        Some(1.0)
    }

    #[inline]
    pub fn new() -> Self {
        Self::default()
    }
}

impl Default for ComponentColorPresentation {
    fn default() -> Self {
        ComponentColorPresentation {
            minimum: 0.0,
            maximum: Some(1.0),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComponentFieldVisibility {
    pub path: Vec<String>,
    pub values: Vec<ComponentValue>,
}

impl ComponentFieldVisibility {
    pub fn new(path: Vec<String>, values: Vec<ComponentValue>) -> Self {
        ComponentFieldVisibility { path, values }
    }
}

/// The control's stable ID is independent of the codec's string or numeric enum value.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComponentFieldChoice {
    pub id: String,
    pub label: String,
    pub value: ComponentValue,
}

impl ComponentFieldChoice {
    /// Swift `init(_ id:value:label:)` defaults `label` to the derived display
    /// label of `id` and `value` to `.string(id)`.
    pub fn new(id: impl Into<String>) -> Self {
        let id = id.into();
        ComponentFieldChoice {
            label: ComponentFieldDescriptor::display_label(&id),
            value: ComponentValue::String(id.clone()),
            id,
        }
    }

    pub fn with_value(mut self, value: ComponentValue) -> Self {
        self.value = value;
        self
    }

    pub fn with_label(mut self, label: impl Into<String>) -> Self {
        self.label = label.into();
        self
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComponentFieldDescriptor {
    pub path: Vec<String>,
    pub id: String,
    pub label: String,
    #[serde(default = "ComponentFieldDescriptor::default_kind")]
    pub kind: ComponentFieldKind,
    #[serde(default)]
    pub numeric: ComponentNumericPresentation,
    #[serde(default)]
    pub color: ComponentColorPresentation,
    /// Clearing a nullable string writes null; the codec may omit that key.
    #[serde(default)]
    pub is_nullable: bool,
    #[serde(default)]
    pub choices: Vec<ComponentFieldChoice>,
    #[serde(default)]
    pub visibility: Option<ComponentFieldVisibility>,
    #[serde(default)]
    pub is_read_only: bool,
    #[serde(default)]
    pub is_advanced: bool,
    #[serde(default)]
    pub group: Option<String>,
    #[serde(default)]
    pub documentation: Option<String>,
}

impl ComponentFieldDescriptor {
    fn default_kind() -> ComponentFieldKind {
        ComponentFieldKind::Automatic
    }

    /// Swift `init(_ path:_ configure:)`.
    pub fn new(path: Vec<String>) -> Self {
        let id = path.join(".");
        let label =
            ComponentFieldDescriptor::display_label(path.last().map_or("Value", String::as_str));
        ComponentFieldDescriptor {
            path,
            id,
            label,
            kind: ComponentFieldKind::Automatic,
            numeric: ComponentNumericPresentation::default(),
            color: ComponentColorPresentation::default(),
            is_nullable: false,
            choices: Vec::new(),
            visibility: None,
            is_read_only: false,
            is_advanced: false,
            group: None,
            documentation: None,
        }
    }

    /// Splits `camelCase` runs the way Swift's regex does, then replaces `_`/`-`
    /// with spaces and capitalizes each word.
    pub fn display_label(key: &str) -> String {
        let mut spaced = String::with_capacity(key.len() + 4);
        let chars: Vec<char> = key.chars().collect();
        for (index, character) in chars.iter().enumerate() {
            if index > 0 && character.is_ascii_uppercase() {
                let previous = chars[index - 1];
                if previous.is_ascii_lowercase() || previous.is_ascii_digit() {
                    spaced.push(' ');
                }
            }
            spaced.push(*character);
        }
        let replaced: String = spaced
            .chars()
            .map(|character| match character {
                '_' | '-' => ' ',
                other => other,
            })
            .collect();
        capitalize_words(&replaced)
    }
}

/// Swift `String.capitalized`: uppercase the first letter of every whitespace-run
/// word and lowercase the rest.
fn capitalize_words(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut at_word_start = true;
    for character in value.chars() {
        if character.is_whitespace() {
            at_word_start = true;
            result.push(character);
        } else if at_word_start {
            result.extend(character.to_uppercase());
            at_word_start = false;
        } else {
            result.extend(character.to_lowercase());
        }
    }
    result
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComponentInspection {
    #[serde(default, rename = "sectionID")]
    pub section_id: Option<String>,
    #[serde(default)]
    pub fields: Vec<ComponentFieldDescriptor>,
    #[serde(default)]
    pub is_read_only: bool,
    /// Keep inferred codec details accessible without crowding the main form.
    #[serde(default)]
    pub inferred_fields_are_advanced: bool,
}

impl ComponentInspection {
    #[inline]
    pub fn new() -> Self {
        Self::default()
    }

    /// Expands explicit field metadata over the actual document, inferring kinds
    /// for anything the codec did not describe.
    pub fn resolved_fields(&self, value: &ComponentValue) -> Vec<ComponentFieldDescriptor> {
        fn infer(value: &ComponentValue, path: &mut Vec<String>) -> Vec<ComponentFieldDescriptor> {
            if let ComponentValue::Object(values) = value
                && !values.is_empty()
            {
                let mut inferred = Vec::new();
                for (key, child) in values {
                    path.push(key.clone());
                    inferred.extend(infer(child, path));
                    path.pop();
                }
                return inferred;
            }
            if path.is_empty() {
                return Vec::new();
            }
            let mut field = ComponentFieldDescriptor::new(path.clone());
            if path.len() > 1 {
                field.group = Some(
                    path[..path.len() - 1]
                        .iter()
                        .map(|part| ComponentFieldDescriptor::display_label(part))
                        .collect::<Vec<_>>()
                        .join(" / "),
                );
            }
            field.kind = match value {
                ComponentValue::Bool(_) => ComponentFieldKind::Boolean,
                ComponentValue::String(_) => ComponentFieldKind::String,
                ComponentValue::Number(_) => ComponentFieldKind::Number,
                ComponentValue::SignedInteger(_) | ComponentValue::UnsignedInteger(_) => {
                    ComponentFieldKind::Integer
                }
                ComponentValue::Array(values)
                    if values.len() == 3
                        && values.iter().all(|entry| entry.numeric_value().is_some()) =>
                {
                    ComponentFieldKind::Vector3
                }
                _ => ComponentFieldKind::Json,
            };
            vec![field]
        }

        let inferred = infer(value, &mut Vec::new());
        let explicit_paths: Vec<Vec<String>> =
            self.fields.iter().map(|field| field.path.clone()).collect();

        let mut resolved: Vec<ComponentFieldDescriptor> = self
            .fields
            .iter()
            .map(|field| {
                let mut resolved = field.clone();
                let inferred_field = inferred.iter().find(|entry| entry.path == field.path);
                if resolved.kind == ComponentFieldKind::Automatic {
                    resolved.kind =
                        inferred_field.map_or(ComponentFieldKind::Json, |entry| entry.kind);
                }
                if resolved.group.is_none() {
                    resolved.group = inferred_field.and_then(|entry| entry.group.clone());
                }
                resolved
            })
            .collect();

        for field in &inferred {
            let covered = explicit_paths
                .iter()
                .any(|path| field.path.starts_with(path.as_slice()));
            if !covered {
                let mut field = field.clone();
                field.is_advanced = self.inferred_fields_are_advanced;
                resolved.push(field);
            }
        }

        for field in &mut resolved {
            field.is_read_only = field.is_read_only || self.is_read_only;
        }
        resolved
    }
}

/// A component declared by data — plugin output, module manifests.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComponentDescription {
    #[serde(rename = "typeID")]
    pub type_id: String,
    pub display_name: String,
    pub category: crate::components::core::registry::ComponentCategory,
    #[serde(default)]
    pub requires: Vec<String>,
    #[serde(default)]
    pub is_user_addable: bool,
    #[serde(default)]
    pub fields: Vec<ComponentFieldDescriptor>,
    #[serde(default)]
    pub defaults: Option<ComponentValue>,
}

/// Helper used by declaring code paths that need the flattened document keys.
pub fn object_fields(value: &ComponentValue) -> BTreeMap<String, ComponentValue> {
    value.object_value().cloned().unwrap_or_default()
}

impl crate::scene_runtime::SceneRuntime {
    /// Swift `SceneRuntime.componentDescriptions(typeID:)`.
    ///
    /// A pristine copy of the scene's registry installs each schema's default
    /// document on one throwaway entity; that document drives field inference.
    /// Schemas without a default (for example `constraint`) fall back to the first
    /// instance already authored in the scene, then to an empty object. The
    /// inspected scene is never mutated.
    pub fn component_descriptions(&self, type_id: Option<&str>) -> Vec<ComponentDescription> {
        let mut defaults_world = RuntimeWorld::new(self.component_registry().clone());
        let entity = defaults_world.create_entity();
        let schemas: Vec<ComponentSchema> = self
            .component_registry()
            .component_schemas()
            .into_iter()
            .filter(|schema| type_id.is_none_or(|id| schema.type_id == id))
            .collect();
        schemas
            .into_iter()
            .map(|schema| {
                let mut world = defaults_world.clone();
                let _ = make_default_component(&mut world, &schema, entity);
                let mut context = ComponentEncodeContext::new(BTreeMap::from([(entity, 0)]));
                let defaults = (schema.encode)(&world, entity, &mut context);
                let sample = defaults
                    .clone()
                    .or_else(|| self.authored_inspection_sample(&schema))
                    .unwrap_or_else(|| ComponentValue::Object(BTreeMap::new()));
                ComponentDescription {
                    type_id: schema.type_id.clone(),
                    display_name: schema.display_name.clone(),
                    category: schema.category,
                    requires: schema.requires.clone(),
                    is_user_addable: schema.is_user_addable,
                    fields: schema.inspection.resolved_fields(&sample),
                    defaults,
                }
            })
            .collect()
    }

    /// Swift `authoredInspectionSample(_:)` — the first authored document of
    /// `schema` anywhere in the scene.
    fn authored_inspection_sample(&self, schema: &ComponentSchema) -> Option<ComponentValue> {
        let entities = self.entities();
        let mut context = ComponentEncodeContext::new(
            entities
                .iter()
                .enumerate()
                .map(|(index, entity)| (*entity, index as i64))
                .collect(),
        );
        self.read_world(|world| {
            entities
                .iter()
                .find_map(|entity| (schema.encode)(world, *entity, &mut context))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_label_splits_camel_case_and_separators() {
        assert_eq!(
            ComponentFieldDescriptor::display_label("baseColorFactor"),
            "Base Color Factor"
        );
        assert_eq!(
            ComponentFieldDescriptor::display_label("spot_inner-angle"),
            "Spot Inner Angle"
        );
        assert_eq!(ComponentFieldDescriptor::display_label("is2D"), "Is2 D");
    }

    /// Assertions captured from Swift 6.4.1 running the original
    /// `replacingOccurrences(of: "([a-z0-9])([A-Z])", ...)` + `.capitalized`.
    #[test]
    fn display_label_matches_swift_for_awkward_keys() {
        let cases = [
            ("typeID", "Type Id"),
            ("URLPath", "Urlpath"),
            ("FOVY", "Fovy"),
            ("aB", "A B"),
            ("camelCaseMultiWordXYZ", "Camel Case Multi Word Xyz"),
            ("fovYRadians", "Fov Yradians"),
            ("meshIndex", "Mesh Index"),
            ("A", "A"),
            ("x", "X"),
        ];
        for (key, expected) in cases {
            assert_eq!(
                ComponentFieldDescriptor::display_label(key),
                expected,
                "key {key}"
            );
        }
    }

    #[test]
    fn choice_defaults_label_and_value_from_id() {
        let choice = ComponentFieldChoice::new("linearCast");
        assert_eq!(choice.label, "Linear Cast");
        assert_eq!(
            choice.value,
            ComponentValue::String("linearCast".to_string())
        );
    }

    #[test]
    fn resolved_fields_infers_object_leaves_in_sorted_order() {
        let inspection = ComponentInspection::new();
        let document = ComponentValue::Object(
            [
                ("zeta".to_string(), ComponentValue::Number(1.0)),
                ("alpha".to_string(), ComponentValue::Bool(true)),
            ]
            .into_iter()
            .collect(),
        );
        let fields = inspection.resolved_fields(&document);
        assert_eq!(fields.len(), 2);
        assert_eq!(fields[0].path, vec!["alpha".to_string()]);
        assert_eq!(fields[0].kind, ComponentFieldKind::Boolean);
        assert_eq!(fields[1].path, vec!["zeta".to_string()]);
        assert_eq!(fields[1].kind, ComponentFieldKind::Number);
    }

    #[test]
    fn resolved_fields_marks_vector3() {
        let inspection = ComponentInspection::new();
        let document = ComponentValue::Object(
            [(
                "colorTint".to_string(),
                ComponentValue::Array(vec![
                    ComponentValue::Number(1.0),
                    ComponentValue::Number(0.5),
                    ComponentValue::Number(0.0),
                ]),
            )]
            .into_iter()
            .collect(),
        );
        let fields = inspection.resolved_fields(&document);
        assert_eq!(fields[0].kind, ComponentFieldKind::Vector3);
    }

    #[test]
    fn explicit_field_keeps_kind_and_grouping() {
        let mut inspection = ComponentInspection::new();
        let mut field =
            ComponentFieldDescriptor::new(vec!["nested".to_string(), "value".to_string()]);
        field.kind = ComponentFieldKind::Color;
        inspection.fields = vec![field];
        let document = ComponentValue::Object(
            [(
                "nested".to_string(),
                ComponentValue::Object(
                    [("value".to_string(), ComponentValue::Number(1.0))]
                        .into_iter()
                        .collect(),
                ),
            )]
            .into_iter()
            .collect(),
        );
        let fields = inspection.resolved_fields(&document);
        let explicit = fields
            .iter()
            .find(|field| field.path == vec!["nested".to_string(), "value".to_string()])
            .expect("explicit field");
        // Explicit kind is authoritative over inference.
        assert_eq!(explicit.kind, ComponentFieldKind::Color);
        assert_eq!(explicit.group.as_deref(), Some("Nested"));
        // The declared field suppresses the inferred duplicate at the same path.
        assert_eq!(
            fields
                .iter()
                .filter(|field| field.path == vec!["nested".to_string(), "value".to_string()])
                .count(),
            1
        );
    }

    #[test]
    fn read_only_inspection_propagates_to_every_field() {
        let mut inspection = ComponentInspection::new();
        inspection.is_read_only = true;
        let document = ComponentValue::Object(
            [("a".to_string(), ComponentValue::Number(1.0))]
                .into_iter()
                .collect(),
        );
        assert!(inspection.resolved_fields(&document)[0].is_read_only);
    }
}
