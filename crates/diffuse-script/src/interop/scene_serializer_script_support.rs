use super::component_registry_script_codec::ComponentRegistryScriptCodec;
use diffuse_scene::{
    entity_id::EntityID,
    runtime_world::LocalTransform,
    scene_graph::prefab::{Prefab, PrefabError},
    scene_runtime::SceneRuntime,
    serialization::scene_serializer::{SceneSerializer, SceneSerializerError},
};

pub trait SceneSerializerScriptSupport {
    fn serialize_full(scene: &SceneRuntime) -> Result<Vec<u8>, SceneSerializerError>;
    fn deserialize_full(data: &[u8], scene: &mut SceneRuntime) -> Result<(), SceneSerializerError>;
}

impl SceneSerializerScriptSupport for SceneSerializer {
    fn serialize_full(scene: &SceneRuntime) -> Result<Vec<u8>, SceneSerializerError> {
        let mut document_scene = scene.clone();
        document_scene
            .world_mut()
            .component_registry
            .register_default_script_codec();
        SceneSerializer::serialize(document_scene.world()).map(String::into_bytes)
    }

    fn deserialize_full(data: &[u8], scene: &mut SceneRuntime) -> Result<(), SceneSerializerError> {
        scene
            .world_mut()
            .component_registry
            .register_default_script_codec();
        let text = std::str::from_utf8(data).map_err(|_| SceneSerializerError::InvalidFormat)?;
        SceneSerializer::deserialize(text, scene.world_mut()).map(|_| ())
    }
}

pub trait PrefabScriptSupport {
    fn instantiate_full(
        &self,
        scene: &mut SceneRuntime,
        parent: Option<EntityID>,
        transform: Option<LocalTransform>,
    ) -> Result<Option<EntityID>, PrefabError>;
    fn capture_full(scene: &SceneRuntime, root: EntityID) -> Result<Option<Prefab>, PrefabError>;
}

impl PrefabScriptSupport for Prefab {
    fn instantiate_full(
        &self,
        scene: &mut SceneRuntime,
        parent: Option<EntityID>,
        transform: Option<LocalTransform>,
    ) -> Result<Option<EntityID>, PrefabError> {
        scene
            .world_mut()
            .component_registry
            .register_default_script_codec();
        self.instantiate(scene.world_mut(), parent, transform)
    }
    fn capture_full(scene: &SceneRuntime, root: EntityID) -> Result<Option<Prefab>, PrefabError> {
        let mut document_scene = scene.clone();
        document_scene
            .world_mut()
            .component_registry
            .register_default_script_codec();
        Self::capture(document_scene.world(), root)
    }
}
