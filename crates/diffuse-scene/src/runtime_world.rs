//! Scene world storage.
//!
//! This module is being translated in stages because `RuntimeWorld.swift` is one
//! strongly-connected component with the physics subsystem. Everything below is
//! the *closed prefix*: the transform, hierarchy and query vocabulary that does not
//! reference `RuntimeWorld` and which `diffuse-audio`, `diffuse-intent`,
//! `diffuse-assets` and `diffuse-render` consume. `RuntimeWorld` itself lands with
//! the physics backend closure.

use std::any::Any;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use diffuse_kernel::job_system::{JobDispatchReport, JobSystem};
use diffuse_math::simd::simd_compat::{
    Float3, Float3x3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, Quatf, simd_cross, simd_inverse,
    simd_length,
};

use crate::components::core::registry::{
    ComponentDependencyError, ComponentRegistry, ComponentSchema, ComponentTypeKey,
};
use crate::components::core::value::ComponentValue;
use crate::components::editing::ComponentEditError;
use crate::entity_id::{EntityID, RuntimeComponent};
use crate::physics::backend::physics_backend_context::PhysicsBodyWriteback;
use crate::physics::character_controller::CharacterController;
use crate::physics::collider::Collider;
use crate::physics::joints::physics_joint::Constraint;
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::queries::spatial_queries::{
    MeshColliderBoundsResource, MeshColliderGeometryResource,
};
use crate::physics::ragdoll::Ragdoll;
use crate::physics::rigid_body::{RigidBody, RigidBodyMotionType};
use crate::physics::soft_bodies::cloth::Cloth;
use crate::physics::soft_bodies::soft_body::SoftBody;
use crate::physics::vehicles::vehicle::Vehicle;

/// `RuntimeWorldSummary`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RuntimeWorldSummary {
    pub entity_count: usize,
    pub component_store_count: usize,
    pub resource_count: usize,
    pub revision: u64,
}

impl RuntimeWorldSummary {
    pub fn new(
        entity_count: usize,
        component_store_count: usize,
        resource_count: usize,
        revision: u64,
    ) -> Self {
        RuntimeWorldSummary {
            entity_count,
            component_store_count,
            resource_count,
            revision,
        }
    }
}

/// `LocalTransform` — the stored scene transform, held as a single matrix.
///
/// This is deliberately *not* `diffuse_math`'s `Transform3D`: that type is a
/// translation/rotation/scale triple for computation, whereas this is the ECS
/// component. Physics write-back and prefabs need one matrix, so decomposition is
/// derived on demand.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LocalTransform {
    pub matrix: Float4x4,
}

impl LocalTransform {
    /// `static let identity = LocalTransform()`.
    pub const IDENTITY: LocalTransform = LocalTransform {
        matrix: MATRIX_IDENTITY_FLOAT4X4,
    };

    /// `init(matrix:)`.
    pub fn new(matrix: Float4x4) -> Self {
        LocalTransform { matrix }
    }

    /// Projection of the Swift default-argument quaternion:
    /// `simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))`.
    fn default_rotation() -> Quatf {
        Quatf::from_angle_axis(0.0, Float3::new(0.0, 1.0, 0.0))
    }

    /// `init(translation:rotation:scale:)`.
    pub fn from_translation_rotation_scale(
        translation: Float3,
        rotation: Quatf,
        scale: Float3,
    ) -> Self {
        let mut matrix = Float4x4::from_quatf(rotation)
            * Float4x4::diagonal(Float4::new(scale.x, scale.y, scale.z, 1.0));
        // The translation is written last, so it is unaffected by rotation/scale.
        matrix.set_column(
            3,
            Float4::new(translation.x, translation.y, translation.z, 1.0),
        );
        LocalTransform { matrix }
    }

    /// `init(translation:)` — zero rotation about +Y, unit scale.
    pub fn from_translation(translation: Float3) -> Self {
        LocalTransform::from_translation_rotation_scale(
            translation,
            LocalTransform::default_rotation(),
            Float3::ONE,
        )
    }

    /// `init(rotation:scale:)` — translation defaults to zero.
    pub fn from_rotation_scale(rotation: Quatf, scale: Float3) -> Self {
        LocalTransform::from_translation_rotation_scale(Float3::ZERO, rotation, scale)
    }

    /// `var translation` — reads and writes column 3.
    pub fn translation(&self) -> Float3 {
        let column = self.matrix.columns[3];
        Float3::new(column.x, column.y, column.z)
    }

    pub fn set_translation(&mut self, translation: Float3) {
        self.matrix.set_column(
            3,
            Float4::new(translation.x, translation.y, translation.z, 1.0),
        );
    }

    /// `var rotation` — normalizes the basis columns, then decodes the rotation.
    ///
    /// A column whose length is not greater than `1e-6` is used unnormalized,
    /// matching Swift's `sx > 1e-6 ? sx : 1` divisor selection.
    pub fn rotation(&self) -> Quatf {
        let column0 = self.matrix.columns[0];
        let column1 = self.matrix.columns[1];
        let column2 = self.matrix.columns[2];
        let c0 = Float3::new(column0.x, column0.y, column0.z);
        let c1 = Float3::new(column1.x, column1.y, column1.z);
        let c2 = Float3::new(column2.x, column2.y, column2.z);
        let sx = simd_length(c0);
        let sy = simd_length(c1);
        let sz = simd_length(c2);
        let normalized = Float3x3::from_columns([
            c0 / (if sx > 1e-6 { sx } else { 1.0 }),
            c1 / (if sy > 1e-6 { sy } else { 1.0 }),
            c2 / (if sz > 1e-6 { sz } else { 1.0 }),
        ]);
        Quatf::from_float3x3(normalized)
    }

    /// `func withTranslation(_:)`.
    pub fn with_translation(&self, translation: Float3) -> LocalTransform {
        let mut matrix = self.matrix;
        matrix.set_column(
            3,
            Float4::new(translation.x, translation.y, translation.z, 1.0),
        );
        LocalTransform { matrix }
    }

    /// `func withRotation(_:)` — replaces the basis, preserving translation.
    pub fn with_rotation(&self, rotation: Quatf) -> LocalTransform {
        let mut matrix = self.matrix;
        let translation = self.translation();
        let r = Float4x4::from_quatf(rotation);
        matrix.set_column(0, r.columns[0]);
        matrix.set_column(1, r.columns[1]);
        matrix.set_column(2, r.columns[2]);
        matrix.set_column(
            3,
            Float4::new(translation.x, translation.y, translation.z, 1.0),
        );
        LocalTransform { matrix }
    }
}

impl Default for LocalTransform {
    fn default() -> Self {
        LocalTransform::IDENTITY
    }
}

impl RuntimeComponent for LocalTransform {}

/// `WorldTransform` — the resolved world matrix.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WorldTransform {
    pub matrix: Float4x4,
}

impl WorldTransform {
    /// `static let identity = WorldTransform()`.
    pub const IDENTITY: WorldTransform = WorldTransform {
        matrix: MATRIX_IDENTITY_FLOAT4X4,
    };

    pub fn new(matrix: Float4x4) -> Self {
        WorldTransform { matrix }
    }

    /// `var translation` — read-only, unlike `LocalTransform`.
    pub fn translation(&self) -> Float3 {
        let column = self.matrix.columns[3];
        Float3::new(column.x, column.y, column.z)
    }
}

impl Default for WorldTransform {
    fn default() -> Self {
        WorldTransform::IDENTITY
    }
}

impl RuntimeComponent for WorldTransform {}

/// `Parent` — one outgoing hierarchy edge.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Parent {
    pub entity: EntityID,
}

impl Parent {
    pub fn new(entity: EntityID) -> Self {
        Parent { entity }
    }
}

impl RuntimeComponent for Parent {}

/// `Children` — the ordered child list.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Children {
    pub entities: Vec<EntityID>,
}

impl Children {
    pub fn new(entities: Vec<EntityID>) -> Self {
        Children { entities }
    }
}

impl RuntimeComponent for Children {}

/// `RuntimeComponentQuery<Component>`.
#[derive(Clone, Debug, PartialEq)]
pub struct RuntimeComponentQuery<Component: RuntimeComponent> {
    pub entity: EntityID,
    pub component: Component,
}

impl<Component: RuntimeComponent> RuntimeComponentQuery<Component> {
    pub fn new(entity: EntityID, component: Component) -> Self {
        RuntimeComponentQuery { entity, component }
    }
}

/// `RuntimeComponentPairQuery<A, B>`.
#[derive(Clone, Debug, PartialEq)]
pub struct RuntimeComponentPairQuery<A: RuntimeComponent, B: RuntimeComponent> {
    pub entity: EntityID,
    pub a: A,
    pub b: B,
}

