//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/Physics/Collider.swift`.

use std::collections::BTreeMap;
use std::rc::Rc;

use cove_ui_compose::scene_core::Binding;
use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::physics::collider::{Collider, ColliderShape, ColliderShapeKind};

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldPresentation, EditorInspectorFieldValue,
    EditorInspectorSection,
};
use crate::scene::manifest::physics::collider_inspector::EditorSceneManifestColliderShapeInstance;

#[derive(Clone, Copy)]
enum Axis {
    X,
    Y,
    Z,
}

impl EditorSceneAdapter {
    pub(crate) fn collider_section(&self, entity: EntityID) -> Option<EditorInspectorSection> {
        let collider = self.scene().component::<Collider>(entity)?;
        let mut fields: Vec<EditorInspectorField> = vec![EditorInspectorField::new(
            "shape-kind",
            localized("Shape"),
            EditorInspectorFieldValue::options(&self.collider_shape_kind_binding(entity)),
        )];

        match collider.shape() {
            ColliderShape::Box { .. } => fields.push(EditorInspectorField::new(
                "shape-box-extents",
                localized("Half Extents"),
                EditorInspectorFieldValue::Vector3 {
                    x: self.collider_box_half_extents_binding(entity, Axis::X),
                    y: self.collider_box_half_extents_binding(entity, Axis::Y),
                    z: self.collider_box_half_extents_binding(entity, Axis::Z),
                },
            )),
            ColliderShape::Sphere { .. } => fields.push(constrained(
                "shape-sphere-radius",
                "Radius",
                self.collider_sphere_radius_binding(entity),
                0.01,
                None,
                0.1,
            )),
            ColliderShape::Capsule { .. } => {
                fields.push(constrained(
                    "shape-capsule-radius",
                    "Radius",
                    self.collider_capsule_radius_binding(entity),
                    0.01,
                    None,
                    0.1,
                ));
                fields.push(constrained(
                    "shape-capsule-half-height",
                    "Half Height",
                    self.collider_capsule_half_height_binding(entity),
                    0.01,
                    None,
                    0.1,
                ));
            }
            ColliderShape::Cylinder { .. } => {
                fields.push(constrained(
                    "shape-cylinder-radius",
                    "Radius",
                    self.collider_cylinder_radius_binding(entity),
                    0.01,
                    None,
                    0.1,
                ));
                fields.push(constrained(
                    "shape-cylinder-half-height",
                    "Half Height",
                    self.collider_cylinder_half_height_binding(entity),
                    0.01,
                    None,
                    0.1,
                ));
            }
            ColliderShape::HeightField { .. } => fields.push(resource_field(
                "shape-heightfield-resource",
                collider.shape().resource_id().map(str::to_string),
            )),
            ColliderShape::Mesh { .. } => fields.push(resource_field(
                "shape-mesh-resource",
                collider.shape().resource_id().map(str::to_string),
            )),
            ColliderShape::Convex { .. } => fields.push(resource_field(
                "shape-convex-resource",
                collider.shape().resource_id().map(str::to_string),
            )),
        }

        fields.push(EditorInspectorField::new(
            "shape-center",
            localized("Center"),
            EditorInspectorFieldValue::Vector3 {
                x: self.collider_center_binding(entity, Axis::X),
                y: self.collider_center_binding(entity, Axis::Y),
                z: self.collider_center_binding(entity, Axis::Z),
            },
        ));
        fields.push(EditorInspectorField::new(
            "shape-instance-count",
            localized("Shape Instances"),
            EditorInspectorFieldValue::ReadOnly(collider.shapes.len().to_string()),
        ));
        fields.push(EditorInspectorField::new(
            "shape-instances",
            localized("Compound Shapes"),
            EditorInspectorFieldValue::ColliderShapeInstances(
                self.collider_shape_instance_list_binding(entity),
            ),
        ));
        fields.push(EditorInspectorField::with_options(
            "shape-instances-json",
            localized("Advanced JSON"),
            EditorInspectorFieldValue::Json {
                binding: self.collider_shape_instances_binding(entity),
                min_height: 120.0,
            },
            EditorInspectorFieldPresentation::Advanced,
            false,
            std::collections::BTreeSet::new(),
            None,
            None,
        ));
        fields.push(EditorInspectorField::new(
            "trigger",
            localized("Trigger"),
            EditorInspectorFieldValue::Bool(self.collider_trigger_binding(entity)),
        ));
        fields.push(constrained(
            "material-friction",
            "Friction",
            self.collider_friction_binding(entity),
            0.0,
            None,
            0.1,
        ));
        fields.push(constrained(
            "material-restitution",
            "Restitution",
            self.collider_restitution_binding(entity),
            0.0,
            Some(1.0),
            0.05,
        ));
        fields.push(constrained(
            "material-density",
            "Density",
            self.collider_density_binding(entity),
            0.0,
            None,
            0.1,
        ));
        fields.push(constrained(
            "layer",
            "Layer",
            self.collider_layer_binding(entity),
            0.0,
            Some(65_535.0),
            1.0,
        ));
        fields.push(constrained(
            "layer-mask",
            "Layer Mask",
            self.collider_layer_mask_binding(entity),
            0.0,
            Some(65_535.0),
            1.0,
        ));

        Some(EditorInspectorSection::new(
            "collider",
            localized("Collider"),
            fields,
        ))
    }

