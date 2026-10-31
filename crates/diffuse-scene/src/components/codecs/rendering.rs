//! `Codecs/Rendering.swift` — transform, mesh, camera and light documents.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::Float3;

use crate::components::codecs::builtin_component_codecs::BuiltinComponentCodecs;
use crate::components::component_json_helpers::{
    decode_json_value, encode_json_value, integer, json_to_bool, json_to_float,
    json_to_float_array, json_to_int, json_to_matrix, json_to_string, json_to_vec3,
    matrix_to_json, number, object, vec3_to_json,
};
use crate::components::core::value::ComponentValue;
use crate::rendering::render_extraction::{
    CameraComponent, LightComponent, LightType, RenderMeshComponent,
};
use crate::runtime_world::LocalTransform;

impl BuiltinComponentCodecs {
    /// Swift `serializeLocalTransform` — the full matrix, flat and column-major.
    pub fn serialize_local_transform(
        transform: &LocalTransform,
    ) -> BTreeMap<String, ComponentValue> {
        object([("matrix", matrix_to_json(&transform.matrix))])
    }

    /// Swift `deserializeLocalTransform` — anything other than sixteen numbers is
    /// the identity transform.
    pub fn deserialize_local_transform(
        fields: &BTreeMap<String, ComponentValue>,
    ) -> LocalTransform {
        let Some(values) = json_to_float_array(fields.get("matrix")) else {
            return LocalTransform::IDENTITY;
        };
        if values.len() != 16 {
            return LocalTransform::IDENTITY;
        }
        match json_to_matrix(&values) {
            Some(matrix) => LocalTransform::new(matrix),
            None => LocalTransform::IDENTITY,
        }
    }

    pub fn serialize_render_mesh(
        component: &RenderMeshComponent,
    ) -> BTreeMap<String, ComponentValue> {
        let mut document = object([
            ("meshIndex", integer(component.mesh_index)),
            ("isVisible", ComponentValue::Bool(component.is_visible)),
        ]);
        document.insert("colorTint".to_string(), vec3_to_json(component.color_tint));
        if let Some(asset_id) = &component.asset_id {
            document.insert("assetID".to_string(), ComponentValue::String(asset_id.clone()));
        }
        // Swift assigns `encodeJSONValue(...)` and a failing encode removes the key.
        if !component.levels_of_detail.is_empty()
            && let Some(value) = encode_json_value(&component.levels_of_detail)
        {
            document.insert("levelsOfDetail".to_string(), value);
        }
        document
    }

