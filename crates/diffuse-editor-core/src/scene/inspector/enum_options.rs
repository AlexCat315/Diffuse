//! `Editor/Sources/EditorCore/Scene/Inspector/EnumOptions.swift`.

use cove_ui_compose::scene_core::Binding;

use crate::scene::editor_inspector_schema::{
    EditorInspectorFieldValue, EditorInspectorStringOption,
};

/// An engine enum the inspector presents through the shared choices control.
///
/// Conformance belongs to the editor layer: option IDs are only compared inside
/// one presentation, and labels are UI strings the runtime never sees. Swift's
/// `CaseIterable` maps to [`EditorInspectorEnumOption::ALL`].
pub trait EditorInspectorEnumOption: Clone + PartialEq + 'static {
    const ALL: &'static [Self];

    fn inspector_option_id(&self) -> String;

    fn inspector_option_label(&self) -> String;
}

impl EditorInspectorFieldValue {
    /// Presents a typed enum through the shared choices control. An enum field
    /// built this way needs no dedicated case, view, multi-selection merge rule
    /// or row metric of its own.
    pub fn options<Kind: EditorInspectorEnumOption>(binding: &Binding<Kind>) -> Self {
        let read = binding.clone();
        let write = binding.clone();
        let binding = Binding::new(
            move || read.get().inspector_option_id(),
            move |next: String| {
                if let Some(kind) = Kind::ALL
                    .iter()
                    .find(|kind| kind.inspector_option_id() == next)
                {
                    write.set(kind.clone());
                }
            },
        );
        let options = Kind::ALL
            .iter()
            .map(|kind| {
                EditorInspectorStringOption::new(
                    kind.inspector_option_id(),
                    kind.inspector_option_label(),
                )
            })
            .collect();
        EditorInspectorFieldValue::StringOptions { binding, options }
    }
}
