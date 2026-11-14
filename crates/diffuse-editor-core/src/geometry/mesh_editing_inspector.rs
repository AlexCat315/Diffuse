//! `Editor/Sources/EditorCore/Geometry/MeshEditingInspector.swift`.

use std::collections::BTreeSet;
use std::rc::Rc;

use cove_ui_compose::scene_core::Binding;
use diffuse_math::simd::simd_compat::Float3;

use crate::localization::localized;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField as Field, EditorInspectorFieldValue as Value,
    EditorInspectorSection as Section, EditorInspectorStringOption,
};

use super::editor_mesh_editing::{EditorMeshEditing, EditorMeshExtrusionDirection};
use super::editor_mesh_picker::EditorMeshSelectionMode;

impl EditorMeshEditing {
    pub fn inspector_sections(self: &Rc<Self>, entity: u64) -> Vec<Section> {
        if !self.is_editing() || self.has_topology_preview() || self.entity_id() != Some(entity) {
            return Vec::new();
        }
        let selected = self.selection.borrow().len();
        let mut fields = vec![Field::new(
            "mesh-selection-count", localized("Selected"),
            Value::ReadOnly(format!("{selected} {}", localized(self.mode().title()))),
        )];
        if let Some(center) = self.selection_center() {
            let axis = |get: fn(Float3) -> f32, set: fn(&mut Float3, f32)| {
                self.mesh_binding(get(center), move |editor| editor.selection_center().map_or(get(center), get),
                    move |editor, value| {
                        if editor.entity_id() == Some(entity) && let Some(mut point) = editor.selection_center() {
                            set(&mut point, value);
                            editor.move_selection_center(point);
                        }
                    })
            };
            fields.push(Field::new("mesh-selection-center", localized("Center"), Value::Vector3 {
                x: axis(|point| point.x, |point, value| point.x = value),
                y: axis(|point| point.y, |point, value| point.y = value),
                z: axis(|point| point.z, |point, value| point.z = value),
            }));
        }
        fields.push(self.mesh_action("mesh-select-all", "Selection", "Select All", entity, Self::select_all));
        fields.push(self.mesh_action("mesh-select-none", "Selection", "Deselect", entity, |editor| {
            editor.select(BTreeSet::new(), false, false);
        }));
        if self.mode() == EditorMeshSelectionMode::Face && selected > 0 {
            fields.push(Field::new("mesh-extrude-direction", localized("Direction"), Value::StringOptions {
                binding: self.mesh_binding("normal".to_owned(), |editor| editor.extrusion_direction.get().raw_value().into(),
                    |editor, value| {
                        if let Some(direction) = EditorMeshExtrusionDirection::ALL.into_iter()
                            .find(|direction| direction.raw_value() == value)
                        {
                            editor.extrusion_direction.set(direction);
                        }
                    }),
                options: EditorMeshExtrusionDirection::ALL.into_iter().map(|direction| {
                    let value = direction.raw_value();
                    let label = if direction == EditorMeshExtrusionDirection::Normal { localized("Normal") }
                        else { value.to_ascii_uppercase() };
                    EditorInspectorStringOption::new(value, label)
                }).collect(),
            }));
            fields.push(Field::new("mesh-extrude-distance", localized("Distance"), Value::ConstrainedNumber {
                binding: self.mesh_binding(0.25, |editor| editor.extrusion_distance.get(),
                    |editor, value| editor.extrusion_distance.set(value)),
                min: Some(-1000.0), max: Some(1000.0), step: Some(0.05), shows_stepper: true,
            }));
            fields.push(self.mesh_action("mesh-extrude-region", "Topology", "Extrude Region", entity, |editor| {
                editor.extrude_region();
            }));
        }
        let mut section = Section::new("mesh-edit-selection", localized("Mesh Selection"), fields);
        section.supports_multi_selection = false;
        vec![section]
    }

    fn mesh_binding<T: Clone + 'static>(
        self: &Rc<Self>, fallback: T, get: impl Fn(&Self) -> T + 'static,
        set: impl Fn(&Self, T) + 'static,
    ) -> Binding<T> {
        let read = Rc::downgrade(self);
        let write = read.clone();
        Binding::new(
            move || read.upgrade().map_or_else(|| fallback.clone(), |editor| get(&editor)),
            move |value| {
                if let Some(editor) = write.upgrade() { set(&editor, value); }
            },
        )
    }

    fn mesh_action(
        self: &Rc<Self>, id: &str, label: &str, title: &str, entity: u64,
        action: impl Fn(&Self) + 'static,
    ) -> Field {
        let weak = Rc::downgrade(self);
        Field::new(id, localized(label), Value::Action {
            title: localized(title), is_destructive: false,
            action: Rc::new(move || {
                if let Some(editor) = weak.upgrade() && editor.entity_id() == Some(entity) {
                    action(&editor);
                }
            }),
        })
    }
}
