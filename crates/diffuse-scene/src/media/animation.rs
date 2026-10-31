/// One skeleton's joint matrices, in palette order.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct JointPalette {
    pub matrices: Vec<diffuse_math::simd::simd_compat::Float4x4>,
}

impl JointPalette {
    pub fn new(matrices: Vec<diffuse_math::simd::simd_compat::Float4x4>) -> Self {
        JointPalette { matrices }
    }

    /// Swift's `JointPalette.identity`: a single identity matrix.
    pub fn identity() -> Self {
        JointPalette {
            matrices: vec![diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4],
        }
    }
}

/// Scene-level resource mapping an entity to its joint palette.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct JointPaletteMap {
    pub palettes: std::collections::BTreeMap<crate::entity_id::EntityID, JointPalette>,
}

impl JointPaletteMap {
    pub fn new(
        palettes: std::collections::BTreeMap<crate::entity_id::EntityID, JointPalette>,
    ) -> Self {
        JointPaletteMap { palettes }
    }

    /// The palette for `entity`, or `None` when the entity has none.
    #[inline]
    pub fn palette(&self, entity: crate::entity_id::EntityID) -> Option<&JointPalette> {
        self.palettes.get(&entity)
    }
}

#[cfg(test)]
mod joint_palette_tests {
    use super::*;
    use crate::entity_id::EntityID;

    #[test]
    fn an_identity_palette_holds_one_identity_matrix() {
        let palette = JointPalette::identity();
        assert_eq!(palette.matrices.len(), 1);
        assert_eq!(
            palette.matrices[0],
            diffuse_math::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4
        );
    }

    #[test]
    fn a_missing_palette_is_none() {
        let map = JointPaletteMap::default();
        assert!(map.palette(EntityID::new(1, 0)).is_none());
    }
}