    fn collider_center_binding(&self, entity: EntityID, axis: Axis) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Collider>(entity)
                    .map(|collider| axis_value(collider.shape().center(), axis))
                    .unwrap_or(0.0)
            },
            move |next: f32| {
                let Some(mut collider) = set_adapter.scene().component::<Collider>(entity) else {
                    return;
                };
                if axis_value(collider.shape().center(), axis) == next {
                    return;
                }
                let center = set_axis_value(collider.shape().center(), axis, next);
                collider.set_shape(collider.shape().replacing_center(center));
                let _ = set_adapter.set_component_data(collider, entity);
            },
        )
    }

    fn collider_trigger_binding(&self, entity: EntityID) -> Binding<bool> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Collider>(entity)
                    .map(|collider| collider.is_trigger)
                    .unwrap_or(false)
            },
            move |next: bool| {
                let Some(collider) = set_adapter.scene().component::<Collider>(entity) else {
                    return;
                };
                if collider.is_trigger == next {
                    return;
                }
                set_collider_fields(
                    &set_adapter,
                    entity,
                    "scene.set_collider_trigger",
                    "Update collider trigger flag",
                    vec![("isTrigger".to_string(), Some(ComponentValue::Bool(next)))],
                );
            },
        )
    }

    fn collider_shape_kind_binding(&self, entity: EntityID) -> Binding<ColliderShapeKind> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Collider>(entity)
                    .map(|collider| collider.shape().kind())
                    .unwrap_or(ColliderShapeKind::Box)
            },
            move |next: ColliderShapeKind| {
                let Some(collider) = set_adapter.scene().component::<Collider>(entity) else {
                    return;
                };
                if collider.shape().kind() == next {
                    return;
                }
                let default_fields = ComponentValue::Object(next.default_component_fields());
                let shapes =
                    ComponentValue::Object(BTreeMap::from([("0".to_string(), default_fields)]));
                set_collider_fields(
                    &set_adapter,
                    entity,
                    "scene.set_collider_shape_type",
                    "Update collider shape type",
                    vec![("shapes".to_string(), Some(shapes))],
                );
            },
        )
    }

    fn collider_box_half_extents_binding(&self, entity: EntityID, axis: Axis) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || match get_adapter
                .scene()
                .component::<Collider>(entity)
                .map(|c| c.shape())
            {
                Some(ColliderShape::Box { half_extents, .. }) => axis_value(half_extents, axis),
                _ => 0.5,
            },
            move |next: f32| {
                let Some(collider) = set_adapter.scene().component::<Collider>(entity) else {
                    return;
                };
                let ColliderShape::Box { half_extents, .. } = collider.shape() else {
                    return;
                };
                if axis_value(half_extents, axis) == next {
                    return;
                }
                let half_extents = set_axis_value(half_extents, axis, next.max(0.01));
                let shapes = ComponentValue::Object(BTreeMap::from([(
                    "0".to_string(),
                    ComponentValue::Object(BTreeMap::from([(
                        "halfExtents".to_string(),
                        float3_value(half_extents),
                    )])),
                )]));
                set_collider_fields(
                    &set_adapter,
                    entity,
                    "scene.set_collider_box_extents",
                    "Update collider box extents",
                    vec![("shapes".to_string(), Some(shapes))],
                );
            },
        )
    }

    fn collider_sphere_radius_binding(&self, entity: EntityID) -> Binding<f32> {
        shape_float_binding(
            self,
            entity,
            |shape| match shape {
                ColliderShape::Sphere { radius, .. } => Some(*radius),
                _ => None,
            },
            0.5,
            |shape, value| match shape {
                ColliderShape::Sphere { center, .. } => Some(ColliderShape::Sphere {
                    radius: value,
                    center: *center,
                }),
                _ => None,
            },
            "scene.set_collider_sphere_radius",
            "Update collider sphere radius",
            "radius",
        )
    }

    fn collider_capsule_radius_binding(&self, entity: EntityID) -> Binding<f32> {
        shape_float_binding(
            self,
            entity,
            |shape| match shape {
                ColliderShape::Capsule { radius, .. } => Some(*radius),
                _ => None,
            },
            0.5,
            |shape, value| match shape {
                ColliderShape::Capsule {
                    half_height,
                    center,
                    ..
                } => Some(ColliderShape::Capsule {
                    radius: value,
                    half_height: *half_height,
                    center: *center,
                }),
                _ => None,
            },
            "scene.set_collider_capsule_radius",
            "Update collider capsule radius",
            "radius",
        )
    }

    fn collider_capsule_half_height_binding(&self, entity: EntityID) -> Binding<f32> {
        shape_float_binding(
            self,
            entity,
            |shape| match shape {
                ColliderShape::Capsule { half_height, .. } => Some(*half_height),
                _ => None,
            },
            0.5,
            |shape, value| match shape {
                ColliderShape::Capsule { radius, center, .. } => Some(ColliderShape::Capsule {
                    radius: *radius,
                    half_height: value,
                    center: *center,
                }),
                _ => None,
            },
            "scene.set_collider_capsule_half_height",
            "Update collider capsule half height",
            "halfHeight",
        )
    }

    fn collider_cylinder_radius_binding(&self, entity: EntityID) -> Binding<f32> {
        cylinder_float_binding(self, entity, CylinderField::Radius)
    }

    fn collider_cylinder_half_height_binding(&self, entity: EntityID) -> Binding<f32> {
        cylinder_float_binding(self, entity, CylinderField::HalfHeight)
    }

    fn collider_shape_instances_binding(&self, entity: EntityID) -> Binding<String> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let Some(collider) = get_adapter.scene().component::<Collider>(entity) else {
                    return "[]".to_string();
                };
                let encoded: Vec<EditorSceneManifestColliderShapeInstance> = collider
                    .shapes
                    .iter()
                    .map(EditorSceneManifestColliderShapeInstance::new)
                    .collect();
                diffuse_assets::swift_json::to_sorted_pretty(&encoded)
                    .unwrap_or_else(|_| "[]".to_string())
            },
            move |text: String| {
                let Ok(encoded) =
                    serde_json::from_str::<Vec<EditorSceneManifestColliderShapeInstance>>(&text)
                else {
                    return;
                };
                if encoded.is_empty() {
                    return;
                }
                let Some(mut collider) = set_adapter.scene().component::<Collider>(entity) else {
                    return;
                };
                let shapes: Vec<diffuse_scene::physics::collider::ColliderShapeInstance> =
                    encoded.iter().map(|instance| instance.instance()).collect();
                if shapes == collider.shapes {
                    return;
                }
                collider.shapes = shapes;
                let _ = set_adapter.set_component_data(collider, entity);
            },
        )
    }

    fn collider_shape_instance_list_binding(
        &self,
        entity: EntityID,
    ) -> Binding<Vec<diffuse_scene::physics::collider::ColliderShapeInstance>> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<Collider>(entity)
                    .map(|collider| collider.shapes)
                    .unwrap_or_default()
            },
            move |shapes: Vec<diffuse_scene::physics::collider::ColliderShapeInstance>| {
                if shapes.is_empty() {
                    return;
                }
                let Some(mut collider) = set_adapter.scene().component::<Collider>(entity) else {
                    return;
                };
                if collider.shapes == shapes {
                    return;
                }
                collider.shapes = shapes;
                let _ = set_adapter.set_component_data(collider, entity);
            },
        )
    }

    fn collider_friction_binding(&self, entity: EntityID) -> Binding<f32> {
        material_binding(
            self,
            entity,
            MaterialField::Friction,
            "scene.set_collider_friction",
            "Update collider friction",
            |value| value.max(0.0),
        )
    }

    fn collider_restitution_binding(&self, entity: EntityID) -> Binding<f32> {
        material_binding(
            self,
            entity,
            MaterialField::Restitution,
            "scene.set_collider_restitution",
            "Update collider restitution",
            |value| value.clamp(0.0, 1.0),
        )
    }

    fn collider_density_binding(&self, entity: EntityID) -> Binding<f32> {
        material_binding(
            self,
            entity,
            MaterialField::Density,
            "scene.set_collider_density",
            "Update collider density",
            |value| value.max(0.0),
        )
    }

    fn collider_layer_binding(&self, entity: EntityID) -> Binding<f32> {
        layer_binding(
            self,
            entity,
            LayerField::Layer,
            "scene.set_collider_layer",
            "Update collider layer",
        )
    }

    fn collider_layer_mask_binding(&self, entity: EntityID) -> Binding<f32> {
        layer_binding(
            self,
            entity,
            LayerField::Mask,
            "scene.set_collider_layer_mask",
            "Update collider layer mask",
        )
    }
}

