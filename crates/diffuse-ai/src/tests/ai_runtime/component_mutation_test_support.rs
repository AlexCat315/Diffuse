//! Ported from `Engine/Tests/AIRuntimeTests/ComponentMutationTestSupport.swift`.
//!
//! Swift extended `SceneMutation` and `TransactionOperation` directly. Rust's
//! orphan rules forbid inherent extensions on foreign types, so the same two
//! helpers become a local trait implemented for both. `SceneRuntime` owns a
//! fresh built-in registry per call, exactly as the Swift helper did.

use diffuse_intent::transactions::transaction_ir::{SceneMutation, TransactionOperation};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::components::editing::ComponentWriteMode;
use diffuse_scene::entity_id::RuntimeComponent;
use diffuse_scene::scene_runtime::SceneRuntime;
use diffuse_script::ComponentRegistryScriptCodec;

pub trait DecodedComponent {
    fn decoded_component<C: RuntimeComponent>(&self, type_id: &str) -> Option<(u64, C)>;
}

impl DecodedComponent for SceneMutation {
    fn decoded_component<C: RuntimeComponent>(&self, type_id: &str) -> Option<(u64, C)> {
        let SceneMutation::SetComponentData {
            entity_id,
            type_id: actual_type,
            value,
            ..
        } = self
        else {
            return None;
        };
        if type_id != actual_type {
            return None;
        }
        let mut registry = ComponentRegistry::built_in();
        registry.register_script_codec("cove.rotator");
        let mut scene = SceneRuntime::new(registry);
        let entity = scene.create_entity();
        let _ = scene.set_component_data(value, type_id, entity, ComponentWriteMode::Replace);
        scene
            .component::<C>(entity)
            .map(|component| (*entity_id, component))
    }
}

impl DecodedComponent for TransactionOperation {
    fn decoded_component<C: RuntimeComponent>(&self, type_id: &str) -> Option<(u64, C)> {
        match self {
            TransactionOperation::Scene(mutation) => mutation.decoded_component(type_id),
            TransactionOperation::Sequence(_) | TransactionOperation::Asset(_) => None,
        }
    }
}
