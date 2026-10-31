//! `Codecs/Assets.swift` — the `assetReference` document.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::components::codecs::builtin_component_codecs::BuiltinComponentCodecs;
use crate::components::component_json_helpers::{
    integer, json_to_bool, json_to_float, json_to_float_array, json_to_int, json_to_string,
    json_to_vec3, json_to_vec4, number, object, vec3_to_json, vec4_to_json,
};
use crate::components::core::value::ComponentValue;
use crate::rendering::render_extraction::RenderMaterialComponent;
use crate::rendering::render_scene::MaterialAlphaMode;
use crate::scene_bootstrap::AssetReferenceComponent;

impl BuiltinComponentCodecs {
    pub fn serialize_render_material(
        component: &RenderMaterialComponent,
    ) -> BTreeMap<String, ComponentValue> {
        let mut document = object([
            (
                "baseColorFactor",
                vec4_to_json(component.base_color_factor),
            ),
            ("metallicFactor", number(component.metallic_factor)),
            ("roughnessFactor", number(component.roughness_factor)),
            ("emissiveFactor", vec3_to_json(component.emissive_factor)),
        ]);
        if let Some(index) = component.base_color_texture_index {
            document.insert("baseColorTextureIndex".to_string(), integer(index));
        }
        if let Some(index) = component.normal_texture_index {
            document.insert("normalTextureIndex".to_string(), integer(index));
        }
        if let Some(value) = component.alpha_mode {
            document.insert(
                "alphaMode".to_string(),
                ComponentValue::String(value.raw_value().to_string()),
            );
        }
        if let Some(value) = component.alpha_cutoff {
            document.insert("alphaCutoff".to_string(), number(value));
        }
        if let Some(value) = component.double_sided {
            document.insert("doubleSided".to_string(), ComponentValue::Bool(value));
        }
        document
    }

    pub fn deserialize_render_material(
        document: &BTreeMap<String, ComponentValue>,
    ) -> RenderMaterialComponent {
        RenderMaterialComponent::new(
            json_to_float_array(document.get("baseColorFactor"))
                .and_then(|values| json_to_vec4(&values))
                .unwrap_or(Float4::new(1.0, 1.0, 1.0, 1.0)),
            json_to_int(document.get("baseColorTextureIndex")),
            json_to_int(document.get("normalTextureIndex")),
            json_to_float(document.get("metallicFactor")).unwrap_or(0.0),
            json_to_float(document.get("roughnessFactor")).unwrap_or(1.0),
            json_to_float_array(document.get("emissiveFactor"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::ZERO),
            json_to_string(document.get("alphaMode"))
                .and_then(MaterialAlphaMode::from_raw_value),
            json_to_float(document.get("alphaCutoff")),
            json_to_bool(document.get("doubleSided")),
        )
    }

    pub fn serialize_asset_reference(
        component: &AssetReferenceComponent,
    ) -> BTreeMap<String, ComponentValue> {
        object([
            (
                "assetID",
                ComponentValue::String(component.asset_id.clone()),
            ),
            ("name", ComponentValue::String(component.name.clone())),
            (
                "relativePath",
                ComponentValue::String(component.relative_path.clone()),
            ),
            (
                "absolutePath",
                ComponentValue::String(component.absolute_path.clone()),
            ),
            ("kind", ComponentValue::String(component.kind.clone())),
            ("meshIndex", integer(component.mesh_index)),
        ])
    }

    pub fn deserialize_asset_reference(
        document: &BTreeMap<String, ComponentValue>,
    ) -> AssetReferenceComponent {
        AssetReferenceComponent::new(
            json_to_string(document.get("assetID")).unwrap_or(""),
            json_to_string(document.get("name")).unwrap_or(""),
            json_to_string(document.get("relativePath")).unwrap_or(""),
            json_to_string(document.get("absolutePath")).unwrap_or(""),
            json_to_string(document.get("kind")).unwrap_or(""),
            json_to_int(document.get("meshIndex")).unwrap_or(0),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asset_reference_round_trips() {
        let component =
            AssetReferenceComponent::new("id", "name", "relative", "absolute", "mesh", 4);
        let document = BuiltinComponentCodecs::serialize_asset_reference(&component);
        assert_eq!(
            document.get("assetID"),
            Some(&ComponentValue::String("id".to_string()))
        );
        assert_eq!(
            BuiltinComponentCodecs::deserialize_asset_reference(&document),
            component
        );
    }

    #[test]
    fn missing_fields_decode_to_empty_strings() {
        let component = BuiltinComponentCodecs::deserialize_asset_reference(&BTreeMap::new());
        assert_eq!(component.asset_id, "");
        assert_eq!(component.name, "");
        assert_eq!(component.mesh_index, 0);
    }
}
