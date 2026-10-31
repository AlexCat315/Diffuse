//! `RuntimeScriptDriver` and the per-phase script context.
//!
//! Swift's `RuntimeScriptPhaseContext` held `UnsafeMutablePointer<RuntimeWorld>` and
//! `UnsafeMutablePointer<RuntimeCommandBuffer>` because a script callback must mutate
//! the world *and* enqueue deferred commands while the schedule still owns both.
//! Rust expresses that with a single `&mut` borrow of a small pair, so no raw pointer
//! or `unsafe` is needed — the callback gets exclusive access for its duration and the
//! schedule regains it afterwards.
//!
//! World-space readers flush pending transform writes first, matching Swift's
//! `refreshTransformsIfNeeded()`.

use crate::entity_id::{EntityID, RuntimeComponent};
use crate::physics::backend::physics_backend::PhysicsBackend;
use crate::physics::backend::physics_query_scene::PhysicsQueryScene;
use crate::physics::character_controller::{CharacterCommand, CharacterCommandFrameResource};
use crate::physics::destruction::{DestructionCommand, DestructionCommandFrameResource};
use crate::physics::vehicles::vehicle_state::{VehicleCommand, VehicleCommandFrameResource};
use crate::runtime_world::{LocalTransform, RuntimeWorld, WorldTransform};
use crate::scene_bootstrap::SceneNameComponent;
use crate::scene_graph::prefab::{Prefab, PrefabError};
use crate::scheduling::schedule_commands::RuntimeCommandBuffer;

/// The script lifecycle the schedule drives.
///
/// Swift's protocol extension supplied empty `prepareFrame`/`runPrePhysics` and a
/// `runPostPhysics` that forwarded to `run`; the default methods below do the same.
pub trait RuntimeScriptDriver: Send {
    fn run(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        let _ = context;
    }

    fn prepare_frame(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        let _ = context;
    }

    fn run_pre_physics(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        let _ = context;
    }

    /// Swift's default forwarded to `run`.
    fn run_post_physics(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        self.run(context);
    }

    fn reset(&mut self) {}
}

/// The context a script callback receives for one phase.
pub struct RuntimeScriptPhaseContext<'a> {
    world: &'a mut RuntimeWorld,
    commands: &'a mut RuntimeCommandBuffer,
    delta_time_seconds: f64,
}

impl<'a> RuntimeScriptPhaseContext<'a> {
    /// Built by the schedule; the borrows are exclusive for the callback.
    pub fn new(
        world: &'a mut RuntimeWorld,
        commands: &'a mut RuntimeCommandBuffer,
        delta_time_seconds: f64,
    ) -> Self {
        RuntimeScriptPhaseContext {
            world,
            commands,
            delta_time_seconds,
        }
    }

    /// The registry, so a script can enumerate component schemas.
    #[inline]
    pub fn component_registry(&self) -> &crate::components::core::registry::ComponentRegistry {
        &self.world.component_registry
    }

    #[inline]
    pub fn delta_time_seconds(&self) -> f64 {
        self.delta_time_seconds
    }

    pub fn entities(&self) -> Vec<EntityID> {
        self.world.entities()
    }

    pub fn entities_with<C: RuntimeComponent>(&self) -> Vec<EntityID> {
        self.world.entities_with::<C>()
    }

    #[inline]
    pub fn contains(&self, entity: EntityID) -> bool {
        self.world.contains(entity)
    }

    /// Creates an entity immediately so the callback can configure it. Script
    /// iteration uses a snapshot, so newly attached behaviours start on a later pass.
    pub fn create_entity(&mut self, name: Option<&str>, transform: LocalTransform) -> EntityID {
        let entity = self.world.create_entity();
        self.world.set_local_transform(transform, entity);
        if let Some(name) = name {
            self.world
                .set_component(SceneNameComponent::new(name), entity);
        }
        entity
    }

    /// Returns entities in prefab document order, including the root at index zero.
    pub fn instantiate(
        &mut self,
        prefab: &Prefab,
        parent: Option<EntityID>,
        transform: Option<LocalTransform>,
    ) -> Result<Vec<EntityID>, PrefabError> {
        let entities = prefab.instantiate_entities(self.world, parent, transform)?;
        self.refresh_transforms_if_needed();
        Ok(entities)
    }

    #[inline]
    pub fn component<C: RuntimeComponent>(&self, entity: EntityID) -> Option<C> {
        self.world.component::<C>(entity)
    }

    #[inline]
    pub fn has_component<C: RuntimeComponent>(&self, entity: EntityID) -> bool {
        self.world.has_component::<C>(entity)
    }