impl<A: RuntimeComponent, B: RuntimeComponent> RuntimeComponentPairQuery<A, B> {
    pub fn new(entity: EntityID, a: A, b: B) -> Self {
        RuntimeComponentPairQuery { entity, a, b }
    }
}

/// `RuntimeComponentTripleQuery<A, B, C>`.
#[derive(Clone, Debug, PartialEq)]
pub struct RuntimeComponentTripleQuery<
    A: RuntimeComponent,
    B: RuntimeComponent,
    C: RuntimeComponent,
> {
    pub entity: EntityID,
    pub a: A,
    pub b: B,
    pub c: C,
}

impl<A: RuntimeComponent, B: RuntimeComponent, C: RuntimeComponent>
    RuntimeComponentTripleQuery<A, B, C>
{
    pub fn new(entity: EntityID, a: A, b: B, c: C) -> Self {
        RuntimeComponentTripleQuery { entity, a, b, c }
    }
}

// MARK: - RuntimeWorld

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct EntitySlot {
    generation: u32,
    is_alive: bool,
}

/// Object-safe view over a stored component.
///
/// Swift's stores were `AnyObject` boxes with `isKnownUniquelyReferenced` COW. Rust
/// cannot clone a `dyn Any`, so this trait adds an explicit `clone_box`, letting a
/// cloned `RuntimeWorld` deep-copy its stores exactly as Swift's COW produced for a
/// caller that then mutated one side.
trait AnyComponent: Send + Sync {
    fn as_any(&self) -> &dyn Any;
    fn clone_box(&self) -> Box<dyn AnyComponent>;
}

impl<C: RuntimeComponent> AnyComponent for C {
    fn as_any(&self) -> &dyn Any {
        self
    }

    fn clone_box(&self) -> Box<dyn AnyComponent> {
        Box::new(self.clone())
    }
}

impl Clone for Box<dyn AnyComponent> {
    fn clone(&self) -> Self {
        self.clone_box()
    }
}

#[derive(Clone, Default)]
struct ComponentStores {
    values: BTreeMap<ComponentTypeKey, BTreeMap<EntityID, Box<dyn AnyComponent>>>,
}

impl std::fmt::Debug for ComponentStores {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ComponentStores")
            .field("count", &self.values.len())
            .finish()
    }
}

impl ComponentStores {
    fn count(&self) -> usize {
        self.values.len()
    }

    fn set<C: RuntimeComponent>(&mut self, component: C, for_entity: EntityID) {
        self.values
            .entry(ComponentTypeKey::of::<C>())
            .or_default()
            .insert(for_entity, Box::new(component));
    }

    fn get<C: RuntimeComponent>(&self, entity: EntityID) -> Option<C> {
        self.values
            .get(&ComponentTypeKey::of::<C>())?
            .get(&entity)?
            .as_any()
            .downcast_ref::<C>()
            .cloned()
    }

    fn entities<C: RuntimeComponent>(&self) -> Vec<EntityID> {
        self.values
            .get(&ComponentTypeKey::of::<C>())
            .map(|store| store.keys().copied().collect())
            .unwrap_or_default()
    }

    fn snapshot<C: RuntimeComponent>(&self) -> BTreeMap<EntityID, C> {
        self.values
            .get(&ComponentTypeKey::of::<C>())
            .map(|store| {
                store
                    .iter()
                    .filter_map(|(entity, value)| {
                        value
                            .as_any()
                            .downcast_ref::<C>()
                            .map(|c| (*entity, c.clone()))
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    fn count_of<C: RuntimeComponent>(&self) -> usize {
        self.values
            .get(&ComponentTypeKey::of::<C>())
            .map_or(0, BTreeMap::len)
    }

    fn remove<C: RuntimeComponent>(&mut self, entity: EntityID) -> Option<C> {
        let key = ComponentTypeKey::of::<C>();
        let store = self.values.get_mut(&key)?;
        let boxed = store.remove(&entity)?;
        let value = boxed.as_any().downcast_ref::<C>()?.clone();
        if store.is_empty() {
            self.values.remove(&key);
        }
        Some(value)
    }

    /// Applies `body` to a copy and writes it back only when the entity has the
    /// component. Returns whether an update happened.
    fn update<C: RuntimeComponent>(&mut self, entity: EntityID, body: impl FnOnce(&mut C)) -> bool {
        let Some(mut component) = self.get::<C>(entity) else {
            return false;
        };
        body(&mut component);
        self.set(component, entity);
        true
    }

    fn remove_all(&mut self, entity: EntityID) {
        for store in self.values.values_mut() {
            store.remove(&entity);
        }
        self.values.retain(|_, store| !store.is_empty());
    }
}

/// Type-erased resource store.
///
/// Swift replaced the box on every `set` so a copied world never observed the
/// mutation. `Arc` reproduces that: `clone` shares, `set` installs a new `Arc`.
#[derive(Clone, Default)]
struct ResourceStorage {
    values: BTreeMap<ComponentTypeKey, Arc<dyn Any + Send + Sync>>,
}

impl std::fmt::Debug for ResourceStorage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ResourceStorage")
            .field("count", &self.values.len())
            .finish()
    }
}

impl ResourceStorage {
    fn count(&self) -> usize {
        self.values.len()
    }

    fn set<R: Clone + Send + Sync + 'static>(&mut self, resource: R) {
        self.values
            .insert(ComponentTypeKey::of_type::<R>(), Arc::new(resource));
    }

    fn get<R: Clone + Send + Sync + 'static>(&self) -> Option<R> {
        self.values
            .get(&ComponentTypeKey::of_type::<R>())?
            .downcast_ref::<R>()
            .cloned()
    }

    /// Swift copied the resource value, mutated the copy, then replaced the box.
    fn update<R: Clone + Send + Sync + 'static>(&mut self, body: impl FnOnce(&mut R)) -> bool {
        let key = ComponentTypeKey::of_type::<R>();
        let Some(existing) = self.values.get(&key) else {
            return false;
        };
        let Some(mut value) = existing.downcast_ref::<R>().cloned() else {
            return false;
        };
        body(&mut value);
        self.values.insert(key, Arc::new(value));
        true
    }

    fn remove<R: Clone + Send + Sync + 'static>(&mut self) -> Option<R> {
        let arc = self.values.remove(&ComponentTypeKey::of_type::<R>())?;
        arc.downcast_ref::<R>().cloned()
    }
}

/// A resource marker for the hierarchy propagation read set.
#[derive(Clone, Debug, Default, PartialEq)]
struct HierarchyReadSnapshot {
    entities: Vec<EntityID>,
    local_matrices: BTreeMap<EntityID, Float4x4>,
    parent_by_entity: BTreeMap<EntityID, EntityID>,
    children_by_entity: BTreeMap<EntityID, Vec<EntityID>>,
}

/// The scene's entity/component/resource store.
#[derive(Clone, Debug)]
pub struct RuntimeWorld {
    slots: Vec<EntitySlot>,
    free_indices: Vec<usize>,
    components: ComponentStores,
    /// Components registered from data instead of a Rust type keep their authored
    /// document here: there is no type to key a typed store by.
    document_components: BTreeMap<String, BTreeMap<EntityID, ComponentValue>>,
    resources: ResourceStorage,
    root_entities: Vec<EntityID>,
    dirty_hierarchy_entities: BTreeSet<EntityID>,
    entity_count: usize,
    revision: u64,
    physics_revision: u64,
    pub component_registry: ComponentRegistry,
}

impl Default for RuntimeWorld {
    fn default() -> Self {
        RuntimeWorld::new(ComponentRegistry::new())
    }
}

impl RuntimeWorld {
    pub fn new(component_registry: ComponentRegistry) -> Self {
        RuntimeWorld {
            slots: Vec::new(),
            free_indices: Vec::new(),
            components: ComponentStores::default(),
            document_components: BTreeMap::new(),
            resources: ResourceStorage::default(),
            root_entities: Vec::new(),
            dirty_hierarchy_entities: BTreeSet::new(),
            entity_count: 0,
            revision: 0,
            physics_revision: 0,
            component_registry,
        }
    }