fn constrained(
    id: &str,
    label: &str,
    binding: Binding<f32>,
    min: f32,
    max: Option<f32>,
    step: f32,
) -> EditorInspectorField {
    EditorInspectorField::new(
        id,
        localized(label),
        EditorInspectorFieldValue::ConstrainedNumber {
            binding,
            min: Some(min),
            max,
            step: Some(step),
            shows_stepper: true,
        },
    )
}

fn resource_field(id: &str, resource_id: Option<String>) -> EditorInspectorField {
    EditorInspectorField::new(
        id,
        localized("Resource"),
        EditorInspectorFieldValue::ReadOnly(resource_id.unwrap_or_else(|| localized("(auto)"))),
    )
}

fn axis_value(value: Float3, axis: Axis) -> f32 {
    match axis {
        Axis::X => value.x,
        Axis::Y => value.y,
        Axis::Z => value.z,
    }
}

fn set_axis_value(value: Float3, axis: Axis, component: f32) -> Float3 {
    match axis {
        Axis::X => Float3::new(component, value.y, value.z),
        Axis::Y => Float3::new(value.x, component, value.z),
        Axis::Z => Float3::new(value.x, value.y, component),
    }
}

fn float3_value(value: Float3) -> ComponentValue {
    ComponentValue::Array(vec![
        ComponentValue::Number(f64::from(value.x)),
        ComponentValue::Number(f64::from(value.y)),
        ComponentValue::Number(f64::from(value.z)),
    ])
}

