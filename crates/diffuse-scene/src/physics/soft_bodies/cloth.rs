//! Cloth topology.

/// `ClothBendType` — `UInt8`-backed and `Codable`, so it persists as its raw value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClothBendType {
    None,
    Distance,
    Dihedral,
}

impl ClothBendType {
    pub const fn raw_value(&self) -> u8 {
        match self {
            ClothBendType::None => 0,
            ClothBendType::Distance => 1,
            ClothBendType::Dihedral => 2,
        }
    }

    pub const fn from_raw_value(value: u8) -> Option<Self> {
        match value {
            0 => Some(ClothBendType::None),
            1 => Some(ClothBendType::Distance),
            2 => Some(ClothBendType::Dihedral),
            _ => None,
        }
    }

    pub const ALL: [ClothBendType; 3] = [
        ClothBendType::None,
        ClothBendType::Distance,
        ClothBendType::Dihedral,
    ];
}

impl serde::Serialize for ClothBendType {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u8(self.raw_value())
    }
}

impl<'de> serde::Deserialize<'de> for ClothBendType {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = u8::deserialize(deserializer)?;
        ClothBendType::from_raw_value(value)
            .ok_or_else(|| serde::de::Error::custom(format!("Unknown cloth bend type: {value}")))
    }
}

/// Grid topology authored for a soft-body cloth.
#[derive(Clone, Debug, PartialEq)]
pub struct Cloth {
    pub grid_size_x: i64,
    pub grid_size_z: i64,
    pub spacing: f32,
    pub fixed_vertex_indices: Vec<i64>,
    pub compliance: f32,
    pub shear_compliance: f32,
    pub bend_compliance: f32,
    pub bend_type: ClothBendType,
}

/// `Cloth()`'s default `bendType` is `.distance`, while `SoftBodyMesh`'s is
/// `.dihedral` — they differ, so each keeps its own default.
impl Default for Cloth {
    fn default() -> Self {
        Cloth::new(
            16,
            16,
            0.2,
            Vec::new(),
            1.0e-5,
            1.0e-5,
            1.0e-5,
            ClothBendType::Distance,
        )
    }
}

impl Cloth {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        grid_size_x: i64,
        grid_size_z: i64,
        spacing: f32,
        fixed_vertex_indices: Vec<i64>,
        compliance: f32,
        shear_compliance: f32,
        bend_compliance: f32,
        bend_type: ClothBendType,
    ) -> Self {
        let grid_size_x = grid_size_x.clamp(2, 512);
        let grid_size_z = grid_size_z.clamp(2, 512);
        let spacing = spacing.max(0.001);
        let vertex_count = grid_size_x * grid_size_z;
        // Deduplicate, keep only in-range indices, then sort.
        let mut fixed: Vec<i64> = fixed_vertex_indices
            .into_iter()
            .filter(|index| *index >= 0 && *index < vertex_count)
            .collect();
        fixed.sort_unstable();
        fixed.dedup();
        Cloth {
            grid_size_x,
            grid_size_z,
            spacing,
            fixed_vertex_indices: fixed,
            compliance: compliance.max(0.0),
            shear_compliance: shear_compliance.max(0.0),
            bend_compliance: bend_compliance.max(0.0),
            bend_type,
        }
    }

    /// `static func fixedTopEdge`.
    pub fn fixed_top_edge(grid_size_x: i64, grid_size_z: i64, spacing: f32) -> Cloth {
        let width = grid_size_x.clamp(2, 512);
        Cloth::new(
            width,
            grid_size_z,
            spacing,
            (0..width).collect(),
            1.0e-5,
            1.0e-5,
            1.0e-5,
            ClothBendType::Distance,
        )
    }

    pub fn vertex_count(&self) -> i64 {
        self.grid_size_x * self.grid_size_z
    }

    pub fn triangle_index_count(&self) -> i64 {
        (self.grid_size_x - 1) * (self.grid_size_z - 1) * 6
    }

    /// Two triangles per grid cell, emitted in Swift's exact order.
    pub fn triangle_indices(&self) -> Vec<u32> {
        let mut result: Vec<u32> = Vec::with_capacity(self.triangle_index_count().max(0) as usize);
        for z in 0..(self.grid_size_z - 1) {
            for x in 0..(self.grid_size_x - 1) {
                let top_left = (x + z * self.grid_size_x) as u32;
                let bottom_left = (x + (z + 1) * self.grid_size_x) as u32;
                let bottom_right = (x + 1 + (z + 1) * self.grid_size_x) as u32;
                let top_right = (x + 1 + z * self.grid_size_x) as u32;
                result.extend_from_slice(&[
                    top_left,
                    bottom_left,
                    bottom_right,
                    top_left,
                    bottom_right,
                    top_right,
                ]);
            }
        }
        result
    }
}

impl crate::entity_id::RuntimeComponent for Cloth {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid_sizes_and_spacing_clamp() {
        let cloth = Cloth::new(
            0,
            10_000,
            0.0,
            Vec::new(),
            0.0,
            0.0,
            0.0,
            ClothBendType::None,
        );
        assert_eq!(cloth.grid_size_x, 2);
        assert_eq!(cloth.grid_size_z, 512);
        assert_eq!(cloth.spacing, 0.001);
    }

    #[test]
    fn fixed_indices_are_filtered_deduplicated_and_sorted() {
        let cloth = Cloth::new(
            4,
            4,
            0.2,
            vec![5, 1, 99, -3, 5, 1, 15],
            0.0,
            0.0,
            0.0,
            ClothBendType::None,
        );
        // vertex_count = 16, so 15 is in range and 99 is not.
        assert_eq!(cloth.fixed_vertex_indices, vec![1, 5, 15]);
    }

    #[test]
    fn negative_compliance_clamps_to_zero() {
        let cloth = Cloth::new(2, 2, 0.2, Vec::new(), -1.0, -2.0, -3.0, ClothBendType::None);
        assert_eq!(cloth.compliance, 0.0);
        assert_eq!(cloth.shear_compliance, 0.0);
        assert_eq!(cloth.bend_compliance, 0.0);
    }

    #[test]
    fn fixed_top_edge_fixes_first_row() {
        let cloth = Cloth::fixed_top_edge(5, 3, 0.2);
        assert_eq!(cloth.fixed_vertex_indices, vec![0, 1, 2, 3, 4]);
        assert_eq!(cloth.vertex_count(), 15);
    }

    #[test]
    fn triangle_layout_matches_swift_order() {
        let cloth = Cloth::new(2, 2, 0.2, Vec::new(), 0.0, 0.0, 0.0, ClothBendType::None);
        assert_eq!(cloth.triangle_index_count(), 6);
        // topLeft=0, bottomLeft=2, bottomRight=3, topRight=1
        assert_eq!(cloth.triangle_indices(), vec![0, 2, 3, 0, 3, 1]);
    }

    #[test]
    fn bend_type_persists_as_raw_value() {
        assert_eq!(ClothBendType::None.raw_value(), 0);
        assert_eq!(ClothBendType::Distance.raw_value(), 1);
        assert_eq!(ClothBendType::Dihedral.raw_value(), 2);
        assert_eq!(
            ClothBendType::from_raw_value(2),
            Some(ClothBendType::Dihedral)
        );
        assert_eq!(ClothBendType::from_raw_value(9), None);
    }
}