    pub fn entity_count(&self) -> usize {
        self.entity_count
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Swift's `internal(set) var physicsRevision`.
    pub fn physics_revision(&self) -> u64 {
        self.physics_revision
    }

    pub fn summary(&self) -> RuntimeWorldSummary {
        RuntimeWorldSummary::new(
            self.entity_count,
            self.components.count(),
            self.resources.count(),
            self.revision,
        )
    }

    pub fn entities(&self) -> Vec<EntityID> {
        let mut result = Vec::with_capacity(self.entity_count);
        for (index, slot) in self.slots.iter().enumerate() {
            if slot.is_alive {
                result.push(EntityID::new(index as u32, slot.generation));
            }
        }
        result
    }

    pub fn roots(&self) -> Vec<EntityID> {
        self.normalized_roots()
    }

    pub fn create_entity(&mut self) -> EntityID {
        let id = if let Some(reused_index) = self.free_indices.pop() {
            self.slots[reused_index].is_alive = true;
            let slot = &self.slots[reused_index];
            EntityID::new(reused_index as u32, slot.generation)
        } else {
            let index = self.slots.len();
            self.slots.push(EntitySlot {
                generation: 0,
                is_alive: true,
            });
            EntityID::new(index as u32, 0)
        };
        self.entity_count += 1;
        self.root_entities.push(id);
        self.revision = self.revision.wrapping_add(1);
        self.physics_revision = self.physics_revision.wrapping_add(1);
        id
    }

    /// Destroys an entity, promoting its children to roots in place.
    pub fn destroy_entity(&mut self, entity: EntityID) -> bool {
        if !self.contains(entity) {
            return false;
        }

        let previous_parent = self.parent(entity);
        let previous_children = self.children(entity);
        let previous_root_index = self.root_entities.iter().position(|entry| *entry == entity);
        match previous_parent {
            Some(parent) => {
                self.detach_child(entity, parent);
                self.mark_hierarchy_dirty(parent);
            }
            None => self.detach_root(entity),
        }
        let mut root_insert_index = previous_root_index;
        for child in previous_children {
            self.clear_parent(child);
            match root_insert_index {
                Some(insert_index) => {
                    self.attach_root_at(child, insert_index as i64);
                    root_insert_index = Some(insert_index + 1);
                }
                None => self.attach_root(child),
            }
            self.mark_hierarchy_dirty(child);
        }

        let index = entity.index as usize;
        self.slots[index].is_alive = false;
        self.slots[index].generation = self.slots[index].generation.wrapping_add(1);
        self.free_indices.push(index);
        self.entity_count -= 1;
        self.components.remove_all(entity);
        self.remove_document_components(entity);
        self.dirty_hierarchy_entities.remove(&entity);
        self.revision = self.revision.wrapping_add(1);
        self.physics_revision = self.physics_revision.wrapping_add(1);
        true
    }

    // MARK: Document components

    pub fn document_component(&self, type_id: &str, entity: EntityID) -> Option<&ComponentValue> {
        if !self.contains(entity) {
            return None;
        }
        self.document_components.get(type_id)?.get(&entity)
    }

    pub fn has_document_component(&self, type_id: &str, entity: EntityID) -> bool {
        self.document_component(type_id, entity).is_some()
    }

    pub fn set_document_component(
        &mut self,
        type_id: &str,
        value: ComponentValue,
        entity: EntityID,
    ) -> bool {
        if !self.contains(entity) {
            return false;
        }
        self.document_components
            .entry(type_id.to_string())
            .or_default()
            .insert(entity, value);
        self.revision = self.revision.wrapping_add(1);
        true
    }

    pub fn remove_document_component(
        &mut self,
        type_id: &str,
        entity: EntityID,
    ) -> Option<ComponentValue> {
        if !self.contains(entity) {
            return None;
        }
        let store = self.document_components.get_mut(type_id)?;
        let removed = store.remove(&entity)?;
        if store.is_empty() {
            self.document_components.remove(type_id);
        }
        self.revision = self.revision.wrapping_add(1);
        Some(removed)
    }

    fn remove_document_components(&mut self, entity: EntityID) {
        let mut empty: Vec<String> = Vec::new();
        for (type_id, store) in self.document_components.iter_mut() {
            store.remove(&entity);
            if store.is_empty() {
                empty.push(type_id.clone());
            }
        }
        for type_id in empty {
            self.document_components.remove(&type_id);
        }
    }

    pub fn contains(&self, entity: EntityID) -> bool {
        let index = entity.index as usize;
        let Some(slot) = self.slots.get(index) else {
            return false;
        };
        slot.is_alive && slot.generation == entity.generation
    }

    // MARK: Components

    pub fn set_component<C: RuntimeComponent>(&mut self, component: C, entity: EntityID) -> bool {
        if !self.contains(entity) {
            return false;
        }
        let requirements = match self.component_registry.required_schemas_for::<C>() {
            Ok(requirements) => requirements,
            Err(_) => return false,
        };
        if requirements
            .iter()
            .any(|schema| !(schema.has)(self, entity))
        {
            // Work on a copy so a dependency failure leaves no partial state.
            let mut edited = self.clone();
            if edited
                .ensure_required_components(&requirements, entity)
                .is_err()
            {
                return false;
            }
            edited.store_component(component, entity);
            *self = edited;
        } else {
            self.store_component(component, entity);
        }
        true
    }

    fn store_component<C: RuntimeComponent>(&mut self, component: C, entity: EntityID) {
        self.components.set(component, entity);
        if ComponentTypeKey::of::<C>() == ComponentTypeKey::of::<LocalTransform>() {
            self.mark_hierarchy_dirty(entity);
        }
        self.revision = self.revision.wrapping_add(1);
        if component_affects_physics::<C>() {
            self.physics_revision = self.physics_revision.wrapping_add(1);
        }
    }

    pub fn component<C: RuntimeComponent>(&self, entity: EntityID) -> Option<C> {
        if !self.contains(entity) {
            return None;
        }
        self.components.get::<C>(entity)
    }

    pub fn has_component<C: RuntimeComponent>(&self, entity: EntityID) -> bool {
        self.component::<C>(entity).is_some()
    }

    pub fn component_count<C: RuntimeComponent>(&self) -> usize {
        self.components.count_of::<C>()
    }

    /// Entities carrying `C`, sorted by raw value.
    pub fn entities_with<C: RuntimeComponent>(&self) -> Vec<EntityID> {
        let mut entities = self.components.entities::<C>();
        entities.sort_by_key(|entity| entity.raw_value());
        entities
    }

    pub fn component_snapshot<C: RuntimeComponent>(&self) -> BTreeMap<EntityID, C> {
        self.components.snapshot::<C>()
    }

    pub fn component_snapshot_matching<C: RuntimeComponent>(
        &self,
        entities: &[EntityID],
    ) -> BTreeMap<EntityID, C> {
        let stored = self.components.snapshot::<C>();
        if stored.is_empty() || entities.is_empty() {
            return BTreeMap::new();
        }
        let mut snapshot = BTreeMap::new();
        for entity in entities {
            if !self.contains(*entity) {
                continue;
            }
            if let Some(component) = stored.get(entity) {
                snapshot.insert(*entity, component.clone());
            }
        }
        snapshot
    }

    pub fn query<C: RuntimeComponent>(&self) -> Vec<RuntimeComponentQuery<C>> {
        let snapshot = self.components.snapshot::<C>();
        self.entities_with::<C>()
            .into_iter()
            .filter_map(|entity| {
                snapshot
                    .get(&entity)
                    .map(|component| RuntimeComponentQuery::new(entity, component.clone()))
            })
            .collect()
    }

    pub fn query_pair<A: RuntimeComponent, B: RuntimeComponent>(
        &self,
    ) -> Vec<RuntimeComponentPairQuery<A, B>> {
        let snapshot_a = self.components.snapshot::<A>();
        let snapshot_b = self.components.snapshot::<B>();
        let mut candidates: Vec<EntityID> = if snapshot_a.len() <= snapshot_b.len() {
            snapshot_a.keys().copied().collect()
        } else {
            snapshot_b.keys().copied().collect()
        };
        candidates.sort_by_key(|entity| entity.raw_value());
        candidates
            .into_iter()
            .filter_map(|entity| {
                Some(RuntimeComponentPairQuery::new(
                    entity,
                    snapshot_a.get(&entity)?.clone(),
                    snapshot_b.get(&entity)?.clone(),
                ))
            })
            .collect()
    }

    pub fn query_triple<A: RuntimeComponent, B: RuntimeComponent, C: RuntimeComponent>(
        &self,
    ) -> Vec<RuntimeComponentTripleQuery<A, B, C>> {
        let snapshot_a = self.components.snapshot::<A>();
        let snapshot_b = self.components.snapshot::<B>();
        let snapshot_c = self.components.snapshot::<C>();
        let mut candidates: Vec<EntityID> =
            if snapshot_a.len() <= snapshot_b.len() && snapshot_a.len() <= snapshot_c.len() {
                snapshot_a.keys().copied().collect()
            } else if snapshot_b.len() <= snapshot_c.len() {
                snapshot_b.keys().copied().collect()
            } else {
                snapshot_c.keys().copied().collect()
            };
        candidates.sort_by_key(|entity| entity.raw_value());
        candidates
            .into_iter()
            .filter_map(|entity| {
                Some(RuntimeComponentTripleQuery::new(
                    entity,
                    snapshot_a.get(&entity)?.clone(),
                    snapshot_b.get(&entity)?.clone(),
                    snapshot_c.get(&entity)?.clone(),
                ))
            })
            .collect()
    }

    pub fn update_component<C: RuntimeComponent>(
        &mut self,
        entity: EntityID,
        body: impl FnOnce(&mut C),
    ) -> bool {
        if !self.contains(entity) {
            return false;
        }
        let updated = self.components.update::<C>(entity, body);
        if updated {
            self.revision = self.revision.wrapping_add(1);
            if component_affects_physics::<C>() {
                self.physics_revision = self.physics_revision.wrapping_add(1);
            }
        }
        updated
    }

    pub fn update_components<C: RuntimeComponent>(
        &mut self,
        mut body: impl FnMut(EntityID, &mut C),
    ) -> usize {
        let matched = self.entities_with::<C>();
        let mut updated_count = 0;
        for entity in matched {
            if self
                .components
                .update::<C>(entity, |component| body(entity, component))
            {
                updated_count += 1;
            }
        }
        if updated_count > 0 {
            self.revision = self.revision.wrapping_add(1);
            if component_affects_physics::<C>() {
                self.physics_revision = self.physics_revision.wrapping_add(1);
            }
        }
        updated_count
    }

    pub fn remove_component<C: RuntimeComponent>(&mut self, entity: EntityID) -> Option<C> {
        if !self.contains(entity) {
            return None;
        }
        let removed = self.components.remove::<C>(entity);
        if removed.is_some() {
            self.revision = self.revision.wrapping_add(1);
            if component_affects_physics::<C>() {
                self.physics_revision = self.physics_revision.wrapping_add(1);
            }
        }
        removed
    }

    // MARK: Resources

    pub fn set_resource<R: Clone + Send + Sync + 'static>(&mut self, resource: R) {
        self.resources.set(resource);
        self.revision = self.revision.wrapping_add(1);
        if resource_affects_physics::<R>() {
            self.physics_revision = self.physics_revision.wrapping_add(1);
        }
    }

