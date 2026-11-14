//! `Editor/Sources/EditorCore/Geometry/GeometryInspector.swift`.

use std::ops::RangeInclusive;
use std::rc::Rc;

use cove_ui_compose::scene_core::{Binding, Color};
use diffuse_assets::geometry::bezier_spline::BezierControlPoint;
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::geometry_modifier::{
    GeometryAxis, GeometryModifier, GeometryModifierEntry,
};
use diffuse_assets::geometry::polygon_mesh::{GeometryError, GeometryLimits};
use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::localization::localized;
use crate::scene::editor_inspector_schema::{
    EditorInspectorField as Field, EditorInspectorFieldValue as Value,
    EditorInspectorSection as Section, EditorInspectorStringOption,
};

use super::editor_geometry_authoring::EditorGeometryAuthoring;

impl EditorGeometryAuthoring {
    pub fn inspector_sections(self: &Rc<Self>, entity_id: u64) -> Vec<Section> {
        let document = match self.document(entity_id) {
            Ok(Some(document)) => document,
            Ok(None) => return Vec::new(),
            Err(error) => {
                return vec![section(
                    "geometry-error",
                    "Geometry",
                    vec![field(
                        "geometry-error",
                        "Source",
                        Value::ReadOnly(error.to_string()),
                    )],
                )];
            }
        };
        let controls = InspectorBindings {
            authoring: self,
            entity_id,
        };
        let mut source = vec![
            field(
                "geometry-file",
                "Asset",
                Value::ReadOnly(document.name.clone()),
            ),
            field(
                "geometry-shading",
                "Shading",
                Value::StringOptions {
                    binding: controls.binding(
                        shading_value(document.shading).into(),
                        |doc| shading_value(doc.shading).into(),
                        |doc, value: String| {
                            doc.shading = match value.as_str() {
                                "flat" => GeometryShading::Flat,
                                "smooth" => GeometryShading::Smooth,
                                _ => return Err(GeometryError::invalid_parameter("shading")),
                            };
                            Ok(())
                        },
                    ),
                    options: options([("flat", "Flat"), ("smooth", "Smooth")]),
                },
            ),
        ];
        source.extend(controls.source_fields(&document.source));
        if !matches!(document.source, GeometrySource::Polygon { .. }) {
            source.push(controls.action(
                "geometry-convert",
                "Topology",
                "Convert Source to Mesh",
                false,
                |authoring, id| {
                    authoring.edit(id, |doc| {
                        doc.source = GeometrySource::Polygon {
                            mesh: doc.source.evaluate(GeometryLimits::default())?,
                        };
                        Ok(())
                    });
                },
            ));
        }
        let mut sections = vec![section("geometry-source", "Geometry", source)];
        for (index, entry) in document.modifiers.iter().enumerate() {
            sections.push(controls.modifier_section(entry, index, document.modifiers.len()));
        }
        let defaults = [
            (
                "Mirror",
                GeometryModifier::Mirror {
                    axis: GeometryAxis::X,
                    offset: 0.0,
                    weld_distance: 0.00001,
                },
            ),
            (
                "Array",
                GeometryModifier::Array {
                    count: 2,
                    offset: Float3::new(1.5, 0.0, 0.0),
                },
            ),
            ("Subdivision", GeometryModifier::Subdivision { levels: 1 }),
            ("Solidify", GeometryModifier::Solidify { thickness: 0.1 }),
        ];
        sections.push(section(
            "geometry-modifiers",
            "Add Modifier",
            defaults
                .into_iter()
                .map(|(name, operation)| {
                    controls.action(
                        format!("geometry-add-{}", name.to_ascii_lowercase()),
                        name,
                        "Add",
                        false,
                        move |authoring, id| {
                            authoring.add_modifier(operation.clone(), id);
                        },
                    )
                })
                .collect(),
        ));
        for (index, material) in document.materials.iter().enumerate() {
            let prefix = format!("geometry-material-{index}");
            let color = |c: Float4| Color {
                r: c.x,
                g: c.y,
                b: c.z,
                a: c.w,
            };
            sections.push(section(
                &prefix,
                format!("{} {}", localized("Material"), index + 1),
                vec![
                    field(
                        format!("{prefix}-name"),
                        "Name",
                        Value::Text(controls.binding(
                            material.name.clone(),
                            move |doc| {
                                doc.materials
                                    .get(index)
                                    .map_or_else(String::new, |m| m.name.clone())
                            },
                            move |doc, value| {
                                if let Some(material) = doc.materials.get_mut(index) {
                                    material.name = value;
                                }
                                Ok(())
                            },
                        )),
                    ),
                    field(
                        format!("{prefix}-color"),
                        "Base Color",
                        Value::Color(controls.binding(
                            color(material.base_color),
                            move |doc| {
                                doc.materials
                                    .get(index)
                                    .map_or(Color::WHITE, |m| color(m.base_color))
                            },
                            move |doc, value| {
                                if let Some(material) = doc.materials.get_mut(index) {
                                    material.base_color =
                                        Float4::new(value.r, value.g, value.b, value.a);
                                }
                                Ok(())
                            },
                        )),
                    ),
                    number(
                        format!("{prefix}-metallic"),
                        "Metallic",
                        controls.binding(
                            material.metallic,
                            move |doc| doc.materials.get(index).map_or(0.0, |m| m.metallic),
                            move |doc, value| {
                                if let Some(material) = doc.materials.get_mut(index) {
                                    material.metallic = value;
                                }
                                Ok(())
                            },
                        ),
                        Some(0.0),
                        Some(1.0),
                        None,
                    ),
                    number(
                        format!("{prefix}-roughness"),
                        "Roughness",
                        controls.binding(
                            material.roughness,
                            move |doc| doc.materials.get(index).map_or(0.5, |m| m.roughness),
                            move |doc, value| {
                                if let Some(material) = doc.materials.get_mut(index) {
                                    material.roughness = value;
                                }
                                Ok(())
                            },
                        ),
                        Some(0.0),
                        Some(1.0),
                        None,
                    ),
                ],
            ));
        }
        sections
    }

