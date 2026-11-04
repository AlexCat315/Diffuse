//! Import-time baking of closed prefractured meshes and their connection graph.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_math::simd::simd_compat::{
    Float3, Float4, mul_4x4_float4, simd_cross, simd_dot, simd_length_squared,
};
use diffuse_scene::physics::destruction::{
    DestructibleAsset, DestructibleAssetResource, DestructibleConnectionAsset,
    DestructibleFragmentAsset,
};
use diffuse_scene::physics::queries::spatial_queries::{
    MeshColliderGeometry, MeshColliderGeometryResource,
};
use diffuse_scene::rendering::render_extraction::{RenderMaterialComponent, RenderMeshComponent};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;

#[derive(Clone, Debug, PartialEq)]
pub struct PrefracturedFragmentInput {
    pub fragment_id: u32,
    pub positions: Vec<Float3>,
    pub triangle_indices: Vec<u32>,
    pub local_transform: LocalTransform,
    pub density: f32,
    pub geometry_revision: u64,
    pub render_mesh: Option<RenderMeshComponent>,
    pub render_material: Option<RenderMaterialComponent>,
}

impl PrefracturedFragmentInput {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        fragment_id: u32,
        positions: Vec<Float3>,
        triangle_indices: Vec<u32>,
        local_transform: LocalTransform,
        density: f32,
        geometry_revision: u64,
        render_mesh: Option<RenderMeshComponent>,
        render_material: Option<RenderMaterialComponent>,
    ) -> Self {
        Self {
            fragment_id,
            positions,
            triangle_indices,
            local_transform,
            density,
            geometry_revision,
            render_mesh,
            render_material,
        }
    }

    pub fn with_geometry(
        fragment_id: u32,
        positions: Vec<Float3>,
        triangle_indices: Vec<u32>,
    ) -> Self {
        Self::new(
            fragment_id,
            positions,
            triangle_indices,
            LocalTransform::IDENTITY,
            1.0,
            0,
            None,
            None,
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum DestructibleAssetBakeError {
    #[error("empty asset resource ID")]
    EmptyAssetResourceID,
    #[error("no fragments")]
    NoFragments,
    #[error("duplicate fragment ID: {0}")]
    DuplicateFragmentID(u32),
    #[error("invalid density for fragment {fragment_id}")]
    InvalidDensity { fragment_id: u32 },
    #[error("invalid geometry for fragment {fragment_id}")]
    InvalidGeometry { fragment_id: u32 },
    #[error("non-closed geometry for fragment {fragment_id}")]
    NonClosedGeometry { fragment_id: u32 },
    #[error("duplicate connection ID: {0}")]
    DuplicateConnectionID(u32),
    #[error("invalid connection {connection_id}")]
    InvalidConnection { connection_id: u32 },
    #[error("disconnected connection graph: {fragment_ids:?}")]
    DisconnectedConnectionGraph { fragment_ids: Vec<u32> },
    #[error("invalid connection tolerance")]
    InvalidConnectionTolerance,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DestructibleAssetBakeResult {
    pub asset_resource_id: String,
    pub asset: DestructibleAsset,
    pub geometry_by_resource_id: BTreeMap<String, MeshColliderGeometry>,
}

impl DestructibleAssetBakeResult {
    pub fn new(
        asset_resource_id: impl Into<String>,
        asset: DestructibleAsset,
        geometry_by_resource_id: BTreeMap<String, MeshColliderGeometry>,
    ) -> Self {
        Self {
            asset_resource_id: asset_resource_id.into(),
            asset,
            geometry_by_resource_id,
        }
    }

    /// Replaces this asset's owned geometry while retaining unrelated resources.
    pub fn install(&self, runtime: &mut SceneRuntime) {
        let mut assets = runtime
            .resource::<DestructibleAssetResource>()
            .unwrap_or_default();
        let mut geometries = runtime
            .resource::<MeshColliderGeometryResource>()
            .unwrap_or_default();
        if let Some(previous) = assets.assets_by_resource_id.get(&self.asset_resource_id) {
            let owned_prefix = format!("{}#convex:", self.asset_resource_id);
            for fragment in &previous.fragments {
                if fragment.collider_resource_id.starts_with(&owned_prefix)
                    && !self
                        .geometry_by_resource_id
                        .contains_key(&fragment.collider_resource_id)
                {
                    geometries
                        .geometry_by_resource_id
                        .remove(&fragment.collider_resource_id);
                }
            }
        }
        for (resource_id, geometry) in &self.geometry_by_resource_id {
            geometries
                .geometry_by_resource_id
                .insert(resource_id.clone(), geometry.clone());
        }
        runtime.set_resource(geometries);
        assets
            .assets_by_resource_id
            .insert(self.asset_resource_id.clone(), self.asset.clone());
        runtime.set_resource(assets);
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DestructibleAssetBaker;

impl DestructibleAssetBaker {
    pub fn new() -> Self {
        Self
    }

    pub fn bake(
        &self,
        asset_resource_id: &str,
        revision: u64,
        fragments: &[PrefracturedFragmentInput],
        connections: &[DestructibleConnectionAsset],
        automatically_generate_connections: bool,
        connection_tolerance: f32,
    ) -> Result<DestructibleAssetBakeResult, DestructibleAssetBakeError> {
        if asset_resource_id.is_empty() {
            return Err(DestructibleAssetBakeError::EmptyAssetResourceID);
        }
        if fragments.is_empty() {
            return Err(DestructibleAssetBakeError::NoFragments);
        }
        let mut seen_fragment_ids = BTreeSet::new();
        let mut baked_fragments = Vec::with_capacity(fragments.len());
        let mut geometries = BTreeMap::new();
        let mut sorted_fragments: Vec<_> = fragments.iter().collect();
        sorted_fragments.sort_by_key(|input| input.fragment_id);
        for input in sorted_fragments {
            if !seen_fragment_ids.insert(input.fragment_id) {
                return Err(DestructibleAssetBakeError::DuplicateFragmentID(
                    input.fragment_id,
                ));
            }
            if !input.density.is_finite() || input.density <= 0.0 {
                return Err(DestructibleAssetBakeError::InvalidDensity {
                    fragment_id: input.fragment_id,
                });
            }
            if !self.is_valid_geometry(input) {
                return Err(DestructibleAssetBakeError::InvalidGeometry {
                    fragment_id: input.fragment_id,
                });
            }
            let volume = self.signed_mesh_volume(&input.positions, &input.triangle_indices);
            if !self.is_closed_triangle_mesh(&input.triangle_indices)
                || !volume.is_finite()
                || volume <= 1.0e-8
            {
                return Err(DestructibleAssetBakeError::NonClosedGeometry {
                    fragment_id: input.fragment_id,
                });
            }
            let geometry_resource_id =
                Self::geometry_resource_id(asset_resource_id, input.fragment_id);
            geometries.insert(
                geometry_resource_id.clone(),
                MeshColliderGeometry::new(
                    input.positions.clone(),
                    input.triangle_indices.clone(),
                    Vec::new(),
                    Vec::new(),
                    None,
                    input.geometry_revision,
                ),
            );
            baked_fragments.push(DestructibleFragmentAsset::new(
                input.fragment_id,
                geometry_resource_id,
                input.local_transform,
                volume * input.density,
                input.render_mesh.clone(),
                input.render_material.clone(),
            ));
        }
        let final_connections = if connections.is_empty() && automatically_generate_connections {
            if !connection_tolerance.is_finite() || connection_tolerance < 0.0 {
                return Err(DestructibleAssetBakeError::InvalidConnectionTolerance);
            }
            self.generate_connections(fragments, connection_tolerance)
        } else {
            connections.to_vec()
        };
        let fragment_ids: BTreeSet<_> = baked_fragments.iter().map(|f| f.fragment_id).collect();
        let mut seen_connection_ids = BTreeSet::new();
        for connection in &final_connections {
            if !seen_connection_ids.insert(connection.connection_id) {
                return Err(DestructibleAssetBakeError::DuplicateConnectionID(
                    connection.connection_id,
                ));
            }
            if connection.fragment_a == connection.fragment_b
                || !fragment_ids.contains(&connection.fragment_a)
                || !fragment_ids.contains(&connection.fragment_b)
                || !connection.damage_threshold.is_finite()
                || connection.damage_threshold < 0.0
                || !connection.impulse_threshold.is_finite()
                || connection.impulse_threshold < 0.0
            {
                return Err(DestructibleAssetBakeError::InvalidConnection {
                    connection_id: connection.connection_id,
                });
            }
        }
        if !final_connections.is_empty() {
            let disconnected = self.disconnected_fragment_ids(
                &baked_fragments
                    .iter()
                    .map(|f| f.fragment_id)
                    .collect::<Vec<_>>(),
                &final_connections,
            );
            if !disconnected.is_empty() {
                return Err(DestructibleAssetBakeError::DisconnectedConnectionGraph {
                    fragment_ids: disconnected,
                });
            }
        }
        Ok(DestructibleAssetBakeResult::new(
            asset_resource_id,
            DestructibleAsset::new(revision, baked_fragments, final_connections),
            geometries,
        ))
    }

    /// Swift defaults: revision 0, automatic connections, tolerance 0.001.
    pub fn bake_fragments(
        &self,
        asset_resource_id: &str,
        fragments: &[PrefracturedFragmentInput],
    ) -> Result<DestructibleAssetBakeResult, DestructibleAssetBakeError> {
        self.bake(asset_resource_id, 0, fragments, &[], true, 0.001)
    }

    pub fn geometry_resource_id(asset_resource_id: &str, fragment_id: u32) -> String {
        format!("{asset_resource_id}#convex:{fragment_id}")
    }

    fn is_valid_geometry(&self, input: &PrefracturedFragmentInput) -> bool {
        if input.positions.len() < 4
            || input.triangle_indices.is_empty()
            || !input.triangle_indices.len().is_multiple_of(3)
            || !input
                .local_transform
                .matrix
                .columns
                .iter()
                .all(|c| c.x.is_finite() && c.y.is_finite() && c.z.is_finite() && c.w.is_finite())
            || !input
                .positions
                .iter()
                .all(|p| p.x.is_finite() && p.y.is_finite() && p.z.is_finite())
        {
            return false;
        }
        if !input
            .triangle_indices
            .iter()
            .all(|&index| (index as usize) < input.positions.len())
        {
            return false;
        }
        for triangle in input.triangle_indices.as_chunks::<3>().0 {
            let (a, b, c) = (triangle[0], triangle[1], triangle[2]);
            if a == b || b == c || c == a {
                return false;
            }
            let edge_ab = input.positions[b as usize] - input.positions[a as usize];
            let edge_ac = input.positions[c as usize] - input.positions[a as usize];
            // A failed ordered comparison also rejects NaN, as Swift's guard does.
            if simd_length_squared(simd_cross(edge_ab, edge_ac)).partial_cmp(&1.0e-12)
                != Some(std::cmp::Ordering::Greater)
            {
                return false;
            }
        }
        true
    }

    fn is_closed_triangle_mesh(&self, triangle_indices: &[u32]) -> bool {
        let mut edges: BTreeMap<u64, (i64, i64)> = BTreeMap::new();
        for triangle in triangle_indices.as_chunks::<3>().0 {
            for edge_index in 0..3 {
                let start = triangle[edge_index];
                let end = triangle[(edge_index + 1) % 3];
                let key = (u64::from(start.min(end)) << 32) | u64::from(start.max(end));
                let edge = edges.entry(key).or_default();
                edge.0 += 1;
                edge.1 += if start < end { 1 } else { -1 };
            }
        }
        !edges.is_empty()
            && edges
                .values()
                .all(|&(count, orientation)| count == 2 && orientation == 0)
    }

    fn signed_mesh_volume(&self, positions: &[Float3], triangle_indices: &[u32]) -> f32 {
        let mut signed_six_volume = 0.0_f64;
        for triangle in triangle_indices.as_chunks::<3>().0 {
            let a = positions[triangle[0] as usize];
            let b = positions[triangle[1] as usize];
            let c = positions[triangle[2] as usize];
            signed_six_volume += f64::from(simd_dot(a, simd_cross(b, c)));
        }
        (signed_six_volume.abs() / 6.0) as f32
    }

    fn generate_connections(
        &self,
        fragments: &[PrefracturedFragmentInput],
        tolerance: f32,
    ) -> Vec<DestructibleConnectionAsset> {
        struct Surface<'a> {
            fragment_id: u32,
            positions: Vec<Float3>,
            triangle_indices: &'a [u32],
            minimum: Float3,
            maximum: Float3,
        }
        let mut sorted: Vec<_> = fragments.iter().collect();
        sorted.sort_by_key(|f| f.fragment_id);
        let surfaces: Vec<_> = sorted
            .into_iter()
            .map(|fragment| {
                let positions: Vec<_> = fragment
                    .positions
                    .iter()
                    .map(|p| {
                        mul_4x4_float4(
                            fragment.local_transform.matrix,
                            Float4::new(p.x, p.y, p.z, 1.0),
                        )
                        .xyz()
                    })
                    .collect();
                let mut minimum = Float3::splat(f32::MAX);
                let mut maximum = Float3::splat(-f32::MAX);
                for position in &positions {
                    minimum = Float3::new(
                        swift_min(minimum.x, position.x),
                        swift_min(minimum.y, position.y),
                        swift_min(minimum.z, position.z),
                    );
                    maximum = Float3::new(
                        swift_max(maximum.x, position.x),
                        swift_max(maximum.y, position.y),
                        swift_max(maximum.z, position.z),
                    );
                }
                Surface {
                    fragment_id: fragment.fragment_id,
                    positions,
                    triangle_indices: &fragment.triangle_indices,
                    minimum,
                    maximum,
                }
            })
            .collect();
        let mut result = Vec::new();
        for first_index in 0..surfaces.len() {
            if first_index + 1 >= surfaces.len() {
                continue;
            }
            for second_index in (first_index + 1)..surfaces.len() {
                let first = &surfaces[first_index];
                let second = &surfaces[second_index];
                if self.aabb_squared_distance(
                    first.minimum,
                    first.maximum,
                    second.minimum,
                    second.maximum,
                ) <= tolerance * tolerance
                    && self.surfaces_are_adjacent(
                        &first.positions,
                        first.triangle_indices,
                        &second.positions,
                        second.triangle_indices,
                        tolerance * tolerance,
                    )
                {
                    result.push(DestructibleConnectionAsset::unthresholded(
                        u32::try_from(result.len()).expect("connection count exceeds UInt32"),
                        first.fragment_id,
                        second.fragment_id,
                    ));
                }
            }
        }
        result
    }

    fn aabb_squared_distance(
        &self,
        min_a: Float3,
        max_a: Float3,
        min_b: Float3,
        max_b: Float3,
    ) -> f32 {
        let separation = Float3::new(
            swift_max(0.0, swift_max(min_a.x - max_b.x, min_b.x - max_a.x)),
            swift_max(0.0, swift_max(min_a.y - max_b.y, min_b.y - max_a.y)),
            swift_max(0.0, swift_max(min_a.z - max_b.z, min_b.z - max_a.z)),
        );
        simd_length_squared(separation)
    }

    fn disconnected_fragment_ids(
        &self,
        fragment_ids: &[u32],
        connections: &[DestructibleConnectionAsset],
    ) -> Vec<u32> {
        let Some(&root) = fragment_ids.iter().min() else {
            return Vec::new();
        };
        let mut adjacency: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
        let mut sorted: Vec<_> = connections.iter().collect();
        sorted.sort_by_key(|c| c.connection_id);
        for connection in sorted {
            adjacency
                .entry(connection.fragment_a)
                .or_default()
                .push(connection.fragment_b);
            adjacency
                .entry(connection.fragment_b)
                .or_default()
                .push(connection.fragment_a);
        }
        let mut visited = BTreeSet::from([root]);
        let mut queue = vec![root];
        let mut index = 0;
        while index < queue.len() {
            let current = queue[index];
            index += 1;
            let mut neighbors = adjacency.get(&current).cloned().unwrap_or_default();
            neighbors.sort();
            for neighbor in neighbors {
                if visited.insert(neighbor) {
                    queue.push(neighbor);
                }
            }
        }
        let mut sorted_ids = fragment_ids.to_vec();
        sorted_ids.sort();
        sorted_ids
            .into_iter()
            .filter(|id| !visited.contains(id))
            .collect()
    }

    fn surfaces_are_adjacent(
        &self,
        positions_a: &[Float3],
        triangles_a: &[u32],
        positions_b: &[Float3],
        triangles_b: &[u32],
        tolerance_squared: f32,
    ) -> bool {
        self.points(positions_a, tolerance_squared, positions_b, triangles_b)
            || self.points(positions_b, tolerance_squared, positions_a, triangles_a)
    }

    fn points(
        &self,
        points: &[Float3],
        tolerance_squared: f32,
        positions: &[Float3],
        triangle_indices: &[u32],
    ) -> bool {
        for &point in points {
            for triangle in triangle_indices.as_chunks::<3>().0 {
                let a = positions[triangle[0] as usize];
                let b = positions[triangle[1] as usize];
                let c = positions[triangle[2] as usize];
                if self.point_triangle_squared_distance(point, a, b, c) <= tolerance_squared {
                    return true;
                }
            }
        }
        false
    }

    fn point_triangle_squared_distance(
        &self,
        point: Float3,
        a: Float3,
        b: Float3,
        c: Float3,
    ) -> f32 {
        let ab = b - a;
        let ac = c - a;
        let ap = point - a;
        let d1 = simd_dot(ab, ap);
        let d2 = simd_dot(ac, ap);
        if d1 <= 0.0 && d2 <= 0.0 {
            return simd_length_squared(ap);
        }
        let bp = point - b;
        let d3 = simd_dot(ab, bp);
        let d4 = simd_dot(ac, bp);
        if d3 >= 0.0 && d4 <= d3 {
            return simd_length_squared(bp);
        }
        let vc = d1 * d4 - d3 * d2;
        if vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0 {
            let v = d1 / (d1 - d3);
            return simd_length_squared(point - (a + v * ab));
        }
        let cp = point - c;
        let d5 = simd_dot(ab, cp);
        let d6 = simd_dot(ac, cp);
        if d6 >= 0.0 && d5 <= d6 {
            return simd_length_squared(cp);
        }
        let vb = d5 * d2 - d1 * d6;
        if vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0 {
            let w = d2 / (d2 - d6);
            return simd_length_squared(point - (a + w * ac));
        }
        let va = d3 * d6 - d5 * d4;
        if va <= 0.0 && d4 - d3 >= 0.0 && d5 - d6 >= 0.0 {
            let edge = c - b;
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
            return simd_length_squared(point - (b + w * edge));
        }
        let denominator = 1.0 / (va + vb + vc);
        let v = vb * denominator;
        let w = vc * denominator;
        simd_length_squared(point - (a + ab * v + ac * w))
    }
}

// Swift's generic min/max retain the first operand for unordered comparisons.
fn swift_min(a: f32, b: f32) -> f32 {
    if b < a { b } else { a }
}

fn swift_max(a: f32, b: f32) -> f32 {
    if b >= a { b } else { a }
}
