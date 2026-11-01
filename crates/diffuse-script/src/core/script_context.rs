use std::cell::OnceCell;

use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::entity_id::{EntityID, RuntimeComponent};
use diffuse_scene::input_action::InputFrameState;
use diffuse_scene::physics::character_controller::{
    CharacterCommand, CharacterState, CharacterStateFrameResource,
};
use diffuse_scene::physics::collider::SpatialAABB;
use diffuse_scene::physics::queries::physics_query_types::*;
use diffuse_scene::physics::queries::trigger_detection::{TriggerEvent, TriggerFrameResource};
use diffuse_scene::physics::vehicles::vehicle_state::VehicleCommand;
use diffuse_scene::runtime_world::{LocalTransform, WorldTransform};
use diffuse_scene::scene_bootstrap::SceneNameComponent;
use diffuse_scene::scene_graph::prefab::{Prefab, PrefabError};
use diffuse_scene::scripting::RuntimeScriptPhaseContext;

use super::script_definition::{JsonValue, ScriptDefinition, ScriptParameters};
use crate::interop::component_registry_script_codec::ComponentRegistryScriptCodec;

/// Exclusive world access lasts only for this script invocation.
pub struct ScriptContext<'phase, 'world> {
    pub(crate) phase_context: &'phase mut RuntimeScriptPhaseContext<'world>,
    pub entity: EntityID,
    pub delta_time: f64,
    pub parameters_json: String,
    default_parameters_json: String,
    definition: ScriptDefinition,
    cached_parameters: OnceCell<ScriptParameters>,
}

impl<'phase, 'world> ScriptContext<'phase, 'world> {
    pub fn new(
        phase_context: &'phase mut RuntimeScriptPhaseContext<'world>,
        entity: EntityID,
        delta_time: f64,
        parameters_json: impl Into<String>,
        default_parameters_json: impl Into<String>,
        definition: ScriptDefinition,
    ) -> Self {
        Self {
            phase_context,
            entity,
            delta_time,
            parameters_json: parameters_json.into(),
            default_parameters_json: default_parameters_json.into(),
            definition,
            cached_parameters: OnceCell::new(),
        }
    }

    pub fn parameters(&self) -> &ScriptParameters {
        self.cached_parameters.get_or_init(|| {
            self.definition
                .resolved_parameters(&self.default_parameters_json, &self.parameters_json)
        })
    }

    pub fn float_parameter(&self, name: &str) -> Option<f32> {
        self.double_parameter(name).map(|value| value as f32)
    }
    pub fn double_parameter(&self, name: &str) -> Option<f64> {
        self.parameters().get(name)?.nsnumber_double_value()
    }
    pub fn string_parameter(&self, name: &str) -> Option<&str> {
        self.parameters().get(name)?.as_str()
    }
    pub fn vector3_parameter(&self, name: &str) -> Option<Float3> {
        let lanes = match self.parameters().get(name)? {
            JsonValue::Array(values) if values.len() == 3 => [&values[0], &values[1], &values[2]],
            JsonValue::Object(values) => [values.get("x")?, values.get("y")?, values.get("z")?],
            _ => return None,
        };
        Some(Float3::new(
            lanes[0].nsnumber_double_value()? as f32,
            lanes[1].nsnumber_double_value()? as f32,
            lanes[2].nsnumber_double_value()? as f32,
        ))
    }
    pub fn entity_parameter(&self, name: &str) -> Option<EntityID> {
        let candidate =
            EntityID::from_raw_value(self.parameters().get(name)?.nsnumber_uint64_value()?);
        self.contains(candidate).then_some(candidate)
    }