fn set_collider_fields(
    adapter: &EditorSceneAdapter,
    entity: EntityID,
    verb: &str,
    summary: &str,
    fields: Vec<(String, Option<ComponentValue>)>,
) {
    let _ = adapter.apply_scene_transaction(
        verb,
        summary,
        vec![entity.raw_value()],
        vec![SceneMutation::component_fields(
            entity.raw_value(),
            "collider",
            fields,
        )],
    );
}

fn shape_float_binding(
    adapter: &EditorSceneAdapter,
    entity: EntityID,
    get: impl Fn(&ColliderShape) -> Option<f32> + 'static,
    default: f32,
    rebuild: impl Fn(&ColliderShape, f32) -> Option<ColliderShape> + 'static,
    verb: &'static str,
    summary: &'static str,
    field: &'static str,
) -> Binding<f32> {
    let get_adapter = adapter.clone();
    let set_adapter = adapter.clone();
    let get: Rc<dyn Fn(&ColliderShape) -> Option<f32>> = Rc::new(get);
    let rebuild: Rc<dyn Fn(&ColliderShape, f32) -> Option<ColliderShape>> = Rc::new(rebuild);
    let get_get = get.clone();
    Binding::new(
        move || {
            get_adapter
                .scene()
                .component::<Collider>(entity)
                .and_then(|collider| get_get(&collider.shape()))
                .unwrap_or(default)
        },
        move |next: f32| {
            let clamped = next.max(0.01);
            let Some(collider) = set_adapter.scene().component::<Collider>(entity) else {
                return;
            };
            let Some(current) = get(&collider.shape()) else {
                return;
            };
            if current == clamped {
                return;
            }
            if rebuild(&collider.shape(), clamped).is_none() {
                return;
            }
            let shapes = ComponentValue::Object(BTreeMap::from([(
                "0".to_string(),
                ComponentValue::Object(BTreeMap::from([(
                    field.to_string(),
                    ComponentValue::Number(f64::from(clamped)),
                )])),
            )]));
            set_collider_fields(
                &set_adapter,
                entity,
                verb,
                summary,
                vec![("shapes".to_string(), Some(shapes))],
            );
        },
    )
}

