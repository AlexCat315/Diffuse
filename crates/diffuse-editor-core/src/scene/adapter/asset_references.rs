//! Translation of Editor/Sources/EditorCore/Scene/Adapter/AssetReferences.swift.

use std::collections::BTreeSet;
use std::path::Path;

use diffuse_scene::particles::emitter::particle_emitter::ParticleEmitter;
use diffuse_scene::rendering::render_extraction::RenderMeshComponent;
use diffuse_scene::scene_bootstrap::AssetReferenceComponent;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::assets::asset_catalog::{EditorAsset, EditorAssetCatalog};
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;

impl EditorSceneAdapter {
    pub fn referenced_asset(&self, raw_id: u64) -> Option<EditorAsset> {
        let entity = self.entity_from(Some(raw_id))?;
        let reference = self.scene().component::<AssetReferenceComponent>(entity)?;
        EditorAssetCatalog::asset_for(&reference.asset_id)
    }

    pub fn asset_referenced_entity_ids(&self, asset_id: &str) -> Vec<u64> {
        let scene = self.scene();
        let mut ids: BTreeSet<u64> = BTreeSet::new();
        for entity in scene.entities_with::<AssetReferenceComponent>() {
            if scene
                .component::<AssetReferenceComponent>(entity)
                .is_some_and(|reference| reference.asset_id == asset_id)
            {
                ids.insert(entity.raw_value());
            }
        }
        for entity in scene.entities_with::<RenderMeshComponent>() {
            if scene
                .component::<RenderMeshComponent>(entity)
                .and_then(|mesh| mesh.asset_id)
                .as_deref()
                == Some(asset_id)
            {
                ids.insert(entity.raw_value());
            }
        }
        for entity in scene.entities_with::<ParticleEmitter>() {
            if scene
                .component::<ParticleEmitter>(entity)
                .is_some_and(|emitter| {
                    emitter.settings.texture_sheet.texture_asset_id.as_deref() == Some(asset_id)
                })
            {
                ids.insert(entity.raw_value());
            }
        }
        ids.into_iter().collect()
    }

    pub fn missing_asset_paths(&self) -> Vec<String> {
        let scene = self.scene();
        let mut paths: BTreeSet<String> = BTreeSet::new();
        for entity in scene.entities_with::<AssetReferenceComponent>() {
            if let Some(asset) = scene.component::<AssetReferenceComponent>(entity)
                && !Path::new(&asset.absolute_path).exists()
            {
                paths.insert(asset.absolute_path);
            }
        }
        for entity in scene.entities_with::<ParticleEmitter>() {
            if let Some(path) = scene
                .component::<ParticleEmitter>(entity)
                .and_then(|emitter| emitter.settings.texture_sheet.texture_path)
                && !Path::new(&path).exists()
            {
                paths.insert(path);
            }
        }
        paths.into_iter().collect()
    }

    pub fn relocate_asset_references(&self, old_id: &str, asset: &EditorAsset) {
        let update = |runtime: &mut SceneRuntime| {
            for entity in runtime.entities_with::<AssetReferenceComponent>() {
                if runtime
                    .component::<AssetReferenceComponent>(entity)
                    .is_none_or(|reference| reference.asset_id != old_id)
                {
                    continue;
                }
                runtime.update_component::<AssetReferenceComponent>(entity, |reference| {
                    reference.asset_id = asset.id.clone();
                    reference.name = asset.name.clone();
                    reference.relative_path = asset.relative_path.clone();
                    reference.absolute_path = asset.absolute_path.clone();
                    reference.mesh_index = asset.mesh_index;
                });
            }
            for entity in runtime.entities_with::<RenderMeshComponent>() {
                if runtime
                    .component::<RenderMeshComponent>(entity)
                    .and_then(|mesh| mesh.asset_id)
                    .as_deref()
                    != Some(old_id)
                {
                    continue;
                }
                runtime.update_component::<RenderMeshComponent>(entity, |mesh| {
                    mesh.asset_id = Some(asset.id.clone());
                    mesh.mesh_index = asset.mesh_index;
                });
            }
            for entity in runtime.entities_with::<ParticleEmitter>() {
                if runtime
                    .component::<ParticleEmitter>(entity)
                    .is_none_or(|emitter| {
                        emitter.settings.texture_sheet.texture_asset_id.as_deref() != Some(old_id)
                    })
                {
                    continue;
                }
                runtime.update_component::<ParticleEmitter>(entity, |emitter| {
                    emitter.settings.texture_sheet.texture_asset_id = Some(asset.id.clone());
                    emitter.settings.texture_sheet.texture_path = Some(asset.absolute_path.clone());
                });
            }
        };
        self.with_scene_mut(update);
        self.edit_history.borrow_mut().remap_scenes(update);
        self.notify_revision_changed(false, None);
    }
}