    pub fn resource<R: Clone + Send + Sync + 'static>(&self) -> Option<R> {
        self.resources.get::<R>()
    }

    pub fn update_resource<R: Clone + Send + Sync + 'static>(
        &mut self,
        body: impl FnOnce(&mut R),
    ) -> bool {
        let updated = self.resources.update::<R>(body);
        if updated {
            self.revision = self.revision.wrapping_add(1);
            if resource_affects_physics::<R>() {
                self.physics_revision = self.physics_revision.wrapping_add(1);
            }
        }
        updated
    }

    pub fn remove_resource<R: Clone + Send + Sync + 'static>(&mut self) -> Option<R> {
        let removed = self.resources.remove::<R>();
        if removed.is_some() {
            self.revision = self.revision.wrapping_add(1);
            if resource_affects_physics::<R>() {
                self.physics_revision = self.physics_revision.wrapping_add(1);
            }
        }
        removed
    }

    pub fn advance_revision(&mut self) {
        self.revision = self.revision.wrapping_add(1);
    }

    /// Stores a derived component without bumping the revision — used by the
    /// schedule for values that are outputs, not authoring edits.
    pub fn set_derived_component<C: RuntimeComponent>(&mut self, component: C, entity: EntityID) {
        if !self.contains(entity) {
            return;
        }
        self.components.set(component, entity);
    }

    pub fn set_derived_resource<R: Clone + Send + Sync + 'static>(&mut self, resource: R) {
        self.resources.set(resource);
    }

    // MARK: Transforms

    pub fn set_local_transform(&mut self, transform: LocalTransform, entity: EntityID) -> bool {
        self.set_component(transform, entity)
    }

    /// A live entity without an explicit transform reads as identity.
    pub fn local_transform(&self, entity: EntityID) -> Option<LocalTransform> {
        if !self.contains(entity) {
            return None;
        }
        Some(
            self.components
                .get::<LocalTransform>(entity)
                .unwrap_or(LocalTransform::IDENTITY),
        )
    }

    pub fn local_transform_snapshot(&self) -> BTreeMap<EntityID, LocalTransform> {
        let stored = self.components.snapshot::<LocalTransform>();
        if stored.len() == self.entity_count {
            stored
        } else {
            self.local_transform_snapshot_matching(&self.entities())
        }
    }

    pub fn local_transform_snapshot_matching(
        &self,
        entities: &[EntityID],
    ) -> BTreeMap<EntityID, LocalTransform> {
        let explicit = self.components.snapshot::<LocalTransform>();
        let mut snapshot = BTreeMap::new();
        for entity in entities {
            if !self.contains(*entity) {
                continue;
            }
            snapshot.insert(
                *entity,
                explicit
                    .get(entity)
                    .copied()
                    .unwrap_or(LocalTransform::IDENTITY),
            );
        }
        snapshot
    }

    pub fn world_transform(&self, entity: EntityID) -> Option<WorldTransform> {
        if !self.contains(entity) {
            return None;
        }
        Some(
            self.components
                .get::<WorldTransform>(entity)
                .unwrap_or(WorldTransform::IDENTITY),
        )
    }

    pub fn world_transform_snapshot(&self) -> BTreeMap<EntityID, WorldTransform> {
        let stored = self.components.snapshot::<WorldTransform>();
        if stored.len() == self.entity_count {
            stored
        } else {
            self.world_transform_snapshot_matching(&self.entities())
        }
    }

    pub fn world_transform_snapshot_matching(
        &self,
        entities: &[EntityID],
    ) -> BTreeMap<EntityID, WorldTransform> {
        let explicit = self.components.snapshot::<WorldTransform>();
        let mut snapshot = BTreeMap::new();
        for entity in entities {
            if !self.contains(*entity) {
                continue;
            }
            snapshot.insert(
                *entity,
                explicit
                    .get(entity)
                    .copied()
                    .unwrap_or(WorldTransform::IDENTITY),
            );
        }
        snapshot
    }

    // MARK: Hierarchy

    pub fn parent(&self, entity: EntityID) -> Option<EntityID> {
        if !self.contains(entity) {
            return None;
        }
        self.components
            .get::<Parent>(entity)
            .map(|parent| parent.entity)
    }

    pub fn children(&self, entity: EntityID) -> Vec<EntityID> {
        if !self.contains(entity) {
            return Vec::new();
        }
        self.components
            .get::<Children>(entity)
            .map(|children| {
                children
                    .entities
                    .into_iter()
                    .filter(|child| self.contains(*child))
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn set_parent(&mut self, parent: Option<EntityID>, child: EntityID) -> bool {
        if !self.contains(child) {
            return false;
        }
        if let Some(parent) = parent
            && (!self.contains(parent) || parent == child || self.is_descendant(parent, child))
        {
            return false;
        }

        let previous_parent = self.parent(child);
        if previous_parent == parent {
            return true;
        }

        match previous_parent {
            Some(previous) => {
                self.detach_child(child, previous);
                self.mark_hierarchy_dirty(previous);
            }
            None => {
                // Child was a root; detach it so it does not appear twice.
                self.detach_root(child);
            }
        }

        match parent {
            Some(parent) => {
                self.attach_child(child, parent);
                self.components.set(Parent::new(parent), child);
                self.mark_hierarchy_dirty(parent);
            }
            None => {
                self.clear_parent(child);
                self.attach_root(child);
            }
        }

        self.mark_hierarchy_dirty(child);
        self.revision = self.revision.wrapping_add(1);
        self.physics_revision = self.physics_revision.wrapping_add(1);
        true
    }

    pub fn move_entity(&mut self, entity: EntityID, parent: Option<EntityID>, index: i64) -> bool {
        if !self.contains(entity) {
            return false;
        }
        if let Some(parent) = parent
            && (!self.contains(parent) || parent == entity || self.is_descendant(parent, entity))
        {
            return false;
        }

        let previous_parent = self.parent(entity);
        if previous_parent == parent {
            return match parent {
                Some(parent) => self.reorder_child(entity, parent, index),
                None => self.reorder_root(entity, index),
            };
        }

        match previous_parent {
            Some(previous) => {
                self.detach_child(entity, previous);
                self.mark_hierarchy_dirty(previous);
            }
            None => self.detach_root(entity),
        }

        match parent {
            Some(parent) => {
                self.insert_child(entity, parent, index);
                self.components.set(Parent::new(parent), entity);
                self.mark_hierarchy_dirty(parent);
            }
            None => {
                self.clear_parent(entity);
                self.attach_root_at(entity, index);
            }
        }

        self.mark_hierarchy_dirty(entity);
        self.revision = self.revision.wrapping_add(1);
        self.physics_revision = self.physics_revision.wrapping_add(1);
        true
    }

    pub fn hierarchy_needs_propagation(&self) -> bool {
        !self.dirty_hierarchy_entities.is_empty()
    }

    /// Recomputes world transforms for dirty hierarchy subtrees.
    ///
    /// Swift parallelizes the per-frontier matrix products with the job system. The
    /// Rust port keeps the same breadth-first frontier algorithm and the same
    /// `(parent_world * local)` arithmetic order; the parallel dispatch is applied to
    /// the frontier map so floating-point results are identical (each matrix product
    /// is independent, so chunking cannot reorder any single product).
    pub fn propagate_transforms(&mut self, job_system: &JobSystem) -> JobDispatchReport {
        if !self.hierarchy_needs_propagation() {
            return JobDispatchReport::new(0, job_system.worker_count, false);
        }

        let parent_count = self.components.count_of::<Parent>();
        let children_count = self.components.count_of::<Children>();
        if parent_count == 0 && children_count == 0 {
            // Independent roots have no graph to traverse.
            let entities = self.entities();
            let local_transforms = self.components.snapshot::<LocalTransform>();
            let (computed, report) = job_system.parallel_map(&entities, Some(1), |entity| {
                MATRIX_IDENTITY_FLOAT4X4
                    * local_transforms
                        .get(entity)
                        .map_or(MATRIX_IDENTITY_FLOAT4X4, |transform| transform.matrix)
            });
            for (index, entity) in entities.iter().enumerate() {
                let transform = WorldTransform::new(computed[index]);
                if self.components.get::<WorldTransform>(*entity) != Some(transform) {
                    self.components.set(transform, *entity);
                }
            }
            self.dirty_hierarchy_entities.clear();
            self.revision = self.revision.wrapping_add(1);
            self.physics_revision = self.physics_revision.wrapping_add(1);
            return report;
        }

        let snapshot = self.hierarchy_read_snapshot(job_system);
        let mut world_matrices: BTreeMap<EntityID, Float4x4> = BTreeMap::new();
        let mut visited: BTreeSet<EntityID> = BTreeSet::new();

        let mut roots: Vec<EntityID> = Vec::with_capacity(snapshot.entities.len());
        for entity in &snapshot.entities {
            match snapshot.parent_by_entity.get(entity) {
                Some(parent) if snapshot.entities.contains(parent) => {}
                _ => roots.push(*entity),
            }
        }

        let mut frontier = roots;
        while !frontier.is_empty() {
            let current_frontier = frontier.clone();
            let parent_world_matrices = world_matrices.clone();
            let (computed, _report) =
                job_system.parallel_map(&current_frontier, Some(1), |entity| {
                    let local_matrix = snapshot
                        .local_matrices
                        .get(entity)
                        .copied()
                        .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
                    let parent_matrix = snapshot
                        .parent_by_entity
                        .get(entity)
                        .and_then(|parent| parent_world_matrices.get(parent))
                        .copied()
                        .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
                    parent_matrix * local_matrix
                });

            let mut next_frontier: Vec<EntityID> = Vec::new();
            for (index, entity) in current_frontier.iter().enumerate() {
                let world_matrix = computed[index];
                world_matrices.insert(*entity, world_matrix);
                self.components
                    .set(WorldTransform::new(world_matrix), *entity);
                visited.insert(*entity);
                if let Some(children) = snapshot.children_by_entity.get(entity) {
                    for child in children {
                        if !visited.contains(child) {
                            next_frontier.push(*child);
                        }
                    }
                }
            }
            frontier = next_frontier;
        }

        for entity in &snapshot.entities {
            if !visited.contains(entity) {
                self.propagate_from(
                    *entity,
                    MATRIX_IDENTITY_FLOAT4X4,
                    &mut visited,
                    &snapshot.local_matrices,
                    &snapshot.children_by_entity,
                );
            }
        }

        self.dirty_hierarchy_entities.clear();
        self.revision = self.revision.wrapping_add(1);
        self.physics_revision = self.physics_revision.wrapping_add(1);
        JobDispatchReport::new(0, job_system.worker_count, false)
    }

    /// Convenience wrapper using an owned job system, matching Swift's
    /// `propagateTransforms()` default argument of `.shared`.
    pub fn propagate_transforms_default(&mut self) -> JobDispatchReport {
        self.propagate_transforms(&JobSystem::with_available_parallelism())
    }

    fn propagate_from(
        &mut self,
        entity: EntityID,
        parent_world_matrix: Float4x4,
        visited: &mut BTreeSet<EntityID>,
        local_matrices: &BTreeMap<EntityID, Float4x4>,
        children_by_entity: &BTreeMap<EntityID, Vec<EntityID>>,
    ) {
        if !self.contains(entity) || visited.contains(&entity) {
            return;
        }
        visited.insert(entity);
        let local_matrix = local_matrices
            .get(&entity)
            .copied()
            .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
        let world_matrix = parent_world_matrix * local_matrix;
        self.components
            .set(WorldTransform::new(world_matrix), entity);
        if let Some(children) = children_by_entity.get(&entity) {
            for child in children.clone() {
                self.propagate_from(
                    child,
                    world_matrix,
                    visited,
                    local_matrices,
                    children_by_entity,
                );
            }
        }
    }

    fn hierarchy_read_snapshot(&self, job_system: &JobSystem) -> HierarchyReadSnapshot {
        let entities = self.entities();
        let entity_set: BTreeSet<EntityID> = entities.iter().copied().collect();
        let local_transforms = self.components.snapshot::<LocalTransform>();
        let parents = self.components.snapshot::<Parent>();
        let children = self.components.snapshot::<Children>();

        let (local_pairs, _) = job_system.parallel_map(&entities, None, |entity| {
            (
                *entity,
                local_transforms
                    .get(entity)
                    .map_or(MATRIX_IDENTITY_FLOAT4X4, |transform| transform.matrix),
            )
        });
        let (parent_pairs, _) = job_system.parallel_compact_map(&entities, None, |entity| {
            parents
                .get(entity)
                .map(|parent| parent.entity)
                .filter(|parent| entity_set.contains(parent))
                .map(|parent| (*entity, parent))
        });
        let (children_pairs, _) = job_system.parallel_compact_map(&entities, None, |entity| {
            let live: Vec<EntityID> = children
                .get(entity)
                .map(|children| {
                    children
                        .entities
                        .iter()
                        .copied()
                        .filter(|child| entity_set.contains(child))
                        .collect()
                })
                .unwrap_or_default();
            if live.is_empty() {
                None
            } else {
                Some((*entity, live))
            }
        });

        HierarchyReadSnapshot {
            entities,
            local_matrices: local_pairs.into_iter().collect(),
            parent_by_entity: parent_pairs.into_iter().collect(),
            children_by_entity: children_pairs.into_iter().collect(),
        }
    }

    fn attach_child(&mut self, child: EntityID, parent: EntityID) {
        let mut current = self
            .components
            .get::<Children>(parent)
            .map(|children| children.entities)
            .unwrap_or_default();
        if !current.contains(&child) {
            current.push(child);
            self.components.set(Children::new(current), parent);
        }
    }

    fn insert_child(&mut self, child: EntityID, parent: EntityID, index: i64) {
        let mut current: Vec<EntityID> = self
            .components
            .get::<Children>(parent)
            .map(|children| {
                children
                    .entities
                    .into_iter()
                    .filter(|entry| self.contains(*entry))
                    .collect()
            })
            .unwrap_or_default();
        current.retain(|entry| *entry != child);
        let insert_index = clamp_index(index, current.len() as i64) as usize;
        current.insert(insert_index, child);
        self.components.set(Children::new(current), parent);
    }

    fn detach_child(&mut self, child: EntityID, parent: EntityID) {
        let mut current = self
            .components
            .get::<Children>(parent)
            .map(|children| children.entities)
            .unwrap_or_default();
        current.retain(|entry| *entry != child && self.contains(*entry));
        if current.is_empty() {
            let _ = self.components.remove::<Children>(parent);
        } else {
            self.components.set(Children::new(current), parent);
        }
    }

    fn clear_parent(&mut self, child: EntityID) {
        let _ = self.components.remove::<Parent>(child);
    }

    fn reorder_child(&mut self, child: EntityID, parent: EntityID, index: i64) -> bool {
        let mut current: Vec<EntityID> = self
            .components
            .get::<Children>(parent)
            .map(|children| {
                children
                    .entities
                    .into_iter()
                    .filter(|entry| self.contains(*entry))
                    .collect()
            })
            .unwrap_or_default();
        let Some(existing_index) = current.iter().position(|entry| *entry == child) else {
            return false;
        };
        let clamped_index = clamp_index(index, current.len() as i64 - 1) as usize;
        let mut destination_index = clamped_index;
        if existing_index < clamped_index {
            destination_index -= 1;
        }
        if existing_index == destination_index {
            return true;
        }
        current.remove(existing_index);
        let insert_at = destination_index.min(current.len());
        current.insert(insert_at, child);
        self.components.set(Children::new(current), parent);
        self.mark_hierarchy_dirty(parent);
        self.mark_hierarchy_dirty(child);
        self.revision = self.revision.wrapping_add(1);
        self.physics_revision = self.physics_revision.wrapping_add(1);
        true
    }

    fn reorder_root(&mut self, entity: EntityID, index: i64) -> bool {
        let mut current_roots = self.normalized_roots();
        let Some(existing_index) = current_roots.iter().position(|entry| *entry == entity) else {
            return false;
        };
        let clamped_index = clamp_index(index, current_roots.len() as i64 - 1) as usize;
        let mut destination_index = clamped_index;
        if existing_index < clamped_index {
            destination_index -= 1;
        }
        if existing_index == destination_index {
            return true;
        }
        current_roots.remove(existing_index);
        let insert_at = destination_index.min(current_roots.len());
        current_roots.insert(insert_at, entity);
        self.root_entities = current_roots;
        self.mark_hierarchy_dirty(entity);
        self.revision = self.revision.wrapping_add(1);
        self.physics_revision = self.physics_revision.wrapping_add(1);
        true
    }

    fn attach_root(&mut self, entity: EntityID) {
        let mut current_roots = self.normalized_roots();
        current_roots.retain(|entry| *entry != entity);
        current_roots.push(entity);
        self.root_entities = current_roots;
    }

    fn attach_root_at(&mut self, entity: EntityID, index: i64) {
        let mut current_roots = self.normalized_roots();
        current_roots.retain(|entry| *entry != entity);
        let insert_index = clamp_index(index, current_roots.len() as i64) as usize;
        current_roots.insert(insert_index, entity);
        self.root_entities = current_roots;
    }

    fn detach_root(&mut self, entity: EntityID) {
        let current_roots: Vec<EntityID> = self
            .normalized_roots()
            .into_iter()
            .filter(|entry| *entry != entity)
            .collect();
        self.root_entities = current_roots;
    }

    fn normalized_roots(&self) -> Vec<EntityID> {
        let mut seen: BTreeSet<EntityID> = BTreeSet::new();
        let mut normalized = Vec::with_capacity(self.root_entities.len());
        for entity in &self.root_entities {
            if !self.contains(*entity) {
                continue;
            }
            if self.parent(*entity).is_some() {
                continue;
            }
            if !seen.insert(*entity) {
                continue;
            }
            normalized.push(*entity);
        }
        normalized
    }

    fn mark_hierarchy_dirty(&mut self, entity: EntityID) {
        if !self.contains(entity) {
            return;
        }
        self.dirty_hierarchy_entities.insert(entity);
    }

    fn is_descendant(&self, entity: EntityID, ancestor: EntityID) -> bool {
        let mut current = self.parent(entity);
        while let Some(current_entity) = current {
            if current_entity == ancestor {
                return true;
            }
            current = self.parent(current_entity);
        }
        false
    }

    // MARK: Physics helpers

    pub fn apply_force(&mut self, force: Float3, entity: EntityID, wake: bool) -> bool {
        self.update_dynamic_rigid_body(entity, wake, |body| {
            body.accumulated_force += force;
        })
    }

    pub fn apply_force_at(
        &mut self,
        force: Float3,
        world_point: Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        let Some(center) = self.world_transform(entity).map(|t| t.translation()) else {
            return false;
        };
        self.update_dynamic_rigid_body(entity, wake, |body| {
            body.accumulated_force += force;
            body.accumulated_torque += simd_cross(world_point - center, force);
        })
    }

    pub fn apply_torque(&mut self, torque: Float3, entity: EntityID, wake: bool) -> bool {
        self.update_dynamic_rigid_body(entity, wake, |body| {
            body.accumulated_torque += torque;
        })
    }

    pub fn apply_linear_impulse(&mut self, impulse: Float3, entity: EntityID, wake: bool) -> bool {
        self.update_dynamic_rigid_body(entity, wake, |body| {
            body.accumulated_linear_impulse += impulse;
        })
    }

    pub fn apply_linear_impulse_at(
        &mut self,
        impulse: Float3,
        world_point: Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        let Some(center) = self.world_transform(entity).map(|t| t.translation()) else {
            return false;
        };
        self.update_dynamic_rigid_body(entity, wake, |body| {
            body.accumulated_linear_impulse += impulse;
            body.accumulated_angular_impulse += simd_cross(world_point - center, impulse);
        })
    }

    pub fn apply_angular_impulse(&mut self, impulse: Float3, entity: EntityID, wake: bool) -> bool {
        self.update_dynamic_rigid_body(entity, wake, |body| {
            body.accumulated_angular_impulse += impulse;
        })
    }

    pub fn wake_rigid_body(&mut self, entity: EntityID) -> bool {
        self.update_component::<RigidBody>(entity, |body| {
            body.is_sleeping = false;
        })
    }

    pub fn sleep_rigid_body(&mut self, entity: EntityID) -> bool {
        self.update_component::<RigidBody>(entity, |body| {
            body.linear_velocity = Float3::ZERO;
            body.angular_velocity = Float3::ZERO;
            body.accumulated_force = Float3::ZERO;
            body.accumulated_torque = Float3::ZERO;
            body.accumulated_linear_impulse = Float3::ZERO;
            body.accumulated_angular_impulse = Float3::ZERO;
            body.is_sleeping = true;
        })
    }

    pub fn clear_forces(&mut self, entity: EntityID) -> bool {
        self.update_component::<RigidBody>(entity, |body| {
            body.accumulated_force = Float3::ZERO;
            body.accumulated_torque = Float3::ZERO;
        })
    }

    pub fn clear_physics_accumulators(&mut self, entities: &[EntityID]) -> usize {
        let mut cleared_count = 0;
        for entity in entities {
            let Some(body) = self.component::<RigidBody>(*entity) else {
                continue;
            };
            if body.accumulated_force == Float3::ZERO
                && body.accumulated_torque == Float3::ZERO
                && body.accumulated_linear_impulse == Float3::ZERO
                && body.accumulated_angular_impulse == Float3::ZERO
            {
                continue;
            }
            let cleared = self.update_component::<RigidBody>(*entity, |body| {
                body.accumulated_force = Float3::ZERO;
                body.accumulated_torque = Float3::ZERO;
                body.accumulated_linear_impulse = Float3::ZERO;
                body.accumulated_angular_impulse = Float3::ZERO;
            });
            if cleared {
                cleared_count += 1;
            }
        }
        cleared_count
    }

    pub fn apply_physics_writeback(&mut self, writeback: &PhysicsBodyWriteback) -> bool {
        if !self.contains(writeback.entity) {
            return false;
        }

        if let Some(world_transform) = writeback.world_transform {
            let local_matrix = match self.parent(writeback.entity) {
                Some(parent) => match self.world_transform(parent) {
                    Some(parent_world) => {
                        simd_inverse(parent_world.matrix) * world_transform.matrix
                    }
                    None => world_transform.matrix,
                },
                None => world_transform.matrix,
            };
            self.components
                .set(LocalTransform::new(local_matrix), writeback.entity);
            self.components.set(world_transform, writeback.entity);
            self.mark_hierarchy_dirty(writeback.entity);
        }

        if let Some(mut body) = self.component::<RigidBody>(writeback.entity) {
            if let Some(linear_velocity) = writeback.linear_velocity {
                body.linear_velocity = linear_velocity;
            }
            if let Some(angular_velocity) = writeback.angular_velocity {
                body.angular_velocity = angular_velocity;
            }
            if let Some(is_sleeping) = writeback.is_sleeping {
                body.is_sleeping = is_sleeping;
            }
            self.components.set(body, writeback.entity);
        }

        true
    }

    fn update_dynamic_rigid_body(
        &mut self,
        entity: EntityID,
        wake: bool,
        body: impl FnOnce(&mut RigidBody),
    ) -> bool {
        if self
            .component::<RigidBody>(entity)
            .map(|rigid| rigid.motion_type)
            != Some(RigidBodyMotionType::Dynamic)
        {
            return false;
        }
        self.update_component::<RigidBody>(entity, |rigid_body| {
            body(rigid_body);
            if wake {
                rigid_body.is_sleeping = false;
            }
        })
    }

    /// Ensures dependencies exist, refusing incompatible combinations.
    pub fn ensure_required_components(
        &mut self,
        requirements: &[ComponentSchema],
        entity: EntityID,
    ) -> Result<(), ComponentEditError> {
        let required_ids: BTreeSet<&str> = requirements
            .iter()
            .map(|schema| schema.type_id.as_str())
            .collect();
        for schema in requirements {
            for other in &schema.incompatible_with {
                let present = required_ids.contains(other.as_str())
                    || self
                        .component_registry
                        .get(other)
                        .map(|schema| (schema.has)(self, entity))
                        == Some(true);
                if present {
                    return Err(ComponentEditError::IncompatibleComponent(other.clone()));
                }
            }
        }
        for schema in requirements {
            if (schema.has)(self, entity) {
                continue;
            }
            (schema.make_default)(entity, self);
            if !(schema.has)(self, entity) {
                return Err(ComponentEditError::IncompatibleComponent(
                    schema.type_id.clone(),
                ));
            }
        }
        Ok(())
    }

    /// Makes a default component for `schema`, leaving no partial state on failure.
    pub fn make_default_component(
        &mut self,
        schema: &ComponentSchema,
        entity: EntityID,
    ) -> Result<(), ComponentDependencyError> {
        if (schema.has)(self, entity) {
            return Ok(());
        }
        let mut edited = self.clone();
        let requirements = edited
            .component_registry
            .required_schemas(&schema.type_id)
            .unwrap_or_default();
        if edited
            .ensure_required_components(&requirements, entity)
            .is_err()
        {
            return Err(ComponentDependencyError::DefaultUnavailable(
                schema.type_id.clone(),
            ));
        }
        for other in &schema.incompatible_with {
            let incompatible = edited
                .component_registry
                .get(other)
                .map(|other| (other.has)(&edited, entity))
                == Some(true);
            if incompatible {
                return Err(ComponentDependencyError::DefaultUnavailable(
                    schema.type_id.clone(),
                ));
            }
        }
        (schema.make_default)(entity, &mut edited);
        if !(schema.has)(&edited, entity) {
            return Err(ComponentDependencyError::DefaultUnavailable(
                schema.type_id.clone(),
            ));
        }
        *self = edited;
        Ok(())
    }
}

/// `max(0, min(index, upper))` with Swift's `Int` semantics.
fn clamp_index(index: i64, upper: i64) -> i64 {
    let upper = upper.max(0);
    if index < 0 {
        0
    } else if index > upper {
        upper
    } else {
        index
    }
}

fn component_affects_physics<C: RuntimeComponent>() -> bool {
    let key = ComponentTypeKey::of::<C>();
    key == ComponentTypeKey::of::<RigidBody>()
        || key == ComponentTypeKey::of::<Collider>()
        || key == ComponentTypeKey::of::<Constraint>()
        || key == ComponentTypeKey::of::<CharacterController>()
        || key == ComponentTypeKey::of::<Vehicle>()
        || key == ComponentTypeKey::of::<Ragdoll>()
        || key == ComponentTypeKey::of::<SoftBody>()
        || key == ComponentTypeKey::of::<Cloth>()
        || key == ComponentTypeKey::of::<LocalTransform>()
        || key == ComponentTypeKey::of::<WorldTransform>()
        || key == ComponentTypeKey::of::<Parent>()
        || key == ComponentTypeKey::of::<Children>()
}

fn resource_affects_physics<R: 'static>() -> bool {
    let key = ComponentTypeKey::of_type::<R>();
    key == ComponentTypeKey::of_type::<PhysicsSettingsResource>()
        || key == ComponentTypeKey::of_type::<MeshColliderBoundsResource>()
        || key == ComponentTypeKey::of_type::<MeshColliderGeometryResource>()
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::FRAC_PI_2;

    fn approx(a: f32, b: f32) {
        assert!((a - b).abs() < 1e-5, "{a} !~= {b}");
    }

    #[test]
    fn identity_translation_is_origin_and_rotation_is_identity() {
        let transform = LocalTransform::IDENTITY;
        assert_eq!(transform.translation(), Float3::ZERO);
        let rotation = transform.rotation();
        approx(rotation.real(), 1.0);
        approx(rotation.imag().x, 0.0);
        approx(rotation.imag().y, 0.0);
        approx(rotation.imag().z, 0.0);
    }

    #[test]
    fn translation_initializer_writes_column_three() {
        let transform = LocalTransform::from_translation(Float3::new(1.0, 2.0, 3.0));
        assert_eq!(transform.translation(), Float3::new(1.0, 2.0, 3.0));
        // Column 3's w stays 1.
        approx(transform.matrix.columns[3].w, 1.0);
    }

    #[test]
    fn translation_setter_keeps_w_at_one() {
        let mut transform = LocalTransform::IDENTITY;
        transform.set_translation(Float3::new(-4.0, 0.5, 9.0));
        assert_eq!(transform.translation(), Float3::new(-4.0, 0.5, 9.0));
        approx(transform.matrix.columns[3].w, 1.0);
    }

    #[test]
    fn rotation_round_trips_through_matrix() {
        let rotation = Quatf::from_angle_axis(FRAC_PI_2, Float3::new(0.0, 1.0, 0.0));
        let transform =
            LocalTransform::from_translation_rotation_scale(Float3::ZERO, rotation, Float3::ONE);
        let recovered = transform.rotation();
        // q and -q describe the same rotation, so compare the inner product.
        let dot = recovered.vector.x * rotation.vector.x
            + recovered.vector.y * rotation.vector.y
            + recovered.vector.z * rotation.vector.z
            + recovered.vector.w * rotation.vector.w;
        approx(dot.abs(), 1.0);
    }

    #[test]
    fn with_translation_preserves_rotation_and_scale() {
        let scale = Float3::new(2.0, 3.0, 4.0);
        let transform = LocalTransform::from_translation_rotation_scale(
            Float3::new(1.0, 1.0, 1.0),
            LocalTransform::default_rotation(),
            scale,
        );
        let moved = transform.with_translation(Float3::new(7.0, 8.0, 9.0));
        assert_eq!(moved.translation(), Float3::new(7.0, 8.0, 9.0));
        approx(moved.matrix.columns[0].x, 2.0);
        approx(moved.matrix.columns[1].y, 3.0);
        approx(moved.matrix.columns[2].z, 4.0);
    }

    #[test]
    fn with_rotation_preserves_translation() {
        let transform = LocalTransform::from_translation(Float3::new(1.0, 2.0, 3.0));
        let rotated = transform.with_rotation(Quatf::from_angle_axis(
            FRAC_PI_2,
            Float3::new(0.0, 1.0, 0.0),
        ));
        assert_eq!(rotated.translation(), Float3::new(1.0, 2.0, 3.0));
    }

    #[test]
    fn degenerate_scale_does_not_divide_by_zero() {
        // Swift falls back to a divisor of 1 when a column is <= 1e-6 long.
        let transform = LocalTransform::from_translation_rotation_scale(
            Float3::ZERO,
            LocalTransform::default_rotation(),
            Float3::ZERO,
        );
        let rotation = transform.rotation();
        assert!(rotation.real().is_finite());
    }

    #[test]
    fn world_transform_translation_reads_column_three() {
        let mut matrix = MATRIX_IDENTITY_FLOAT4X4;
        matrix.set_column(3, Float4::new(5.0, 6.0, 7.0, 1.0));
        let transform = WorldTransform::new(matrix);
        assert_eq!(transform.translation(), Float3::new(5.0, 6.0, 7.0));
    }
}

#[cfg(test)]
mod world_tests {
    use super::*;
    use crate::physics::rigid_body::RigidBodyOptions;
    use diffuse_math::simd::simd_compat::Float4;

    fn world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    #[test]
    fn create_entity_allocates_sequential_slots() {
        let mut world = world();
        let a = world.create_entity();
        let b = world.create_entity();
        assert_eq!(a, EntityID::new(0, 0));
        assert_eq!(b, EntityID::new(1, 0));
        assert_eq!(world.entity_count(), 2);
        assert!(world.contains(a));
    }

    #[test]
    fn destroy_bumps_generation_and_reuses_slot() {
        let mut world = world();
        let a = world.create_entity();
        assert!(world.destroy_entity(a));
        assert!(!world.contains(a));
        let b = world.create_entity();
        // Same index, next generation.
        assert_eq!(b.index, a.index);
        assert_eq!(b.generation, a.generation + 1);
        assert!(world.contains(b));
        assert!(!world.contains(a), "stale handle must not resolve");
    }

    #[test]
    fn destroy_promotes_children_to_roots() {
        let mut world = world();
        let parent = world.create_entity();
        let child = world.create_entity();
        assert!(world.set_parent(Some(parent), child));
        assert_eq!(world.children(parent), vec![child]);
        assert!(world.destroy_entity(parent));
        assert_eq!(world.parent(child), None);
        assert!(world.roots().contains(&child));
    }

    #[test]
    fn set_parent_rejects_self_and_cycles() {
        let mut world = world();
        let parent = world.create_entity();
        let child = world.create_entity();
        assert!(!world.set_parent(Some(child), child));
        assert!(world.set_parent(Some(parent), child));
        // parent is a descendant of child now, so the reverse edge is illegal.
        assert!(!world.set_parent(Some(child), parent));
    }

    #[test]
    fn propagate_world_transforms_multiplies_parent_and_local() {
        let mut world = world();
        let parent = world.create_entity();
        let child = world.create_entity();
        world.set_component(
            LocalTransform::from_translation(Float3::new(10.0, 0.0, 0.0)),
            parent,
        );
        world.set_component(
            LocalTransform::from_translation(Float3::new(0.0, 5.0, 0.0)),
            child,
        );
        world.set_parent(Some(parent), child);
        world.propagate_transforms_default();
        let world_transform = world.world_transform(child).expect("world transform");
        assert_eq!(world_transform.translation(), Float3::new(10.0, 5.0, 0.0));
    }

    #[test]
    fn propagate_is_noop_when_nothing_is_dirty() {
        let mut world = world();
        world.create_entity();
        // No transform/structural edits yet, so nothing is dirty.
        assert!(!world.hierarchy_needs_propagation());
        let first = world.revision();
        world.propagate_transforms_default();
        assert_eq!(world.revision(), first);
    }

    #[test]
    fn local_transform_defaults_to_identity_for_live_entities() {
        let mut world = world();
        let entity = world.create_entity();
        assert_eq!(
            world.local_transform(entity),
            Some(LocalTransform::IDENTITY)
        );
        assert_eq!(world.local_transform(EntityID::new(99, 0)), None);
    }

    #[test]
    fn document_components_round_trip_and_clear_on_destroy() {
        let mut world = world();
        let entity = world.create_entity();
        let value = ComponentValue::String("hello".to_string());
        assert!(world.set_document_component("mod.thing", value.clone(), entity));
        assert_eq!(world.document_component("mod.thing", entity), Some(&value));
        world.destroy_entity(entity);
        assert_eq!(world.document_component("mod.thing", entity), None);
    }

    #[test]
    fn resources_round_trip_and_isolate_copies() {
        let mut world = world();
        world.set_resource(PhysicsSettingsResource::default());
        assert!(world.resource::<PhysicsSettingsResource>().is_some());

        let mut copy = world.clone();
        assert!(copy.resource::<PhysicsSettingsResource>().is_some());
        assert!(copy.remove_resource::<PhysicsSettingsResource>().is_some());
        // The original must not observe the copy's removal.
        assert!(world.resource::<PhysicsSettingsResource>().is_some());
    }

    #[test]
    fn component_copies_are_deep() {
        let mut world = world();
        let entity = world.create_entity();
        world.set_component(LocalTransform::from_translation(Float3::splat(1.0)), entity);
        let mut copy = world.clone();
        copy.set_component(LocalTransform::from_translation(Float3::splat(9.0)), entity);
        assert_eq!(
            world.local_transform(entity).map(|t| t.translation()),
            Some(Float3::splat(1.0))
        );
        assert_eq!(
            copy.local_transform(entity).map(|t| t.translation()),
            Some(Float3::splat(9.0))
        );
    }

    #[test]
    fn queries_are_sorted_by_raw_value() {
        let mut world = world();
        let a = world.create_entity();
        let b = world.create_entity();
        world.set_component(LocalTransform::from_translation(Float3::splat(1.0)), b);
        world.set_component(LocalTransform::from_translation(Float3::splat(1.0)), a);
        let entities = world.entities_with::<LocalTransform>();
        let mut sorted = entities.clone();
        sorted.sort_by_key(|entity| entity.raw_value());
        assert_eq!(entities, sorted);
    }

    #[test]
    fn physics_revision_only_moves_for_physics_components() {
        let mut world = world();
        let entity = world.create_entity();
        let before = world.physics_revision();
        // `AudioSource` is not a physics component.
        world.set_component(crate::media::audio::AudioSource::default(), entity);
        assert_eq!(world.physics_revision(), before);
        world.set_component(RigidBody::new(RigidBodyOptions::default()), entity);
        assert!(world.physics_revision() > before);
    }

    #[test]
    fn applying_force_requires_dynamic_body() {
        let mut world = world();
        let entity = world.create_entity();
        let options = RigidBodyOptions {
            motion_type: RigidBodyMotionType::Static,
            ..RigidBodyOptions::default()
        };
        world.set_component(RigidBody::new(options), entity);
        assert!(!world.apply_force(Float3::splat(1.0), entity, true));
    }

    #[test]
    fn applying_force_accumulates_on_dynamic_body() {
        let mut world = world();
        let entity = world.create_entity();
        world.set_component(RigidBody::new(RigidBodyOptions::default()), entity);
        assert!(world.apply_force(Float3::splat(2.0), entity, true));
        let body = world.component::<RigidBody>(entity).expect("body");
        assert_eq!(body.accumulated_force, Float3::splat(2.0));
        assert!(!body.is_sleeping);
    }

    #[test]
    fn apply_force_at_adds_torque_from_offset() {
        let mut world = world();
        let entity = world.create_entity();
        world.set_component(RigidBody::new(RigidBodyOptions::default()), entity);
        world.set_component(WorldTransform::IDENTITY, entity);
        // Force +Z applied at +X offset yields torque about -Y.
        assert!(world.apply_force_at(
            Float3::new(0.0, 0.0, 1.0),
            Float3::new(1.0, 0.0, 0.0),
            entity,
            true
        ));
        let body = world.component::<RigidBody>(entity).expect("body");
        assert_eq!(body.accumulated_torque, Float3::new(0.0, -1.0, 0.0));
    }

    #[test]
    fn writeback_recomputes_local_from_parent() {
        let mut world = world();
        let parent = world.create_entity();
        let child = world.create_entity();
        world.set_parent(Some(parent), child);
        world.set_component(
            WorldTransform::new(Float4x4::from_columns([
                Float4::new(1.0, 0.0, 0.0, 0.0),
                Float4::new(0.0, 1.0, 0.0, 0.0),
                Float4::new(0.0, 0.0, 1.0, 0.0),
                Float4::new(4.0, 0.0, 0.0, 1.0),
            ])),
            parent,
        );
        let target = WorldTransform::new(Float4x4::from_columns([
            Float4::new(1.0, 0.0, 0.0, 0.0),
            Float4::new(0.0, 1.0, 0.0, 0.0),
            Float4::new(0.0, 0.0, 1.0, 0.0),
            Float4::new(9.0, 0.0, 0.0, 1.0),
        ]));
        let mut writeback = PhysicsBodyWriteback::new(child);
        writeback.world_transform = Some(target);
        assert!(world.apply_physics_writeback(&writeback));
        // local = inverse(parent world) * target = translate(5).
        assert_eq!(
            world.local_transform(child).map(|t| t.translation()),
            Some(Float3::new(5.0, 0.0, 0.0))
        );
    }

    #[test]
    fn move_entity_reorders_children_with_swift_index_adjustment() {
        let mut world = world();
        let parent = world.create_entity();
        let a = world.create_entity();
        let b = world.create_entity();
        world.set_parent(Some(parent), a);
        world.set_parent(Some(parent), b);
        assert_eq!(world.children(parent), vec![a, b]);

        // Swift 6.4.1 verified: moving `a` (index 0) to index 1 in a 2-element list
        // is a NO-OP, because destinationIndex is decremented when
        // existingIndex < clampedIndex, making it equal existingIndex.
        assert!(world.move_entity(a, Some(parent), 1));
        assert_eq!(world.children(parent), vec![a, b]);

        // Moving `b` (index 1) to index 0 does reorder.
        assert!(world.move_entity(b, Some(parent), 0));
        assert_eq!(world.children(parent), vec![b, a]);
    }

    #[test]
    fn move_entity_index_adjustment_matches_swift_with_three_children() {
        // Swift 6.4.1 verified: ["a","b","c"], move "a" to 2 -> ["b","a","c"].
        let mut world = world();
        let parent = world.create_entity();
        let a = world.create_entity();
        let b = world.create_entity();
        let c = world.create_entity();
        for child in [a, b, c] {
            world.set_parent(Some(parent), child);
        }
        assert_eq!(world.children(parent), vec![a, b, c]);
        assert!(world.move_entity(a, Some(parent), 2));
        assert_eq!(world.children(parent), vec![b, a, c]);
    }

    #[test]
    fn summary_counts_stores_and_resources() {
        let mut world = world();
        let entity = world.create_entity();
        world.set_component(LocalTransform::IDENTITY, entity);
        world.set_resource(PhysicsSettingsResource::default());
        let summary = world.summary();
        assert_eq!(summary.entity_count, 1);
        assert!(summary.component_store_count >= 1);
        assert_eq!(summary.resource_count, 1);
    }
}