    pub fn entities(&self) -> Vec<EntityID> {
        self.phase_context.entities()
    }
    pub fn entity_named(&mut self, name: &str) -> Option<EntityID> {
        if name.is_empty() {
            return None;
        }
        self.phase_context
            .entities_with::<SceneNameComponent>()
            .into_iter()
            .find(|entity| {
                self.phase_context
                    .component::<SceneNameComponent>(*entity)
                    .is_some_and(|component| component.value == name)
            })
    }
    pub fn is_alive(&self) -> bool {
        self.phase_context.contains(self.entity)
    }
    pub fn contains(&self, entity: EntityID) -> bool {
        self.phase_context.contains(entity)
    }
    pub fn create_entity(&mut self, name: Option<&str>, transform: LocalTransform) -> EntityID {
        self.phase_context.create_entity(name, transform)
    }
    pub fn instantiate(
        &mut self,
        prefab: &Prefab,
        parent: Option<EntityID>,
        transform: Option<LocalTransform>,
    ) -> Result<Option<EntityID>, PrefabError> {
        let mut registry = self.phase_context.component_registry().clone();
        registry.register_default_script_codec();
        self.phase_context.set_component_registry(registry);
        Ok(self
            .phase_context
            .instantiate(prefab, parent, transform)?
            .first()
            .copied())
    }

    pub fn component<C: RuntimeComponent>(&mut self) -> Option<C> {
        self.component_for(self.entity)
    }
    pub fn component_for<C: RuntimeComponent>(&mut self, entity: EntityID) -> Option<C> {
        self.phase_context.component::<C>(entity)
    }
    pub fn has_component<C: RuntimeComponent>(&mut self) -> bool {
        self.has_component_for::<C>(self.entity)
    }
    pub fn has_component_for<C: RuntimeComponent>(&mut self, entity: EntityID) -> bool {
        self.phase_context.has_component::<C>(entity)
    }
    pub fn set_component<C: RuntimeComponent>(&mut self, component: C) -> bool {
        self.set_component_for(component, self.entity)
    }
    pub fn set_component_for<C: RuntimeComponent>(
        &mut self,
        component: C,
        entity: EntityID,
    ) -> bool {
        self.phase_context.set_component(component, entity)
    }
    pub fn update_component<C: RuntimeComponent>(&mut self, body: impl FnOnce(&mut C)) -> bool {
        self.update_component_for(self.entity, body)
    }
    pub fn update_component_for<C: RuntimeComponent>(
        &mut self,
        entity: EntityID,
        body: impl FnOnce(&mut C),
    ) -> bool {
        self.phase_context.update_component::<C>(entity, body)
    }
    pub fn remove_component<C: RuntimeComponent>(&mut self) -> Option<C> {
        self.remove_component_from(self.entity)
    }
    pub fn remove_component_from<C: RuntimeComponent>(&mut self, entity: EntityID) -> Option<C> {
        self.phase_context.remove_component::<C>(entity)
    }

    pub fn local_transform(&self) -> Option<LocalTransform> {
        self.local_transform_of(self.entity)
    }
    pub fn local_transform_of(&self, entity: EntityID) -> Option<LocalTransform> {
        self.phase_context.local_transform(entity)
    }
    pub fn world_transform(&mut self) -> Option<WorldTransform> {
        self.world_transform_of(self.entity)
    }
    pub fn world_transform_of(&mut self, entity: EntityID) -> Option<WorldTransform> {
        self.phase_context.world_transform(entity)
    }
    pub fn set_local_transform(&mut self, transform: LocalTransform) -> bool {
        self.set_local_transform_for(transform, self.entity)
    }
    pub fn set_local_transform_for(&mut self, transform: LocalTransform, entity: EntityID) -> bool {
        self.phase_context.set_local_transform(transform, entity)
    }
    pub fn translate(&mut self, delta: Float3) -> bool {
        self.translate_for(delta, self.entity)
    }
    pub fn translate_for(&mut self, delta: Float3, entity: EntityID) -> bool {
        self.phase_context.translate(delta, entity)
    }
    pub fn parent(&self) -> Option<EntityID> {
        self.parent_of(self.entity)
    }
    pub fn parent_of(&self, entity: EntityID) -> Option<EntityID> {
        self.phase_context.parent(entity)
    }
    pub fn children(&self) -> Vec<EntityID> {
        self.children_of(self.entity)
    }
    pub fn children_of(&self, entity: EntityID) -> Vec<EntityID> {
        self.phase_context.children(entity)
    }
    pub fn set_parent(&mut self, parent: Option<EntityID>) -> bool {
        self.set_parent_for(parent, self.entity)
    }
    pub fn set_parent_for(&mut self, parent: Option<EntityID>, child: EntityID) -> bool {
        self.phase_context.set_parent(parent, child)
    }