    #[inline]
    pub fn set_component<C: RuntimeComponent>(&mut self, component: C, entity: EntityID) -> bool {
        self.world.set_component(component, entity)
    }

    pub fn update_component<C: RuntimeComponent>(
        &mut self,
        entity: EntityID,
        body: impl FnOnce(&mut C),
    ) -> bool {
        self.world.update_component::<C>(entity, body)
    }

    pub fn remove_component<C: RuntimeComponent>(&mut self, entity: EntityID) -> Option<C> {
        self.world.remove_component::<C>(entity)
    }

    #[inline]
    pub fn local_transform(&self, entity: EntityID) -> Option<LocalTransform> {
        self.world.local_transform(entity)
    }

    /// World-space read: flushes pending local writes first.
    pub fn world_transform(&mut self, entity: EntityID) -> Option<WorldTransform> {
        self.refresh_transforms_if_needed();
        self.world.world_transform(entity)
    }

    #[inline]
    pub fn set_local_transform(&mut self, transform: LocalTransform, entity: EntityID) -> bool {
        // World-space readers flush pending writes; the schedule also flushes at
        // phase boundaries so several local edits share one propagation.
        self.world.set_local_transform(transform, entity)
    }

    /// Moves an entity by `delta` in its parent's space.
    pub fn translate(
        &mut self,
        delta: diffuse_math::simd::simd_compat::Float3,
        entity: EntityID,
    ) -> bool {
        let Some(mut transform) = self.world.local_transform(entity) else {
            return false;
        };
        transform.matrix.columns[3].x += delta.x;
        transform.matrix.columns[3].y += delta.y;
        transform.matrix.columns[3].z += delta.z;
        self.world.set_local_transform(transform, entity)
    }

    #[inline]
    pub fn parent(&self, entity: EntityID) -> Option<EntityID> {
        self.world.parent(entity)
    }

    #[inline]
    pub fn children(&self, entity: EntityID) -> Vec<EntityID> {
        self.world.children(entity)
    }

    pub fn set_parent(&mut self, parent: Option<EntityID>, child: EntityID) -> bool {
        let updated = self.world.set_parent(parent, child);
        self.refresh_transforms_if_needed();
        updated
    }

    // MARK: - Deferred commands

    pub fn enqueue_destroy_entity(&mut self, entity: EntityID) {
        self.commands.destroy_entity(entity);
    }

    pub fn enqueue_set_parent(&mut self, parent: Option<EntityID>, child: EntityID) {
        self.commands.set_parent(parent, child);
    }

    pub fn enqueue_set_local_transform(&mut self, transform: LocalTransform, entity: EntityID) {
        self.commands.set_local_transform(transform, entity);
    }

    // MARK: - Physics queries

