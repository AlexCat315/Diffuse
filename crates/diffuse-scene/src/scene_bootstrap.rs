//! Scene naming/reference components and the editor preview bootstrap.
//!
//! Ported from `Engine/Sources/SceneRuntime/SceneBootstrap.swift`.
//!
//! The component types and the three preview matrix helpers are the closed prefix:
//! they have no forward dependency. `bootstrap_editor_preview_scene` is a
//! `SceneRuntime` extension, so it lands with `scene_runtime.rs`; it also needs
//! `ParticleEmitter`, which is a separate module.

use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};

use crate::entity_id::{EntityID, RuntimeComponent};

/// `SceneNameComponent` — the display name shown in the hierarchy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SceneNameComponent {
    pub value: String,
}

impl SceneNameComponent {
    pub fn new(value: impl Into<String>) -> Self {
        SceneNameComponent {
            value: value.into(),
        }
    }
}

impl RuntimeComponent for SceneNameComponent {}

/// `SceneKindComponent` — the authored category label ("Camera", "Group", ...).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SceneKindComponent {
    pub value: String,
}

impl SceneKindComponent {
    pub fn new(value: impl Into<String>) -> Self {
        SceneKindComponent {
            value: value.into(),
        }
    }
}

impl RuntimeComponent for SceneKindComponent {}

/// `AssetReferenceComponent` — the imported-asset provenance of an entity.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AssetReferenceComponent {
    pub asset_id: String,
    pub name: String,
    pub relative_path: String,
    pub absolute_path: String,
    pub kind: String,
    pub mesh_index: i64,
}

impl AssetReferenceComponent {
    pub fn new(
        asset_id: impl Into<String>,
        name: impl Into<String>,
        relative_path: impl Into<String>,
        absolute_path: impl Into<String>,
        kind: impl Into<String>,
        mesh_index: i64,
    ) -> Self {
        AssetReferenceComponent {
            asset_id: asset_id.into(),
            name: name.into(),
            relative_path: relative_path.into(),
            absolute_path: absolute_path.into(),
            kind: kind.into(),
            mesh_index,
        }
    }
}

impl RuntimeComponent for AssetReferenceComponent {}

/// `SceneBootstrapDefaultsResource` — the editor's initial selection and expansion.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SceneBootstrapDefaultsResource {
    pub default_selection: Option<EntityID>,
    pub default_expanded: Vec<EntityID>,
}

impl SceneBootstrapDefaultsResource {
    pub fn new(default_selection: Option<EntityID>, default_expanded: Vec<EntityID>) -> Self {
        SceneBootstrapDefaultsResource {
            default_selection,
            default_expanded,
        }
    }
}

/// `previewTranslationMatrix(_:)`.
pub fn preview_translation_matrix(translation: Float3) -> Float4x4 {
    Float4x4::from_rows(&[
        Float4::new(1.0, 0.0, 0.0, translation.x),
        Float4::new(0.0, 1.0, 0.0, translation.y),
        Float4::new(0.0, 0.0, 1.0, translation.z),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ])
}

/// `previewScaleMatrix(_:)`.
pub fn preview_scale_matrix(scale: Float3) -> Float4x4 {
    Float4x4::from_rows(&[
        Float4::new(scale.x, 0.0, 0.0, 0.0),
        Float4::new(0.0, scale.y, 0.0, 0.0),
        Float4::new(0.0, 0.0, scale.z, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ])
}

/// `previewTranslationScaleMatrix(translation:scale:)` — translation times scale,
/// in that order, so the scale applies first.
pub fn preview_translation_scale_matrix(translation: Float3, scale: Float3) -> Float4x4 {
    preview_translation_matrix(translation) * preview_scale_matrix(scale)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_translation_writes_column_three() {
        let matrix = preview_translation_matrix(Float3::new(4.0, 6.0, 2.0));
        assert_eq!(matrix.columns[3], Float4::new(4.0, 6.0, 2.0, 1.0));
        assert_eq!(matrix.columns[0], Float4::new(1.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn preview_scale_writes_diagonal() {
        let matrix = preview_scale_matrix(Float3::new(8.0, 0.5, 8.0));
        assert_eq!(matrix.columns[0], Float4::new(8.0, 0.0, 0.0, 0.0));
        assert_eq!(matrix.columns[1], Float4::new(0.0, 0.5, 0.0, 0.0));
        assert_eq!(matrix.columns[2], Float4::new(0.0, 0.0, 8.0, 0.0));
        assert_eq!(matrix.columns[3], Float4::new(0.0, 0.0, 0.0, 1.0));
    }

    #[test]
    fn preview_translation_scale_is_translation_times_scale() {
        let translation = Float3::new(0.0, -1.0, 0.0);
        let scale = Float3::new(8.0, 0.5, 8.0);
        let combined = preview_translation_scale_matrix(translation, scale);
        assert_eq!(
            combined,
            preview_translation_matrix(translation) * preview_scale_matrix(scale)
        );
        // Scale lands on the diagonal, translation on column 3 — the translation is
        // not scaled.
        assert_eq!(combined.columns[0], Float4::new(8.0, 0.0, 0.0, 0.0));
        assert_eq!(combined.columns[3], Float4::new(0.0, -1.0, 0.0, 1.0));
    }

    #[test]
    fn bootstrap_defaults_have_no_selection() {
        let defaults = SceneBootstrapDefaultsResource::default();
        assert_eq!(defaults.default_selection, None);
        assert!(defaults.default_expanded.is_empty());
    }
}
