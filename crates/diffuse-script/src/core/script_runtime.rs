use super::{
    script_behavior::{ScriptAuthoring, ScriptBehavior},
    script_component::{ScriptBinding, ScriptBindingID, ScriptComponent, ScriptHandle},
    script_context::ScriptContext,
    script_definition::{ScriptDefinition, ScriptParameters},
    script_lifecycle::{Script, ScriptCallback},
};
use crate::{
    controllers::animation_runtime::AnimationRuntime,
    input::input_state_processor::InputStateProcessor,
};
use diffuse_kernel::in_game_canvas::InGameCanvas;
use diffuse_scene::{
    entity_id::EntityID,
    physics::queries::physics_query_types::*,
    scene_runtime::SceneRuntime,
    scripting::{RuntimeScriptDriver, RuntimeScriptPhaseContext},
};
use std::{
    cmp::Ordering,
    collections::{BTreeMap, BTreeSet},
    sync::{
        Arc, Mutex, MutexGuard,
        atomic::{AtomicBool, Ordering as AtomicOrdering},
    },
};

#[derive(Clone)]
struct RegisteredScript {
    name: Option<String>,
    generation: u64,
    default_parameters_json: String,
    definition: ScriptDefinition,
    make_script: Arc<dyn Fn() -> Script + Send + Sync>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ScriptInstanceKey {
    entity: EntityID,
    binding: ScriptBindingID,
}
impl Ord for ScriptInstanceKey {
    fn cmp(&self, other: &Self) -> Ordering {
        self.entity
            .raw_value()
            .cmp(&other.entity.raw_value())
            .then_with(|| self.binding.cmp(&other.binding))
    }
}
impl PartialOrd for ScriptInstanceKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Clone)]
struct ActiveScriptInstance {
    registration_handle: ScriptHandle,
    registration_generation: u64,
    script: Script,
    parameters_json: String,
    default_parameters_json: String,
    definition: ScriptDefinition,
}

struct RuntimeState {
    next_handle_raw_value: u64,
    registered_scripts: BTreeMap<ScriptHandle, RegisteredScript>,
    handles_by_name: BTreeMap<String, ScriptHandle>,
    active_instances: BTreeMap<ScriptInstanceKey, ActiveScriptInstance>,
    input_processor: InputStateProcessor,
    animation_runtime: AnimationRuntime,
}

// Swift's runtime is shared by the editor and its scene driver. Callbacks run outside the state lock.
#[derive(Clone)]
pub struct ScriptRuntime {
    state: Arc<Mutex<RuntimeState>>,
    gameplay_execution_enabled: Arc<AtomicBool>,
}

impl Default for ScriptRuntime {
    fn default() -> Self {
        Self::new()
    }
}

