//! `Editor/Sources/EditorCore/Scene/Inspector/FieldControls.swift`.
//!
//! Identifies the control a compound inspector field renders through, plus the
//! type-erased view a registered control reads and writes.

use std::any::Any;

use cove_ui_compose::scene_core::Binding;

use crate::scene::editor_inspector_schema::{
    EditorInspectorEntityOption, EditorInspectorFieldValue,
};

/// Identifies the control that renders a compound inspector field.
///
/// Generic values — text, numbers, choices, colors — render through the shared
/// control for their shape. Compound editors such as shape instance lists,
/// curves and module stacks carry an ID, so the property grid looks their control
/// up in a registry instead of switching on the value.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EditorInspectorControlID {
    pub raw_value: String,
}

impl EditorInspectorControlID {
    pub fn new(raw_value: impl Into<String>) -> Self {
        EditorInspectorControlID {
            raw_value: raw_value.into(),
        }
    }

    pub fn collider_shape_instances() -> Self {
        Self::new("collider.shape-instances")
    }

    pub fn particle_curve() -> Self {
        Self::new("particle.curve")
    }

    pub fn particle_sub_emitters() -> Self {
        Self::new("particle.sub-emitters")
    }

    pub fn particle_module_stack() -> Self {
        Self::new("particle.module-stack")
    }

    pub fn entity_reference() -> Self {
        Self::new("entity.reference")
    }
}

/// Swift's `Binding<Any>`: a two-way reference whose value type is erased.
pub type ErasedBinding = Binding<Box<dyn Any>>;

/// Swift extended `Binding` with `erased()`; Rust needs a local trait for the
/// same method on Cove's binding type.
pub trait BindingErased {
    /// Erases the value type so a registered control can read and write it.
    /// Writes of another type are dropped: a mismatched registration must never
    /// corrupt the component document.
    fn erased(&self) -> ErasedBinding;
}

impl<Value: 'static> BindingErased for Binding<Value> {
    fn erased(&self) -> ErasedBinding {
        let read = self.clone();
        let write = self.clone();
        Binding::new(
            move || Box::new(read.get()) as Box<dyn Any>,
            move |next: Box<dyn Any>| {
                if let Ok(value) = next.downcast::<Value>() {
                    write.set(*value);
                }
            },
        )
    }
}

impl EditorInspectorFieldValue {
    /// The registered control that renders this value, if it owns one.
    pub fn control_id(&self) -> Option<EditorInspectorControlID> {
        match self {
            EditorInspectorFieldValue::ColliderShapeInstances(_) => {
                Some(EditorInspectorControlID::collider_shape_instances())
            }
            EditorInspectorFieldValue::ParticleCurve(_) => {
                Some(EditorInspectorControlID::particle_curve())
            }
            EditorInspectorFieldValue::ParticleSubEmitters(_) => {
                Some(EditorInspectorControlID::particle_sub_emitters())
            }
            EditorInspectorFieldValue::ParticleModuleStack(_) => {
                Some(EditorInspectorControlID::particle_module_stack())
            }
            EditorInspectorFieldValue::EntityReference { .. } => {
                Some(EditorInspectorControlID::entity_reference())
            }
            _ => None,
        }
    }

    pub fn erased_binding(&self) -> Option<ErasedBinding> {
        match self {
            EditorInspectorFieldValue::ColliderShapeInstances(binding) => Some(binding.erased()),
            EditorInspectorFieldValue::ParticleCurve(binding) => Some(binding.erased()),
            EditorInspectorFieldValue::ParticleSubEmitters(binding) => Some(binding.erased()),
            EditorInspectorFieldValue::ParticleModuleStack(binding) => Some(binding.erased()),
            EditorInspectorFieldValue::EntityReference { binding, .. } => Some(binding.erased()),
            _ => None,
        }
    }

    /// Entity choices travel with the value, so a control can render names without
    /// knowing which component produced the field.
    pub fn entity_options(&self) -> Option<Vec<EditorInspectorEntityOption>> {
        match self {
            EditorInspectorFieldValue::EntityReference { options, .. } => Some(options.clone()),
            _ => None,
        }
    }
}
