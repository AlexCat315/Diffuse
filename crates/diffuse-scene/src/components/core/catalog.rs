//! `Core/Catalog.swift` — discovery metadata for every runtime component type.
//!
//! Swift identifies a component by `ObjectIdentifier(C.self)` plus
//! `String(describing: C.self)`. Rust's equivalent is [`std::any::TypeId`] plus the
//! final path segment of [`std::any::type_name`], which reproduces the Swift type
//! names — except for `Constraint`, a Rust type alias whose underlying name is
//! `PhysicsJoint`, so it registers through the explicit-name constructor.
//!
//! `ComponentTypeID` is also the tuple used by [`crate::components::core::registry`]
//! for runtime (`ComponentTypeKey::Runtime`) keys, but it carries a display name the
//! registry key does not, so the two stay separate types.

use std::any::{TypeId, type_name};
use std::sync::LazyLock;

use crate::media::animation::{AnimationGraphPlayer, AnimationPlayer};
use crate::media::audio::{AudioListener, AudioSource};
use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::physics::character_controller::CharacterController;
use crate::physics::collider::Collider;
use crate::physics::destruction::Destructible;
use crate::physics::joints::physics_joint::Constraint;
use crate::physics::ragdoll::Ragdoll;
use crate::physics::rigid_body::RigidBody;
use crate::physics::soft_bodies::cloth::Cloth;
use crate::physics::soft_bodies::soft_body::{SoftBody, SoftBodyMesh};
use crate::physics::vehicles::vehicle::Vehicle;
use crate::rendering::render_extraction::{
    CameraComponent, LightComponent, RenderMaterialComponent, RenderMeshComponent,
};
use crate::runtime_world::{Children, LocalTransform, Parent, WorldTransform};
use crate::scene_bootstrap::{AssetReferenceComponent, SceneKindComponent, SceneNameComponent};

/// Swift `ComponentTypeID` — a component type's display name and identity.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ComponentTypeID {
    pub name: String,
    pub metatype: TypeId,
}

impl ComponentTypeID {
    /// Swift `init<C>(_ type: C.Type)` — the name is the unqualified type name.
    pub fn of<C: 'static>() -> Self {
        ComponentTypeID::named::<C>(unqualified_type_name::<C>())
    }

    /// Swift cannot express this case, but Rust needs it for type aliases such as
    /// `Constraint` (`PhysicsJoint`) that must keep the authored component name.
    pub fn named<C: 'static>(name: impl Into<String>) -> Self {
        ComponentTypeID {
            name: name.into(),
            metatype: TypeId::of::<C>(),
        }
    }

    /// Swift `$0.metatype == ObjectIdentifier(type)`.
    #[inline]
    pub fn is<C: 'static>(&self) -> bool {
        self.metatype == TypeId::of::<C>()
    }
}

/// Swift `String(describing: C.self)` for a concrete Rust type.
fn unqualified_type_name<C: 'static>() -> &'static str {
    let full = type_name::<C>();
    full.rsplit("::").next().unwrap_or(full)
}

/// Swift `ComponentCatalog`.
pub enum ComponentCatalog {}

impl ComponentCatalog {
    /// Swift `allKnown` — every `RuntimeComponent` type in registration order.
    pub fn all_known() -> &'static [ComponentTypeID] {
        static ALL_KNOWN: LazyLock<Vec<ComponentTypeID>> = LazyLock::new(|| {
            vec![
                // Spatial
                ComponentTypeID::of::<LocalTransform>(),
                ComponentTypeID::of::<WorldTransform>(),
                // Hierarchy
                ComponentTypeID::of::<Parent>(),
                ComponentTypeID::of::<Children>(),
                // Physics
                ComponentTypeID::of::<RigidBody>(),
                ComponentTypeID::of::<Collider>(),
                ComponentTypeID::named::<Constraint>("Constraint"),
                ComponentTypeID::of::<CharacterController>(),
                ComponentTypeID::of::<Vehicle>(),
                ComponentTypeID::of::<Ragdoll>(),
                ComponentTypeID::of::<SoftBody>(),
                ComponentTypeID::of::<Cloth>(),
                ComponentTypeID::of::<SoftBodyMesh>(),
                ComponentTypeID::of::<Destructible>(),
                // Scene metadata
                ComponentTypeID::of::<SceneNameComponent>(),
                ComponentTypeID::of::<SceneKindComponent>(),
                ComponentTypeID::of::<AssetReferenceComponent>(),
                // Rendering
                ComponentTypeID::of::<RenderMeshComponent>(),
                ComponentTypeID::of::<RenderMaterialComponent>(),
                ComponentTypeID::of::<CameraComponent>(),
                ComponentTypeID::of::<LightComponent>(),
                // Audio
                ComponentTypeID::of::<AudioSource>(),
                ComponentTypeID::of::<AudioListener>(),
                // Animation
                ComponentTypeID::of::<AnimationPlayer>(),
                ComponentTypeID::of::<AnimationGraphPlayer>(),
                // VFX
                ComponentTypeID::of::<ParticleEmitter>(),
            ]
        });
        &ALL_KNOWN
    }

    /// Swift `count`.
    pub fn count() -> usize {
        ComponentCatalog::all_known().len()
    }

    /// Swift `id(of:)` — `None` when the type is not registered.
    pub fn id<C: 'static>() -> Option<ComponentTypeID> {
        ComponentCatalog::all_known()
            .iter()
            .find(|identifier| identifier.is::<C>())
            .cloned()
    }

    /// Swift `componentNames` — the display names, sorted.
    pub fn component_names() -> Vec<String> {
        let mut names: Vec<String> = ComponentCatalog::all_known()
            .iter()
            .map(|identifier| identifier.name.clone())
            .collect();
        names.sort();
        names
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_catalog_lists_the_swift_registration_order() {
        let all = ComponentCatalog::all_known();
        assert_eq!(all.len(), 26);
        assert_eq!(all[0].name, "LocalTransform");
        assert_eq!(all[6].name, "Constraint");
        assert_eq!(all[25].name, "ParticleEmitter");
        assert_eq!(ComponentCatalog::count(), 26);
    }

    #[test]
    fn constraint_keeps_its_authored_name() {
        let identifier = ComponentCatalog::id::<Constraint>().expect("registered");
        assert_eq!(identifier.name, "Constraint");
        assert!(identifier.is::<PhysicsJointType>());
        assert!(ComponentCatalog::id::<u8>().is_none());
    }

    /// `Constraint` is an alias, so this is the same type the catalog stores.
    type PhysicsJointType = Constraint;

    #[test]
    fn component_names_are_sorted() {
        let names = ComponentCatalog::component_names();
        let mut sorted = names.clone();
        sorted.sort();
        assert_eq!(names, sorted);
        assert!(names.contains(&"RenderMeshComponent".to_string()));
    }
}