    pub fn apply_modifier(self: &Rc<Self>, id: &str, entity_id: u64) -> bool {
        self.edit(entity_id, |document| {
            let index = document
                .modifiers
                .iter()
                .position(|entry| entry.id == id)
                .ok_or_else(|| GeometryError::invalid_parameter("missing modifier"))?;
            let limits = GeometryLimits::default();
            let mut mesh = document.source.evaluate(limits)?;
            for entry in document.modifiers[..=index]
                .iter()
                .filter(|entry| entry.enabled)
            {
                mesh = entry.operation.apply(&mesh, limits)?;
            }
            document.source = GeometrySource::Polygon { mesh };
            document.modifiers.drain(..=index);
            Ok(())
        })
    }
}

struct InspectorBindings<'a> {
    authoring: &'a Rc<EditorGeometryAuthoring>,
    entity_id: u64,
}

impl InspectorBindings<'_> {
    fn binding<T: Clone + 'static>(
        &self,
        fallback: T,
        get: impl Fn(&GeometryDocument) -> T + 'static,
        set: impl Fn(&mut GeometryDocument, T) -> Result<(), GeometryError> + 'static,
    ) -> Binding<T> {
        let weak = Rc::downgrade(self.authoring);
        let read = weak.clone();
        let entity = self.entity_id;
        Binding::new(
            move || {
                read.upgrade()
                    .and_then(|authoring| authoring.document(entity).ok().flatten())
                    .map_or_else(|| fallback.clone(), |doc| get(&doc))
            },
            move |value| {
                if let Some(authoring) = weak.upgrade() {
                    authoring.edit(entity, |doc| set(doc, value));
                }
            },
        )
    }

    fn action(
        &self,
        id: impl Into<String>,
        label: &str,
        title: &str,
        destructive: bool,
        action: impl Fn(&Rc<EditorGeometryAuthoring>, u64) + 'static,
    ) -> Field {
        let weak = Rc::downgrade(self.authoring);
        let entity = self.entity_id;
        field(
            id,
            label,
            Value::Action {
                title: localized(title),
                is_destructive: destructive,
                action: Rc::new(move || {
                    if let Some(authoring) = weak.upgrade() {
                        action(&authoring, entity);
                    }
                }),
            },
        )
    }

    fn vector(
        &self,
        id: impl Into<String>,
        label: &str,
        fallback: Float3,
        get: impl Fn(&GeometryDocument) -> Float3 + Copy + 'static,
        set: impl Fn(&mut GeometryDocument, Float3) + Copy + 'static,
    ) -> Field {
        let axis = |index| {
            self.binding(
                vector_part(fallback, index),
                move |doc| vector_part(get(doc), index),
                move |doc, value| {
                    let mut vector = get(doc);
                    match index {
                        0 => vector.x = value,
                        1 => vector.y = value,
                        _ => vector.z = value,
                    }
                    set(doc, vector);
                    Ok(())
                },
            )
        };
        field(
            id,
            label,
            Value::Vector3 {
                x: axis(0),
                y: axis(1),
                z: axis(2),
            },
        )
    }

    fn source_fields(&self, source: &GeometrySource) -> Vec<Field> {
        match source {
            GeometrySource::Box { size } => vec![self.vector(
                "geometry-size",
                "Size",
                *size,
                |doc| match doc.source {
                    GeometrySource::Box { size } => size,
                    _ => Float3::ONE,
                },
                |doc, value| {
                    if let GeometrySource::Box { size } = &mut doc.source {
                        *size = value;
                    }
                },
            )],
            GeometrySource::Grid { size, segments } => {
                let mut fields = Vec::new();
                for (axis, width) in ["Width", "Depth"].into_iter().enumerate() {
                    let x = axis == 0;
                    fields.push(number(
                        format!("geometry-grid-size-{axis}"),
                        width,
                        self.binding(
                            if x { size.x } else { size.y },
                            move |doc| match doc.source {
                                GeometrySource::Grid { size, .. } => {
                                    if x {
                                        size.x
                                    } else {
                                        size.y
                                    }
                                }
                                _ => 1.0,
                            },
                            move |doc, value| {
                                if let GeometrySource::Grid { size, .. } = &mut doc.source {
                                    if x {
                                        size.x = value;
                                    } else {
                                        size.y = value;
                                    }
                                }
                                Ok(())
                            },
                        ),
                        Some(0.0001),
                        None,
                        None,
                    ));
                    fields.push(integer_field(
                        format!("geometry-grid-segments-{axis}"),
                        if x { "Columns" } else { "Rows" },
                        self.binding(
                            if x { segments.x } else { segments.y } as f32,
                            move |doc| match doc.source {
                                GeometrySource::Grid { segments, .. } => {
                                    (if x { segments.x } else { segments.y }) as f32
                                }
                                _ => 1.0,
                            },
                            move |doc, value| {
                                if let GeometrySource::Grid { segments, .. } = &mut doc.source {
                                    let value = integer(value, 1..=1024)? as i32;
                                    if x {
                                        segments.x = value;
                                    } else {
                                        segments.y = value;
                                    }
                                }
                                Ok(())
                            },
                        ),
                        1..=1024,
                    ));
                }
                fields
            }
            GeometrySource::Polygon { mesh } => vec![
                field(
                    "geometry-vertices",
                    "Vertices",
                    Value::ReadOnly(mesh.positions.len().to_string()),
                ),
                field(
                    "geometry-faces",
                    "Faces",
                    Value::ReadOnly(mesh.faces.len().to_string()),
                ),
            ],
            GeometrySource::Tube {
                spline,
                radius,
                radial_segments,
                samples_per_segment,
                capped,
            } => {
                let mut fields = vec![
                    number(
                        "geometry-tube-radius",
                        "Radius",
                        self.source_binding(
                            *radius,
                            |source| match source {
                                GeometrySource::Tube { radius, .. } => Some(*radius),
                                _ => None,
                            },
                            |source, value| {
                                if let GeometrySource::Tube { radius, .. } = source {
                                    *radius = value;
                                }
                                Ok(())
                            },
                        ),
                        Some(0.0001),
                        None,
                        None,
                    ),
                    integer_field(
                        "geometry-tube-radial",
                        "Sides",
                        self.source_binding(
                            *radial_segments as f32,
                            |source| match source {
                                GeometrySource::Tube {
                                    radial_segments, ..
                                } => Some(*radial_segments as f32),
                                _ => None,
                            },
                            |source, value| {
                                if let GeometrySource::Tube {
                                    radial_segments, ..
                                } = source
                                {
                                    *radial_segments = integer(value, 3..=256)?;
                                }
                                Ok(())
                            },
                        ),
                        3..=256,
                    ),
                    integer_field(
                        "geometry-tube-samples",
                        "Resolution",
                        self.source_binding(
                            *samples_per_segment as f32,
                            |source| match source {
                                GeometrySource::Tube {
                                    samples_per_segment,
                                    ..
                                } => Some(*samples_per_segment as f32),
                                _ => None,
                            },
                            |source, value| {
                                if let GeometrySource::Tube {
                                    samples_per_segment,
                                    ..
                                } = source
                                {
                                    *samples_per_segment = integer(value, 1..=4096)?;
                                }
                                Ok(())
                            },
                        ),
                        1..=4096,
                    ),
                    field(
                        "geometry-tube-capped",
                        "Caps",
                        Value::Bool(self.source_binding(
                            *capped,
                            |source| match source {
                                GeometrySource::Tube { capped, .. } => Some(*capped),
                                _ => None,
                            },
                            |source, value| {
                                if let GeometrySource::Tube { capped, .. } = source {
                                    *capped = value;
                                }
                                Ok(())
                            },
                        )),
                    ),
                    field(
                        "geometry-tube-closed",
                        "Closed",
                        Value::Bool(self.source_binding(
                            spline.closed,
                            |source| match source {
                                GeometrySource::Tube { spline, .. } => Some(spline.closed),
                                _ => None,
                            },
                            |source, value| {
                                if let GeometrySource::Tube { spline, .. } = source {
                                    spline.closed = value;
                                }
                                Ok(())
                            },
                        )),
                    ),
                ];
                for (index, point) in spline.points.iter().enumerate() {
                    type PointProperty = fn(&mut BezierControlPoint) -> &mut Float3;
                    let properties: [(&str, Float3, PointProperty); 3] = [
                        ("Position", point.position, |p| &mut p.position),
                        ("Handle In", point.handle_in, |p| &mut p.handle_in),
                        ("Handle Out", point.handle_out, |p| &mut p.handle_out),
                    ];
                    for (label, fallback, property) in properties {
                        fields.push(self.vector(
                            format!("geometry-point-{index}-{label}"),
                            &format!("{} {}", index + 1, localized(label)),
                            fallback,
                            move |doc| {
                                match &doc.source {
                                    GeometrySource::Tube { spline, .. } => {
                                        spline.points.get(index).map_or(Float3::ZERO, |point| {
                                            *property(&mut point.clone())
                                        })
                                    }
                                    _ => Float3::ZERO,
                                }
                            },
                            move |doc, value| {
                                if let GeometrySource::Tube { spline, .. } = &mut doc.source
                                    && let Some(point) = spline.points.get_mut(index)
                                {
                                    *property(point) = value;
                                }
                            },
                        ));
                    }
                }
                fields
            }
        }
    }

    fn source_binding<T: Clone + 'static>(
        &self,
        fallback: T,
        get: impl Fn(&GeometrySource) -> Option<T> + 'static,
        set: impl Fn(&mut GeometrySource, T) -> Result<(), GeometryError> + 'static,
    ) -> Binding<T> {
        self.binding(
            fallback.clone(),
            move |doc| get(&doc.source).unwrap_or_else(|| fallback.clone()),
            move |doc, value| set(&mut doc.source, value),
        )
    }

    fn modifier_section(
        &self,
        entry: &GeometryModifierEntry,
        index: usize,
        count: usize,
    ) -> Section {
        let id = entry.id.clone();
        let get_id = id.clone();
        let set_id = id.clone();
        let mut fields = vec![field(
            format!("{id}-enabled"),
            "Enabled",
            Value::Bool(self.binding(
                entry.enabled,
                move |doc| {
                    doc.modifiers
                        .iter()
                        .any(|entry| entry.id == get_id && entry.enabled)
                },
                move |doc, value| {
                    if let Some(entry) = doc.modifiers.iter_mut().find(|entry| entry.id == set_id) {
                        entry.enabled = value;
                    }
                    Ok(())
                },
            )),
        )];
        let (name, parameter_fields) = self.modifier_fields(entry);
        fields.extend(parameter_fields);
        for (available, direction, title, offset) in [
            (index > 0, "up", "Move Up", -1),
            (index + 1 < count, "down", "Move Down", 1),
        ] {
            if available {
                let modifier = id.clone();
                fields.push(self.action(
                    format!("{id}-{direction}"),
                    "Order",
                    title,
                    false,
                    move |authoring, entity| {
                        authoring.move_modifier(&modifier, offset, entity);
                    },
                ));
            }
        }
        let modifier = id.clone();
        fields.push(self.action(
            format!("{id}-apply"),
            "Topology",
            "Apply Through Modifier",
            false,
            move |authoring, entity| {
                authoring.apply_modifier(&modifier, entity);
            },
        ));
        let modifier = id.clone();
        fields.push(self.action(
            format!("{id}-remove"),
            "Modifier",
            "Remove",
            true,
            move |authoring, entity| {
                authoring.remove_modifier(&modifier, entity);
            },
        ));
        section(
            format!("geometry-modifier-{id}"),
            format!("{}. {}", index + 1, localized(name)),
            fields,
        )
    }

    fn modifier_binding<T: Clone + 'static>(
        &self,
        id: &str,
        fallback: T,
        get: impl Fn(&GeometryModifier) -> T + 'static,
        set: impl Fn(&mut GeometryModifier, T) -> Result<(), GeometryError> + 'static,
    ) -> Binding<T> {
        let read_id = id.to_owned();
        let write_id = read_id.clone();
        self.binding(
            fallback.clone(),
            move |doc| {
                doc.modifiers
                    .iter()
                    .find(|entry| entry.id == read_id)
                    .map_or_else(|| fallback.clone(), |entry| get(&entry.operation))
            },
            move |doc, value| {
                if let Some(entry) = doc.modifiers.iter_mut().find(|entry| entry.id == write_id) {
                    set(&mut entry.operation, value)?;
                }
                Ok(())
            },
        )
    }

    fn modifier_fields(&self, entry: &GeometryModifierEntry) -> (&'static str, Vec<Field>) {
        let id = entry.id.as_str();
        match entry.operation {
            GeometryModifier::Subdivision { levels } => (
                "Subdivision",
                vec![integer_field(
                    format!("{id}-levels"),
                    "Levels",
                    self.modifier_binding(
                        id,
                        levels as f32,
                        |op| match op {
                            GeometryModifier::Subdivision { levels } => *levels as f32,
                            _ => 0.0,
                        },
                        |op, value| {
                            *op = GeometryModifier::Subdivision {
                                levels: integer(value, 0..=6)?,
                            };
                            Ok(())
                        },
                    ),
                    0..=6,
                )],
            ),
            GeometryModifier::Solidify { thickness } => (
                "Solidify",
                vec![number(
                    format!("{id}-thickness"),
                    "Thickness",
                    self.modifier_binding(
                        id,
                        thickness,
                        |op| match op {
                            GeometryModifier::Solidify { thickness } => *thickness,
                            _ => 0.1,
                        },
                        |op, thickness| {
                            *op = GeometryModifier::Solidify { thickness };
                            Ok(())
                        },
                    ),
                    Some(0.0001),
                    None,
                    None,
                )],
            ),
            GeometryModifier::Array { count, offset } => {
                let axis = |index| {
                    self.modifier_binding(
                        id,
                        vector_part(offset, index),
                        move |op| match op {
                            GeometryModifier::Array { offset, .. } => vector_part(*offset, index),
                            _ => 0.0,
                        },
                        move |op, value| {
                            if let GeometryModifier::Array { offset, .. } = op {
                                match index {
                                    0 => offset.x = value,
                                    1 => offset.y = value,
                                    _ => offset.z = value,
                                }
                            }
                            Ok(())
                        },
                    )
                };
                (
                    "Array",
                    vec![
                        integer_field(
                            format!("{id}-count"),
                            "Count",
                            self.modifier_binding(
                                id,
                                count as f32,
                                |op| match op {
                                    GeometryModifier::Array { count, .. } => *count as f32,
                                    _ => 1.0,
                                },
                                |op, value| {
                                    if let GeometryModifier::Array { count, .. } = op {
                                        *count = integer(value, 1..=4096)?;
                                    }
                                    Ok(())
                                },
                            ),
                            1..=4096,
                        ),
                        field(
                            format!("{id}-offset"),
                            "Offset",
                            Value::Vector3 {
                                x: axis(0),
                                y: axis(1),
                                z: axis(2),
                            },
                        ),
                    ],
                )
            }
            GeometryModifier::Mirror {
                axis,
                offset,
                weld_distance,
            } => (
                "Mirror",
                vec![
                    field(
                        format!("{id}-axis"),
                        "Axis",
                        Value::StringOptions {
                            binding: self.modifier_binding(
                                id,
                                axis_value(axis).into(),
                                |op| match op {
                                    GeometryModifier::Mirror { axis, .. } => {
                                        axis_value(*axis).into()
                                    }
                                    _ => "x".into(),
                                },
                                |op, value: String| {
                                    if let GeometryModifier::Mirror { axis, .. } = op {
                                        *axis = match value.as_str() {
                                            "x" => GeometryAxis::X,
                                            "y" => GeometryAxis::Y,
                                            "z" => GeometryAxis::Z,
                                            _ => return Ok(()),
                                        };
                                    }
                                    Ok(())
                                },
                            ),
                            options: options([("x", "X"), ("y", "Y"), ("z", "Z")]),
                        },
                    ),
                    number(
                        format!("{id}-plane"),
                        "Plane",
                        self.modifier_binding(
                            id,
                            offset,
                            |op| match op {
                                GeometryModifier::Mirror { offset, .. } => *offset,
                                _ => 0.0,
                            },
                            |op, value| {
                                if let GeometryModifier::Mirror { offset, .. } = op {
                                    *offset = value;
                                }
                                Ok(())
                            },
                        ),
                        None,
                        None,
                        None,
                    ),
                    number(
                        format!("{id}-weld"),
                        "Weld",
                        self.modifier_binding(
                            id,
                            weld_distance,
                            |op| match op {
                                GeometryModifier::Mirror { weld_distance, .. } => *weld_distance,
                                _ => 0.0,
                            },
                            |op, value| {
                                if let GeometryModifier::Mirror { weld_distance, .. } = op {
                                    *weld_distance = value;
                                }
                                Ok(())
                            },
                        ),
                        Some(0.0),
                        None,
                        None,
                    ),
                ],
            ),
        }
    }
}