    /// The query backend, synchronised to the world's physics revision.
    pub fn physics_query_backend<'b>(
        &mut self,
        query_scene: &'b mut PhysicsQueryScene,
    ) -> &'b mut dyn PhysicsBackend {
        self.refresh_transforms_if_needed();
        query_scene.backend(self.world)
    }

    // MARK: - Frame resources

    /// Records a character command into the entity's command frame.
    pub fn submit_character_command(&mut self, command: CharacterCommand, entity: EntityID) {
        let mut frame = self
            .world
            .resource::<CharacterCommandFrameResource>()
            .unwrap_or_default();
        frame.commands.insert(entity, command);
        self.world.set_resource(frame);
    }

    /// Records a vehicle command into the entity's command frame.
    pub fn submit_vehicle_command(&mut self, command: VehicleCommand, entity: EntityID) {
        let mut frame = self
            .world
            .resource::<VehicleCommandFrameResource>()
            .unwrap_or_default();
        frame.commands.insert(entity, command);
        self.world.set_resource(frame);
    }

    /// Appends a destruction command for this frame.
    pub fn submit_destruction_command(&mut self, command: DestructionCommand) {
        let mut frame = self
            .world
            .resource::<DestructionCommandFrameResource>()
            .unwrap_or_default();
        frame.commands.push(command);
        self.world.set_resource(frame);
    }

    #[inline]
    pub fn resource<R: Send + Sync + Clone + 'static>(&self) -> Option<R> {
        self.world.resource::<R>()
    }

    #[inline]
    pub fn set_resource<R: Send + Sync + Clone + 'static>(&mut self, resource: R) {
        self.world.set_resource(resource);
    }

    pub fn update_resource<R: Send + Sync + Clone + 'static>(
        &mut self,
        body: impl FnOnce(&mut R),
    ) -> bool {
        self.world.update_resource::<R>(body)
    }

    pub fn remove_resource<R: Send + Sync + Clone + 'static>(&mut self) -> Option<R> {
        self.world.remove_resource::<R>()
    }

    /// Public access to the flush, for callers that read world space outside a getter.
    pub fn propagate_transforms_if_needed(&mut self) {
        self.refresh_transforms_if_needed();
    }

    fn refresh_transforms_if_needed(&mut self) {
        if self.world.hierarchy_needs_propagation() {
            self.world.propagate_transforms_default();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;

    fn empty_world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    /// Records which phase callbacks ran, so the trait defaults are observable.
    #[derive(Default)]
    struct RecordingDriver {
        calls: Vec<&'static str>,
    }

    impl RuntimeScriptDriver for RecordingDriver {
        fn run(&mut self, _context: &mut RuntimeScriptPhaseContext<'_>) {
            self.calls.push("run");
        }

        fn prepare_frame(&mut self, _context: &mut RuntimeScriptPhaseContext<'_>) {
            self.calls.push("prepareFrame");
        }

        fn reset(&mut self) {
            self.calls.push("reset");
        }
    }

    #[test]
    fn the_driver_defaults_match_swift() {
        let mut driver = RecordingDriver::default();
        let mut world = empty_world();
        let mut commands = RuntimeCommandBuffer::new();
        let mut context = RuntimeScriptPhaseContext::new(&mut world, &mut commands, 0.016);

        driver.prepare_frame(&mut context);
        driver.run_pre_physics(&mut context);
        // Swift's default `runPostPhysics` forwards to `run`.
        driver.run_post_physics(&mut context);
        driver.reset();

        assert_eq!(driver.calls, vec!["prepareFrame", "run", "reset"]);
    }

    #[test]
    fn create_entity_sets_the_name_and_transform() {
        let mut world = empty_world();
        let mut commands = RuntimeCommandBuffer::new();
        let mut context = RuntimeScriptPhaseContext::new(&mut world, &mut commands, 0.0);

        let entity = context.create_entity(Some("hero"), LocalTransform::IDENTITY);
        assert!(context.contains(entity));
        assert_eq!(
            context
                .component::<SceneNameComponent>(entity)
                .map(|name| name.value.clone()),
            Some("hero".to_string())
        );
        assert!(context.local_transform(entity).is_some());
    }

    #[test]
    fn creating_without_a_name_leaves_it_unset() {
        let mut world = empty_world();
        let mut commands = RuntimeCommandBuffer::new();
        let mut context = RuntimeScriptPhaseContext::new(&mut world, &mut commands, 0.0);

        let entity = context.create_entity(None, LocalTransform::IDENTITY);
        assert!(context.component::<SceneNameComponent>(entity).is_none());
    }

    #[test]
    fn deferred_commands_do_not_touch_the_world_until_applied() {
        let mut world = empty_world();
        let entity = world.create_entity();
        let mut commands = RuntimeCommandBuffer::new();
        let mut context = RuntimeScriptPhaseContext::new(&mut world, &mut commands, 0.0);

        context.enqueue_destroy_entity(entity);
        // The entity still exists: destruction is deferred to the command phase.
        assert!(context.contains(entity));
    }

    #[test]
    fn translate_moves_the_local_translation() {
        use diffuse_math::simd::simd_compat::Float3;

        let mut world = empty_world();
        let entity = world.create_entity();
        world.set_local_transform(LocalTransform::IDENTITY, entity);
        let mut commands = RuntimeCommandBuffer::new();
        let mut context = RuntimeScriptPhaseContext::new(&mut world, &mut commands, 0.0);

        assert!(context.translate(Float3::new(1.0, 2.0, 3.0), entity));
        let transform = context.local_transform(entity).expect("transform");
        assert_eq!(transform.matrix.columns[3].x, 1.0);
        assert_eq!(transform.matrix.columns[3].y, 2.0);
        assert_eq!(transform.matrix.columns[3].z, 3.0);
    }

    #[test]
    fn translate_reports_false_for_an_unknown_entity() {
        use diffuse_math::simd::simd_compat::Float3;

        let mut world = empty_world();
        let mut commands = RuntimeCommandBuffer::new();
        let mut context = RuntimeScriptPhaseContext::new(&mut world, &mut commands, 0.0);
        // `create_entity` always attaches a transform, so a *fresh* world entity lacks
        // one only when it was never created through the world at all.
        let absent = EntityID::new(77, 0);
        assert!(!context.translate(Float3::new(1.0, 0.0, 0.0), absent));
    }

    #[test]
    fn delta_time_is_reported_unchanged() {
        let mut world = empty_world();
        let mut commands = RuntimeCommandBuffer::new();
        let context = RuntimeScriptPhaseContext::new(&mut world, &mut commands, 0.016);
        assert_eq!(context.delta_time_seconds(), 0.016);
    }
}