impl ScriptRuntime {
    pub fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(RuntimeState {
                next_handle_raw_value: 1,
                registered_scripts: BTreeMap::new(),
                handles_by_name: BTreeMap::new(),
                active_instances: BTreeMap::new(),
                input_processor: InputStateProcessor::default(),
                animation_runtime: AnimationRuntime::new(),
            })),
            gameplay_execution_enabled: Arc::new(AtomicBool::new(true)),
        }
    }
    fn lock(&self) -> MutexGuard<'_, RuntimeState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }
    pub fn is_gameplay_execution_enabled(&self) -> bool {
        self.gameplay_execution_enabled.load(AtomicOrdering::SeqCst)
    }
    pub fn set_gameplay_execution_enabled(&self, enabled: bool) {
        self.gameplay_execution_enabled
            .store(enabled, AtomicOrdering::SeqCst);
    }
    pub fn tick(&self, delta_time: f64) {
        let _ = delta_time;
    }

    pub fn register(&self, script: Script, name: Option<&str>) -> ScriptHandle {
        self.register_factory(name, "{}", ScriptDefinition::default(), move || {
            script.clone()
        })
    }
    pub fn register_factory(
        &self,
        name: Option<&str>,
        default_parameters_json: &str,
        definition: ScriptDefinition,
        build: impl Fn() -> Script + Send + Sync + 'static,
    ) -> ScriptHandle {
        let default_parameters_json = definition.default_parameters_json(default_parameters_json);
        let name = name
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_owned);
        let mut state = self.lock();
        if let Some(handle) = name
            .as_ref()
            .and_then(|name| state.handles_by_name.get(name))
            .copied()
            && let Some(existing) = state.registered_scripts.get_mut(&handle)
        {
            existing.generation = existing.generation.wrapping_add(1);
            existing.default_parameters_json = default_parameters_json;
            existing.definition = definition;
            existing.make_script = Arc::new(build);
            return handle;
        }
        let handle = ScriptHandle::new(state.next_handle_raw_value);
        state.next_handle_raw_value += 1;
        state.registered_scripts.insert(
            handle,
            RegisteredScript {
                name: name.clone(),
                generation: 1,
                default_parameters_json,
                definition,
                make_script: Arc::new(build),
            },
        );
        if let Some(name) = name {
            state.handles_by_name.insert(name, handle);
        }
        handle
    }
    pub fn register_behavior<B: ScriptBehavior>(
        &self,
        name: Option<&str>,
        default_parameters_json: &str,
    ) -> ScriptHandle {
        self.register_factory(
            name,
            default_parameters_json,
            ScriptDefinition::default(),
            Script::from_behavior::<B>,
        )
    }
    /// Rust selects the independent authoring trait explicitly at the registration call site.
    pub fn register_authoring_behavior<B: ScriptBehavior + ScriptAuthoring>(
        &self,
        name: Option<&str>,
        default_parameters_json: &str,
    ) -> ScriptHandle {
        self.register_factory(
            name,
            default_parameters_json,
            B::definition(),
            Script::from_behavior::<B>,
        )
    }
    pub fn definition(&self, binding: &ScriptBinding) -> Option<ScriptDefinition> {
        self.resolve(binding)
            .map(|(_, registered)| registered.definition)
    }
    pub fn default_parameters(&self, binding: &ScriptBinding) -> ScriptParameters {
        self.resolve(binding)
            .map(|(_, registered)| {
                registered
                    .definition
                    .resolved_parameters(&registered.default_parameters_json, "{}")
            })
            .unwrap_or_default()
    }
    pub fn needs_reload(&self, binding: &ScriptBinding, entity: EntityID) -> bool {
        if !binding.is_enabled {
            return false;
        }
        let Some((handle, registered)) = self.resolve(binding) else {
            return false;
        };
        self.lock()
            .active_instances
            .get(&ScriptInstanceKey {
                entity,
                binding: binding.id.clone(),
            })
            .is_some_and(|instance| {
                instance.registration_handle != handle
                    || instance.registration_generation != registered.generation
            })
    }
    pub fn is_active(&self, binding: &ScriptBinding, entity: EntityID) -> bool {
        if !binding.is_enabled {
            return false;
        }
        let Some((handle, registered)) = self.resolve(binding) else {
            return false;
        };
        self.lock()
            .active_instances
            .get(&ScriptInstanceKey {
                entity,
                binding: binding.id.clone(),
            })
            .is_some_and(|instance| {
                instance.registration_handle == handle
                    && instance.registration_generation == registered.generation
            })
    }
    pub fn handle(&self, name: &str) -> Option<ScriptHandle> {
        self.lock().handles_by_name.get(name).copied()
    }
    pub fn identifier(&self, handle: ScriptHandle) -> Option<String> {
        self.lock().registered_scripts.get(&handle)?.name.clone()
    }
    pub fn registered_script_identifiers(&self) -> Vec<String> {
        self.lock().handles_by_name.keys().cloned().collect()
    }
    pub fn can_resolve(&self, binding: &ScriptBinding) -> bool {
        self.resolve(binding).is_some()
    }
    pub fn unregister(&self, handle: ScriptHandle) {
        let mut state = self.lock();
        if let Some(name) = state
            .registered_scripts
            .remove(&handle)
            .and_then(|registered| registered.name)
        {
            state.handles_by_name.remove(&name);
        }
        // Active instances retain their callbacks until post-physics supplies a valid destroy context.
    }
    pub fn unregister_named(&self, name: &str) {
        if let Some(handle) = self.handle(name) {
            self.unregister(handle);
        }
    }
    pub fn reset(&self) {
        let mut state = self.lock();
        state.active_instances.clear();
        state.input_processor.reset();
    }
    pub fn stop(&self, scene: &mut SceneRuntime) {
        scene.run_script_driver(
            &mut ScriptSessionStopDriver {
                runtime: self.clone(),
            },
            0.0,
        );
    }
    fn end_session(&self, context: &mut RuntimeScriptPhaseContext<'_>) {
        let instances = std::mem::take(&mut self.lock().active_instances);
        for (key, instance) in instances {
            let binding = context
                .component::<ScriptComponent>(key.entity)
                .and_then(|component| {
                    component
                        .bindings
                        .into_iter()
                        .find(|binding| binding.id == key.binding)
                });
            let parameters = binding
                .map(|binding| binding.parameters_json)
                .unwrap_or(instance.parameters_json);
            let mut script_context = ScriptContext::new(
                context,
                key.entity,
                0.0,
                parameters,
                instance.default_parameters_json,
                instance.definition,
            );
            invoke(&instance.script.on_destroy_handler, &mut script_context);
        }
        self.lock().input_processor.reset();
    }
    pub fn prepare_frame(&self, context: &mut RuntimeScriptPhaseContext<'_>) {
        context.set_resource(InGameCanvas::default());
        self.lock().input_processor.process(context);
    }
    pub fn run_pre_physics(&self, context: &mut RuntimeScriptPhaseContext<'_>) {
        if self.is_gameplay_execution_enabled() {
            self.execute_bound_scripts(context, ExecutionPhase::PrePhysics);
        }
    }
    pub fn run_post_physics(&self, context: &mut RuntimeScriptPhaseContext<'_>) {
        let delta_time = context.delta_time_seconds();
        self.lock().animation_runtime.tick(context, delta_time);
        if !self.is_gameplay_execution_enabled() {
            return;
        }
        let live = self.execute_bound_scripts(context, ExecutionPhase::PostPhysics);
        let removed: Vec<_> = self
            .lock()
            .active_instances
            .keys()
            .filter(|key| !live.contains(*key))
            .cloned()
            .collect();
        for key in removed {
            let instance = self.lock().active_instances.remove(&key);
            let Some(instance) = instance else {
                continue;
            };
            let mut script_context = ScriptContext::new(
                context,
                key.entity,
                delta_time,
                instance.parameters_json,
                instance.default_parameters_json,
                instance.definition,
            );
            invoke(&instance.script.on_destroy_handler, &mut script_context);
        }
    }
    fn execute_bound_scripts(
        &self,
        context: &mut RuntimeScriptPhaseContext<'_>,
        phase: ExecutionPhase,
    ) -> BTreeSet<ScriptInstanceKey> {
        let mut live = BTreeSet::new();
        let delta_time = context.delta_time_seconds();
        for entity in context.entities() {
            let Some(component) = context.component::<ScriptComponent>(entity) else {
                continue;
            };
            for binding in component
                .bindings
                .into_iter()
                .filter(|binding| binding.is_enabled)
            {
                let Some((handle, registered)) = self.resolve(&binding) else {
                    continue;
                };
                let key = ScriptInstanceKey {
                    entity,
                    binding: binding.id.clone(),
                };
                live.insert(key.clone());
                let mut instance = self.lock().active_instances.get(&key).cloned();
                if instance.as_ref().is_none_or(|instance| {
                    instance.registration_handle != handle
                        || instance.registration_generation != registered.generation
                }) {
                    if let Some(previous) = instance {
                        let mut destroy_context = ScriptContext::new(
                            context,
                            entity,
                            delta_time,
                            previous.parameters_json,
                            previous.default_parameters_json,
                            previous.definition,
                        );
                        invoke(&previous.script.on_destroy_handler, &mut destroy_context);
                    }
                    let replacement = ActiveScriptInstance {
                        registration_handle: handle,
                        registration_generation: registered.generation,
                        script: (registered.make_script)(),
                        parameters_json: binding.parameters_json.clone(),
                        default_parameters_json: registered.default_parameters_json.clone(),
                        definition: registered.definition.clone(),
                    };
                    let mut script_context = ScriptContext::new(
                        context,
                        entity,
                        delta_time,
                        binding.parameters_json.clone(),
                        registered.default_parameters_json.clone(),
                        registered.definition.clone(),
                    );
                    invoke(&replacement.script.on_start_handler, &mut script_context);
                    self.lock()
                        .active_instances
                        .insert(key.clone(), replacement.clone());
                    instance = Some(replacement);
                    if let Some(current) = self.lock().active_instances.get_mut(&key) {
                        current.parameters_json = binding.parameters_json.clone();
                    }
                    if let Some(instance) = instance {
                        invoke(phase.handler(&instance.script), &mut script_context);
                    }
                } else {
                    if let Some(current) = self.lock().active_instances.get_mut(&key) {
                        current.parameters_json = binding.parameters_json.clone();
                    }
                    let mut script_context = ScriptContext::new(
                        context,
                        entity,
                        delta_time,
                        binding.parameters_json,
                        registered.default_parameters_json,
                        registered.definition,
                    );
                    if let Some(instance) = instance {
                        invoke(phase.handler(&instance.script), &mut script_context);
                    }
                }
            }
        }
        live
    }
    fn resolve(&self, binding: &ScriptBinding) -> Option<(ScriptHandle, RegisteredScript)> {
        let state = self.lock();
        if let Some(identifier) = binding
            .identifier
            .as_deref()
            .map(str::trim)
            .filter(|identifier| !identifier.is_empty())
        {
            let handle = *state.handles_by_name.get(identifier)?;
            return Some((handle, state.registered_scripts.get(&handle)?.clone()));
        }
        Some((
            binding.script,
            state.registered_scripts.get(&binding.script)?.clone(),
        ))
    }

    pub fn physics_raycast(
        &self,
        runtime: &mut SceneRuntime,
        query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsRaycastHit> {
        runtime.physics_raycast(query, filter)
    }
    pub fn physics_overlap_aabb(
        &self,
        runtime: &mut SceneRuntime,
        query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        runtime.physics_overlap_aabb(query, filter)
    }
    pub fn physics_overlap_shape(
        &self,
        runtime: &mut SceneRuntime,
        query: PhysicsOverlapShapeQuery,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        runtime.physics_overlap_shape(query, filter)
    }
    pub fn physics_sweep_aabb(
        &self,
        runtime: &mut SceneRuntime,
        query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        runtime.physics_sweep_aabb(query, filter)
    }
    pub fn physics_sweep_shape(
        &self,
        runtime: &mut SceneRuntime,
        query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        runtime.physics_sweep_shape(query, filter)
    }
}