fn section(id: impl Into<String>, title: impl AsRef<str>, fields: Vec<Field>) -> Section {
    let mut section = Section::new(id, localized(title.as_ref()), fields);
    section.supports_multi_selection = false;
    section
}

fn field(id: impl Into<String>, label: &str, value: Value) -> Field {
    Field::new(id, localized(label), value)
}

fn options<const N: usize>(entries: [(&str, &str); N]) -> Vec<EditorInspectorStringOption> {
    entries
        .into_iter()
        .map(|(value, label)| EditorInspectorStringOption::new(value, localized(label)))
        .collect()
}

fn number(
    id: impl Into<String>,
    label: &str,
    binding: Binding<f32>,
    min: Option<f32>,
    max: Option<f32>,
    step: Option<f32>,
) -> Field {
    field(
        id,
        label,
        Value::ConstrainedNumber {
            binding,
            min,
            max,
            step,
            shows_stepper: true,
        },
    )
}

fn integer_field(
    id: impl Into<String>,
    label: &str,
    binding: Binding<f32>,
    range: RangeInclusive<i64>,
) -> Field {
    number(
        id,
        label,
        binding,
        Some(*range.start() as f32),
        Some(*range.end() as f32),
        Some(1.0),
    )
}

fn integer(value: f32, range: RangeInclusive<i64>) -> Result<i64, GeometryError> {
    if (*range.start() as f32..=*range.end() as f32).contains(&value) {
        Ok(value.round() as i64)
    } else {
        Err(GeometryError::invalid_parameter("integer parameter"))
    }
}

fn shading_value(shading: GeometryShading) -> &'static str {
    match shading {
        GeometryShading::Flat => "flat",
        GeometryShading::Smooth => "smooth",
    }
}

fn axis_value(axis: GeometryAxis) -> &'static str {
    match axis {
        GeometryAxis::X => "x",
        GeometryAxis::Y => "y",
        GeometryAxis::Z => "z",
    }
}

fn vector_part(vector: Float3, index: usize) -> f32 {
    match index {
        0 => vector.x,
        1 => vector.y,
        _ => vector.z,
    }
}