#[derive(Clone, Copy)]
enum CylinderField {
    Radius,
    HalfHeight,
}

fn cylinder_float_binding(
    adapter: &EditorSceneAdapter,
    entity: EntityID,
    field: CylinderField,
) -> Binding<f32> {
    let get_adapter = adapter.clone();
    let set_adapter = adapter.clone();
    Binding::new(
        move || match (
            get_adapter
                .scene()
                .component::<Collider>(entity)
                .map(|c| c.shape()),
            field,
        ) {
            (Some(ColliderShape::Cylinder { radius, .. }), CylinderField::Radius) => radius,
            (Some(ColliderShape::Cylinder { half_height, .. }), CylinderField::HalfHeight) => {
                half_height
            }
            _ => 0.5,
        },
        move |next: f32| {
            let clamped = next.max(0.01);
            let Some(mut collider) = set_adapter.scene().component::<Collider>(entity) else {
                return;
            };
            let ColliderShape::Cylinder {
                radius,
                half_height,
                center,
            } = collider.shape()
            else {
                return;
            };
            let current = match field {
                CylinderField::Radius => radius,
                CylinderField::HalfHeight => half_height,
            };
            if current == clamped {
                return;
            }
            collider.set_shape(match field {
                CylinderField::Radius => ColliderShape::Cylinder {
                    radius: clamped,
                    half_height,
                    center,
                },
                CylinderField::HalfHeight => ColliderShape::Cylinder {
                    radius,
                    half_height: clamped,
                    center,
                },
            });
            let _ = set_adapter.set_component_data(collider, entity);
        },
    )
}

#[derive(Clone, Copy)]
enum MaterialField {
    Friction,
    Restitution,
    Density,
}

