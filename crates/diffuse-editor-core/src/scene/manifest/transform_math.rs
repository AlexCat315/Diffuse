//! `Editor/Sources/EditorCore/Scene/Manifest/TransformMath.swift`.
//!
//! JSON-friendly vector and matrix spellings of the runtime SIMD types.

use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};
use diffuse_scene::runtime_world::LocalTransform;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct EditorSceneManifestVector3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl EditorSceneManifestVector3 {
    pub fn new(x: f32, y: f32, z: f32) -> Self {
        EditorSceneManifestVector3 { x, y, z }
    }

    pub fn from_simd(value: Float3) -> Self {
        Self::new(value.x, value.y, value.z)
    }

    pub fn simd_value(&self) -> Float3 {
        Float3::new(self.x, self.y, self.z)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct EditorSceneManifestVector4 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

impl EditorSceneManifestVector4 {
    pub fn new(x: f32, y: f32, z: f32, w: f32) -> Self {
        EditorSceneManifestVector4 { x, y, z, w }
    }

    pub fn from_simd(value: Float4) -> Self {
        Self::new(value.x, value.y, value.z, value.w)
    }

    pub fn simd_value(&self) -> Float4 {
        Float4::new(self.x, self.y, self.z, self.w)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct EditorSceneManifestMatrix {
    pub rows: Vec<f32>,
}

impl EditorSceneManifestMatrix {
    pub fn new(rows: Vec<f32>) -> Self {
        EditorSceneManifestMatrix { rows }
    }

    pub fn from_matrix(matrix: &Float4x4) -> Self {
        let c0 = matrix.columns[0];
        let c1 = matrix.columns[1];
        let c2 = matrix.columns[2];
        let c3 = matrix.columns[3];
        EditorSceneManifestMatrix {
            rows: vec![
                c0.x, c1.x, c2.x, c3.x, c0.y, c1.y, c2.y, c3.y, c0.z, c1.z, c2.z, c3.z, c0.w, c1.w,
                c2.w, c3.w,
            ],
        }
    }

    /// `simd_float4x4(rows:)`: the rows feed the columns.
    pub fn simd_value(&self) -> Option<Float4x4> {
        if self.rows.len() != 16 {
            return None;
        }
        let row = |start: usize| {
            Float4::new(
                self.rows[start],
                self.rows[start + 1],
                self.rows[start + 2],
                self.rows[start + 3],
            )
        };
        Some(Float4x4::from_rows(&[row(0), row(4), row(8), row(12)]))
    }

    pub fn local_transform(&self) -> Option<LocalTransform> {
        self.simd_value().map(LocalTransform::new)
    }
}
