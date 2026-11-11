//! `Editor/Sources/EditorCore/Scene/Adapter/Inspector/General.swift`.

use cove_ui_compose::scene_core::Binding;
use diffuse_intent::transactions::transaction_ir::SceneMutation;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_scene::entity_id::EntityID;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_bootstrap::SceneNameComponent;

use crate::localization::localized;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::adapter::support::editor_scene_transform_math::{
    compose_matrix, decompose_rotation_scale, euler_xyz_from_matrix, matrix_from_euler_xyz,
};
use crate::scene::editor_inspector_schema::{
    EditorInspectorField, EditorInspectorFieldValue, EditorInspectorSection,
};

#[derive(Clone, Copy)]
enum TransformAxis {
    X,
    Y,
    Z,
}

impl EditorSceneAdapter {
    pub(crate) fn general_section(&self, entity: EntityID) -> EditorInspectorSection {
        let fields: Vec<EditorInspectorField> = vec![
            EditorInspectorField::new(
                "name",
                localized("Name"),
                EditorInspectorFieldValue::Text(self.name_binding(entity)),
            ),
            EditorInspectorField::new(
                "kind",
                localized("Kind"),
                EditorInspectorFieldValue::ReadOnly(self.display_kind(entity)),
            ),
            EditorInspectorField::new(
                "entity-id",
                localized("Entity ID"),
                EditorInspectorFieldValue::ReadOnly(entity.raw_value().to_string()),
            ),
        ];
        EditorInspectorSection::new("general", localized("General"), fields)
    }

    pub(crate) fn hierarchy_section(&self, entity: EntityID) -> EditorInspectorSection {
        let scene = self.scene();
        let parent_label = match scene.parent(entity) {
            Some(parent) => self.display_name(parent),
            None => localized("Root"),
        };
        let fields: Vec<EditorInspectorField> = vec![
            EditorInspectorField::new(
                "parent",
                localized("Parent"),
                EditorInspectorFieldValue::ReadOnly(parent_label),
            ),
            EditorInspectorField::new(
                "children",
                localized("Children"),
                EditorInspectorFieldValue::ReadOnly(scene.children(entity).len().to_string()),
            ),
        ];
        EditorInspectorSection::new("hierarchy", localized("Hierarchy"), fields)
    }

    pub(crate) fn transform_section(&self, entity: EntityID) -> Option<EditorInspectorSection> {
        let scene = self.scene();
        let local = scene.local_transform(entity);
        let world = scene.world_transform(entity);
        if local.is_none() && world.is_none() {
            return None;
        }

        let mut fields: Vec<EditorInspectorField> = Vec::new();
        if local.is_some() {
            fields.push(EditorInspectorField::new(
                "local-position",
                localized("Local Position"),
                EditorInspectorFieldValue::Vector3 {
                    x: self.local_position_binding(entity, TransformAxis::X),
                    y: self.local_position_binding(entity, TransformAxis::Y),
                    z: self.local_position_binding(entity, TransformAxis::Z),
                },
            ));
            fields.push(EditorInspectorField::new(
                "local-rotation",
                localized("Rotation"),
                EditorInspectorFieldValue::Vector3 {
                    x: self.local_rotation_binding(entity, TransformAxis::X),
                    y: self.local_rotation_binding(entity, TransformAxis::Y),
                    z: self.local_rotation_binding(entity, TransformAxis::Z),
                },
            ));
            fields.push(EditorInspectorField::new(
                "local-scale",
                localized("Scale"),
                EditorInspectorFieldValue::Vector3 {
                    x: self.local_scale_binding(entity, TransformAxis::X),
                    y: self.local_scale_binding(entity, TransformAxis::Y),
                    z: self.local_scale_binding(entity, TransformAxis::Z),
                },
            ));
        }
        if let Some(world) = world {
            let displayed = self
                .entity_world_position(entity.raw_value())
                .unwrap_or_else(|| world.translation());
            fields.push(EditorInspectorField::new(
                "world-position",
                localized("World Position"),
                EditorInspectorFieldValue::ReadOnly(self.format_vector(displayed)),
            ));
        }

        Some(EditorInspectorSection::new(
            "transform",
            localized("Transform"),
            fields,
        ))
    }