fn material_value(collider: &Collider, field: MaterialField) -> f32 {
    match field {
        MaterialField::Friction => collider.material.friction,
        MaterialField::Restitution => collider.material.restitution,
        MaterialField::Density => collider.material.density,
    }
}

fn material_binding(
    adapter: &EditorSceneAdapter,
    entity: EntityID,
    field: MaterialField,
    verb: &'static str,
    summary: &'static str,
    clamp: impl Fn(f32) -> f32 + 'static,
) -> Binding<f32> {
    let get_adapter = adapter.clone();
    let set_adapter = adapter.clone();
    Binding::new(
        move || {
            get_adapter
                .scene()
                .component::<Collider>(entity)
                .map(|collider| material_value(&collider, field))
                .unwrap_or_else(|| match field {
                    MaterialField::Friction => 0.6,
                    MaterialField::Restitution => 0.0,
                    MaterialField::Density => 1.0,
                })
        },
        move |next: f32| {
            let clamped = clamp(next);
            let Some(collider) = set_adapter.scene().component::<Collider>(entity) else {
                return;
            };
            if material_value(&collider, field) == clamped {
                return;
            }
            let key = match field {
                MaterialField::Friction => "friction",
                MaterialField::Restitution => "restitution",
                MaterialField::Density => "density",
            };
            set_collider_fields(
                &set_adapter,
                entity,
                verb,
                summary,
                vec![(
                    key.to_string(),
                    Some(ComponentValue::Number(f64::from(clamped))),
                )],
            );
        },
    )
}

#[derive(Clone, Copy)]
enum LayerField {
    Layer,
    Mask,
}

fn layer_binding(
    adapter: &EditorSceneAdapter,
    entity: EntityID,
    field: LayerField,
    verb: &'static str,
    summary: &'static str,
) -> Binding<f32> {
    let get_adapter = adapter.clone();
    let set_adapter = adapter.clone();
    Binding::new(
        move || {
            get_adapter
                .scene()
                .component::<Collider>(entity)
                .map(|collider| match field {
                    LayerField::Layer => collider.layer_id as f32,
                    LayerField::Mask => collider.layer_mask as f32,
                })
                .unwrap_or(0.0)
        },
        move |next: f32| {
            let clamped = next.clamp(0.0, 65_535.0) as u16;
            let Some(collider) = set_adapter.scene().component::<Collider>(entity) else {
                return;
            };
            let current = match field {
                LayerField::Layer => collider.layer_id,
                LayerField::Mask => collider.layer_mask,
            };
            if current == clamped {
                return;
            }
            let key = match field {
                LayerField::Layer => "layerID",
                LayerField::Mask => "layerMask",
            };
            set_collider_fields(
                &set_adapter,
                entity,
                verb,
                summary,
                vec![(
                    key.to_string(),
                    Some(ComponentValue::Number(f64::from(clamped))),
                )],
            );
        },
    )
}

/// Drops the legacy single-shape fields once the typed compound editor is present.
/// The scene adapter keeps them for existing clients, but presenting them again
/// would edit shape #1 twice and duplicate the shape count.
pub fn collider_section_presentation(section: EditorInspectorSection) -> EditorInspectorSection {
    if !section
        .fields
        .iter()
        .any(|field| field.id == "shape-instances")
    {
        return section;
    }
    let redundant: std::collections::BTreeSet<&str> = [
        "shape-kind",
        "shape-box-extents",
        "shape-sphere-radius",
        "shape-capsule-radius",
        "shape-capsule-half-height",
        "shape-cylinder-radius",
        "shape-cylinder-half-height",
        "shape-heightfield-resource",
        "shape-mesh-resource",
        "shape-convex-resource",
        "shape-center",
        "shape-instance-count",
    ]
    .into_iter()
    .collect();
    let mut result = section;
    result
        .fields
        .retain(|field| !redundant.contains(field.id.as_str()));
    result
}
