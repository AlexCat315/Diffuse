//! Coplanar region dissolving across selected interior edges.
//!
//! Ported from `Engine/Sources/AssetPipeline/Geometry/PolygonDissolve.swift`.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::geometry::polygon_mesh::{
    GeometryError, GeometryLimits, PolygonEdgeUse, PolygonFace, PolygonMesh, PolygonMeshEdge,
};
use crate::geometry::polygon_triangulation::triangulate;

impl PolygonMesh {
    /// Merges connected coplanar face regions across selected interior edges.
    /// Regions with holes, material boundaries or incompatible UVs are rejected.
    /// Returns the merged face indices; failures leave the mesh unchanged.
    pub fn dissolve(
        &mut self,
        selection: &BTreeSet<PolygonMeshEdge>,
        limits: GeometryLimits,
    ) -> Result<BTreeSet<i64>, GeometryError> {
        self.validate(limits)?;
        let uses = self.edge_uses()?;
        if selection.is_empty()
            || !selection
                .iter()
                .all(|edge| uses.get(edge).map(|uses| uses.len()) == Some(2))
        {
            return Err(GeometryError::invalid_parameter(
                "dissolve requires interior edges",
            ));
        }
        let mut parents: Vec<usize> = (0..self.faces.len()).collect();
        fn root(parents: &mut [usize], index: usize) -> usize {
            let mut cursor = index;
            while parents[cursor] != cursor {
                parents[cursor] = parents[parents[cursor]];
                cursor = parents[cursor];
            }
            cursor
        }
        for edge in selection {
            let adjacent = &uses[edge];
            let a = root(&mut parents, adjacent[0].face as usize);
            let b = root(&mut parents, adjacent[1].face as usize);
            parents[a.max(b)] = a.min(b);
        }
        let mut groups: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
        for i in 0..self.faces.len() {
            let group_root = root(&mut parents, i);
            groups.entry(group_root).or_default().push(i);
        }
        // Swift sorts groups by their first face index, which the BTreeMap on the
        // (monotonically assigned) root does not guarantee; sort explicitly.
        let mut ordered: Vec<Vec<usize>> = groups.into_values().collect();
        ordered.sort_by_key(|group| group[0]);
        let mut result = PolygonMesh::new(self.positions.clone(), Vec::new());
        let mut merged: BTreeSet<i64> = BTreeSet::new();
        for group in ordered {
            if group.len() == 1 {
                result.faces.push(self.faces[group[0]].clone());
                continue;
            }
            merged.insert(result.faces.len() as i64);
            result.faces.push(self.dissolved_face(&group, &uses)?);
        }
        result = result.compacted();
        result.validate(limits)?;
        let _ = result.edge_uses()?;
        for face in &result.faces {
            let _ = triangulate(face, &result.positions)?;
        }
        *self = result;
        Ok(merged)
    }

    fn dissolved_face(
        &self,
        indices: &[usize],
        uses: &HashMap<PolygonMeshEdge, Vec<PolygonEdgeUse>>,
    ) -> Result<PolygonFace, GeometryError> {
        let region: BTreeSet<usize> = indices.iter().copied().collect();
        let uvs = self.dissolve_attributes(indices)?;
        let mut next: BTreeMap<i64, i64> = BTreeMap::new();
        let mut incoming: BTreeSet<i64> = BTreeSet::new();
        for index in indices {
            let vertices = &self.faces[*index].vertices;
            for i in 0..vertices.len() {
                let a = vertices[i];
                let b = vertices[(i + 1) % vertices.len()];
                let edge_uses = &uses[&PolygonMeshEdge::new(a, b)];
                if edge_uses.len() == 2
                    && edge_uses
                        .iter()
                        .all(|use_| region.contains(&(use_.face as usize)))
                {
                    continue;
                }
                if next.insert(a, b).is_some() || !incoming.insert(b) {
                    return Err(GeometryError::invalid_mesh(
                        "dissolve region has a branching boundary",
                    ));
                }
            }
        }
        let start = next.keys().next().copied();
        let (true, Some(start)) = ((3..=256).contains(&next.len()), start) else {
            return Err(GeometryError::invalid_mesh(
                "dissolve region has no supported polygon boundary",
            ));
        };
        let mut boundary: Vec<i64> = Vec::new();
        let mut visited: BTreeSet<i64> = BTreeSet::new();
        let mut cursor = start;
        while visited.insert(cursor) {
            boundary.push(cursor);
            let Some(successor) = next.get(&cursor) else {
                return Err(GeometryError::invalid_mesh("open dissolve boundary"));
            };
            cursor = *successor;
        }
        if cursor != start || visited.len() != next.len() {
            return Err(GeometryError::invalid_mesh(
                "dissolve region contains a hole or disconnected boundary",
            ));
        }
        Ok(PolygonFace::new(
            boundary.clone(),
            uvs.map(|values| {
                boundary
                    .iter()
                    .map(|vertex| values[vertex])
                    .collect::<Vec<_>>()
            }),
            self.faces[indices[0]].material_index,
        ))
    }
}