    fn name_binding(&self, entity: EntityID) -> Binding<String> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                get_adapter
                    .scene()
                    .component::<SceneNameComponent>(entity)
                    .map(|component| component.value)
                    .unwrap_or_else(|| get_adapter.fallback_name(entity))
            },
            move |next: String| {
                let trimmed = next.trim();
                let value = if trimmed.is_empty() {
                    set_adapter.fallback_name(entity)
                } else {
                    trimmed.to_string()
                };
                let current = set_adapter
                    .scene()
                    .component::<SceneNameComponent>(entity)
                    .map(|component| component.value);
                if current == Some(value.clone()) {
                    return;
                }
                let _ = set_adapter.apply_scene_transaction(
                    "scene.set_name",
                    "Rename entity",
                    vec![entity.raw_value()],
                    vec![SceneMutation::SetSceneName {
                        entity_id: entity.raw_value(),
                        value,
                    }],
                );
            },
        )
    }

    fn local_position_binding(&self, entity: EntityID, axis: TransformAxis) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let translation = get_adapter
                    .scene()
                    .local_transform(entity)
                    .map(|local| local.translation())
                    .unwrap_or(Float3::ZERO);
                axis_component(translation, axis)
            },
            move |next: f32| {
                let mut local = set_adapter
                    .scene()
                    .local_transform(entity)
                    .unwrap_or_else(LocalTransform::default);
                let translation = local.translation();
                if axis_component(translation, axis) == next {
                    return;
                }
                let translation = set_axis_component(translation, axis, next);
                local.matrix.set_column(
                    3,
                    Float4::new(translation.x, translation.y, translation.z, 1.0),
                );
                let _ = set_adapter.apply_scene_transaction(
                    "scene.set_local_transform",
                    "Update entity translation",
                    vec![entity.raw_value()],
                    vec![SceneMutation::SetLocalTransform {
                        entity_id: entity.raw_value(),
                        transform: local,
                    }],
                );
            },
        )
    }

    fn local_scale_binding(&self, entity: EntityID, axis: TransformAxis) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let matrix = get_adapter
                    .scene()
                    .local_transform(entity)
                    .map(|local| local.matrix)
                    .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
                let (_, scale) = decompose_rotation_scale(&matrix);
                axis_component(scale, axis)
            },
            move |next: f32| {
                let mut local = set_adapter
                    .scene()
                    .local_transform(entity)
                    .unwrap_or_else(LocalTransform::default);
                let (rotation, _) = decompose_rotation_scale(&local.matrix);
                let translation = local.translation();
                let mut scale = decompose_rotation_scale(&local.matrix).1;
                if axis_component(scale, axis) == next {
                    return;
                }
                scale = set_axis_component(scale, axis, next);
                local.matrix = compose_matrix(translation, &rotation, scale);
                let _ = set_adapter.apply_scene_transaction(
                    "scene.set_local_transform",
                    "Update entity scale",
                    vec![entity.raw_value()],
                    vec![SceneMutation::SetLocalTransform {
                        entity_id: entity.raw_value(),
                        transform: local,
                    }],
                );
            },
        )
    }

    fn local_rotation_binding(&self, entity: EntityID, axis: TransformAxis) -> Binding<f32> {
        let get_adapter = self.clone();
        let set_adapter = self.clone();
        Binding::new(
            move || {
                let matrix = get_adapter
                    .scene()
                    .local_transform(entity)
                    .map(|local| local.matrix)
                    .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
                let (rotation, _) = decompose_rotation_scale(&matrix);
                let euler = euler_xyz_from_matrix(&rotation);
                let degrees = euler * (180.0 / std::f32::consts::PI);
                axis_component(degrees, axis)
            },
            move |next: f32| {
                let mut local = set_adapter
                    .scene()
                    .local_transform(entity)
                    .unwrap_or_else(LocalTransform::default);
                let (_, scale) = decompose_rotation_scale(&local.matrix);
                let translation = local.translation();
                let current_degrees =
                    euler_xyz_from_matrix(&decompose_rotation_scale(&local.matrix).0)
                        * (180.0 / std::f32::consts::PI);
                if axis_component(current_degrees, axis) == next {
                    return;
                }
                let degrees = set_axis_component(current_degrees, axis, next);
                let radians = degrees * (std::f32::consts::PI / 180.0);
                let rotation = matrix_from_euler_xyz(radians);
                local.matrix = compose_matrix(translation, &rotation, scale);
                let _ = set_adapter.apply_scene_transaction(
                    "scene.set_local_transform",
                    "Update entity rotation",
                    vec![entity.raw_value()],
                    vec![SceneMutation::SetLocalTransform {
                        entity_id: entity.raw_value(),
                        transform: local,
                    }],
                );
            },
        )
    }
}

fn axis_component(value: Float3, axis: TransformAxis) -> f32 {
    match axis {
        TransformAxis::X => value.x,
        TransformAxis::Y => value.y,
        TransformAxis::Z => value.z,
    }
}

fn set_axis_component(value: Float3, axis: TransformAxis, component: f32) -> Float3 {
    match axis {
        TransformAxis::X => Float3::new(component, value.y, value.z),
        TransformAxis::Y => Float3::new(value.x, component, value.z),
        TransformAxis::Z => Float3::new(value.x, value.y, component),
    }
}