#[derive(Clone, Copy)]
enum ExecutionPhase {
    PrePhysics,
    PostPhysics,
}
impl ExecutionPhase {
    fn handler(self, script: &Script) -> &Option<ScriptCallback> {
        match self {
            Self::PrePhysics => &script.on_pre_physics_handler,
            Self::PostPhysics => &script.on_tick_handler,
        }
    }
}
/// Swift's `invoke(_:script:context:)`: publishes the callback's context for the
/// duration of the call so the C bridge and `current_script_context()` observe
/// it, then restores whatever was current before.
fn invoke(handler: &Option<ScriptCallback>, context: &mut ScriptContext<'_, '_>) {
    if let Some(handler) = handler {
        crate::dynamic_script::script_c_bridge_context::with_script_context(context, |context| {
            handler(context)
        });
    }
}

impl RuntimeScriptDriver for ScriptRuntime {
    fn run(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        self.prepare_frame(context);
        self.run_pre_physics(context);
        self.run_post_physics(context);
    }
    fn prepare_frame(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        ScriptRuntime::prepare_frame(self, context);
    }
    fn run_pre_physics(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        ScriptRuntime::run_pre_physics(self, context);
    }
    fn run_post_physics(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        ScriptRuntime::run_post_physics(self, context);
    }
    fn reset(&mut self) {
        ScriptRuntime::reset(self);
    }
}
struct ScriptSessionStopDriver {
    runtime: ScriptRuntime,
}
impl RuntimeScriptDriver for ScriptSessionStopDriver {
    fn run(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        self.runtime.end_session(context);
    }
    fn reset(&mut self) {
        let _ = self;
    }
}