    pub fn deserialize_render_mesh(
        document: &BTreeMap<String, ComponentValue>,
    ) -> RenderMeshComponent {
        RenderMeshComponent::new(
            json_to_int(document.get("meshIndex")).unwrap_or(0),
            json_to_bool(document.get("isVisible")).unwrap_or(true),
            json_to_float_array(document.get("colorTint"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::splat(1.0)),
            json_to_string(document.get("assetID")).map(str::to_string),
            decode_json_value(document.get("levelsOfDetail")).unwrap_or_default(),
        )
    }

    pub fn serialize_camera(component: &CameraComponent) -> BTreeMap<String, ComponentValue> {
        object([
            ("isActive", ComponentValue::Bool(component.is_active)),
            ("fovYRadians", number(component.fov_y_radians)),
            ("aspectRatio", number(component.aspect_ratio)),
            ("near", number(component.near)),
            ("far", number(component.far)),
            ("target", vec3_to_json(component.target)),
            ("up", vec3_to_json(component.up)),
        ])
    }

    pub fn deserialize_camera(document: &BTreeMap<String, ComponentValue>) -> CameraComponent {
        CameraComponent::new(
            json_to_float_array(document.get("target"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::new(0.0, 1.0, 0.0)),
            json_to_float_array(document.get("up"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::new(0.0, 1.0, 0.0)),
            json_to_float(document.get("fovYRadians")).unwrap_or(1.0),
            json_to_float(document.get("aspectRatio")).unwrap_or(1.0),
            json_to_float(document.get("near")).unwrap_or(0.1),
            json_to_float(document.get("far")).unwrap_or(1000.0),
            json_to_bool(document.get("isActive")).unwrap_or(false),
        )
    }

    pub fn serialize_light(component: &LightComponent) -> BTreeMap<String, ComponentValue> {
        object([
            (
                "type",
                ComponentValue::String(component.light_type.raw_value().to_string()),
            ),
            ("color", vec3_to_json(component.color)),
            ("intensity", number(component.intensity)),
            ("range", number(component.range)),
            (
                "spotInnerAngleDegrees",
                number(component.spot_inner_angle_degrees),
            ),
            (
                "spotOuterAngleDegrees",
                number(component.spot_outer_angle_degrees),
            ),
            ("castShadows", ComponentValue::Bool(component.cast_shadows)),
        ])
    }

    pub fn deserialize_light(document: &BTreeMap<String, ComponentValue>) -> LightComponent {
        let light_type = json_to_string(document.get("type"))
            .and_then(LightType::from_raw_value)
            .unwrap_or(LightType::Point);
        LightComponent::new(
            light_type,
            json_to_float_array(document.get("color"))
                .and_then(|values| json_to_vec3(&values))
                .unwrap_or(Float3::splat(1.0)),
            json_to_float(document.get("intensity")).unwrap_or(1.0),
            json_to_float(document.get("range")).unwrap_or(10.0),
            json_to_float(document.get("spotInnerAngleDegrees")).unwrap_or(30.0),
            json_to_float(document.get("spotOuterAngleDegrees")).unwrap_or(45.0),
            json_to_bool(document.get("castShadows")).unwrap_or(false),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_transform_round_trips_and_defaults_to_identity() {
        let transform = LocalTransform::from_translation(Float3::new(1.0, 2.0, 3.0));
        let document = BuiltinComponentCodecs::serialize_local_transform(&transform);
        assert_eq!(BuiltinComponentCodecs::deserialize_local_transform(&document), transform);
        assert_eq!(
            BuiltinComponentCodecs::deserialize_local_transform(&BTreeMap::new()),
            LocalTransform::IDENTITY
        );
        let mut short = BTreeMap::new();
        short.insert(
            "matrix".to_string(),
            ComponentValue::Array(vec![number(1.0)]),
        );
        assert_eq!(
            BuiltinComponentCodecs::deserialize_local_transform(&short),
            LocalTransform::IDENTITY
        );
    }

    #[test]
    fn camera_defaults_match_the_swift_codec() {
        let camera = BuiltinComponentCodecs::deserialize_camera(&BTreeMap::new());
        assert_eq!(camera.target, Float3::new(0.0, 1.0, 0.0));
        assert_eq!(camera.up, Float3::new(0.0, 1.0, 0.0));
        assert_eq!(camera.fov_y_radians, 1.0);
        assert_eq!(camera.aspect_ratio, 1.0);
        assert_eq!(camera.near, 0.1);
        assert_eq!(camera.far, 1000.0);
        assert!(!camera.is_active);
    }

    #[test]
    fn light_serializes_the_raw_case_name() {
        let light = LightComponent::new(
            LightType::Spot,
            Float3::splat(1.0),
            2.0,
            4.0,
            10.0,
            20.0,
            true,
        );
        let document = BuiltinComponentCodecs::serialize_light(&light);
        assert_eq!(
            document.get("type"),
            Some(&ComponentValue::String("spot".to_string()))
        );
        assert_eq!(
            BuiltinComponentCodecs::deserialize_light(&document),
            LightComponent::new(
                LightType::Spot,
                Float3::splat(1.0),
                2.0,
                4.0,
                10.0,
                20.0,
                true
            )
        );
    }

    #[test]
    fn render_mesh_omits_absent_optional_keys() {
        let mesh = RenderMeshComponent::new(3, false, Float3::splat(0.5), None, Vec::new());
        let document = BuiltinComponentCodecs::serialize_render_mesh(&mesh);
        assert!(!document.contains_key("assetID"));
        assert!(!document.contains_key("levelsOfDetail"));
        assert_eq!(
            BuiltinComponentCodecs::deserialize_render_mesh(&document),
            mesh
        );
    }
}