    pub fn physics_raycast(
        &mut self,
        query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsRaycastHit> {
        self.phase_context.physics_raycast(query, filter)
    }
    pub fn raycast(
        &mut self,
        origin: Float3,
        direction: Float3,
        max_distance: f32,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsRaycastHit> {
        self.physics_raycast(
            PhysicsRaycastQuery::with_distance(origin, direction, max_distance),
            filter,
        )
    }
    pub fn physics_overlap_aabb(
        &mut self,
        query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        self.phase_context.physics_overlap_aabb(query, filter)
    }
    pub fn physics_overlap_shape(
        &mut self,
        query: PhysicsOverlapShapeQuery,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        self.phase_context.physics_overlap_shape(query, filter)
    }
    pub fn overlap(
        &mut self,
        bounds: SpatialAABB,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        self.physics_overlap_aabb(PhysicsOverlapAABBQuery::new(bounds), filter)
    }
    pub fn physics_sweep_aabb(
        &mut self,
        query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        self.phase_context.physics_sweep_aabb(query, filter)
    }
    pub fn physics_sweep_shape(
        &mut self,
        query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        self.phase_context.physics_sweep_shape(query, filter)
    }
    pub fn sweep(
        &mut self,
        bounds: SpatialAABB,
        translation: Float3,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        self.physics_sweep_aabb(PhysicsSweepAABBQuery::new(bounds, translation), filter)
    }
    pub fn submit_character_command(&mut self, command: CharacterCommand) {
        self.phase_context
            .submit_character_command(command, self.entity);
    }
    pub fn submit_vehicle_command(&mut self, command: VehicleCommand) {
        self.phase_context
            .submit_vehicle_command(command, self.entity);
    }
    pub fn character_state(&self) -> Option<CharacterState> {
        self.resource::<CharacterStateFrameResource>()?
            .states
            .get(&self.entity)
            .cloned()
    }

    pub fn resource<R: Send + Sync + Clone + 'static>(&self) -> Option<R> {
        self.phase_context.resource::<R>()
    }
    pub fn set_resource<R: Send + Sync + Clone + 'static>(&mut self, resource: R) {
        self.phase_context.set_resource(resource);
    }
    pub fn update_resource<R: Send + Sync + Clone + 'static>(
        &mut self,
        body: impl FnOnce(&mut R),
    ) -> bool {
        self.phase_context.update_resource::<R>(body)
    }
    pub fn remove_resource<R: Send + Sync + Clone + 'static>(&mut self) -> Option<R> {
        self.phase_context.remove_resource::<R>()
    }
    pub fn input(&self) -> InputFrameState {
        self.resource::<InputFrameState>().unwrap_or_default()
    }
    pub fn trigger_events(&self) -> TriggerFrameResource {
        self.resource::<TriggerFrameResource>().unwrap_or_default()
    }
    pub fn triggers_entered(&self) -> Vec<TriggerEvent> {
        self.trigger_events()
            .enters
            .into_iter()
            .filter(|event| event.trigger_entity == self.entity)
            .collect()
    }
    pub fn triggers_exited(&self) -> Vec<TriggerEvent> {
        self.trigger_events()
            .exits
            .into_iter()
            .filter(|event| event.trigger_entity == self.entity)
            .collect()
    }
    pub fn did_trigger_enter(&self, other: EntityID) -> bool {
        self.trigger_events()
            .enters
            .iter()
            .any(|event| event.trigger_entity == self.entity && event.other_entity == other)
    }
    pub fn did_trigger_exit(&self, other: EntityID) -> bool {
        self.trigger_events()
            .exits
            .iter()
            .any(|event| event.trigger_entity == self.entity && event.other_entity == other)
    }
    pub fn draw_ui(&mut self, body: impl FnOnce(&mut InGameCanvas)) {
        self.update_resource::<InGameCanvas>(body);
    }
    pub fn destroy_entity(&mut self, entity: EntityID) {
        self.phase_context.enqueue_destroy_entity(entity);
    }
    pub fn destroy_self(&mut self) {
        self.destroy_entity(self.entity);
    }
}
