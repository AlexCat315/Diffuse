//! Uniform XZ navigation grid and A* pathfinding.
//!
//! Ported from `SceneRuntime/SceneGraph/Navigation.swift`. Cell `(0, 0)` starts
//! at `origin` (its minimum corner), each cell is `cell_size` on a side, and Y
//! is up. Cells are walkable by default and can be blocked individually.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_math::simd::simd_compat::Float3;

/// A uniform navigation grid laid out on the XZ plane.
#[derive(Clone, Debug, PartialEq)]
pub struct NavGrid {
    /// Cell count along +X.
    pub width: i64,
    /// Cell count along +Z.
    pub depth: i64,
    pub cell_size: f32,
    pub origin: Float3,
    blocked: Vec<bool>,
}

impl NavGrid {
    /// `init(width:depth:)` — unit cells at the origin.
    pub fn new(width: i64, depth: i64) -> Self {
        NavGrid::with_cell_size_origin(width, depth, 1.0, Float3::ZERO)
    }

    /// `init(width:depth:cellSize:origin:)`.
    pub fn with_cell_size_origin(
        width: i64,
        depth: i64,
        cell_size: f32,
        origin: Float3,
    ) -> Self {
        let width = width.max(0);
        let depth = depth.max(0);
        let cell_size = if cell_size > 0.0 { cell_size } else { 1.0 };
        NavGrid {
            width,
            depth,
            cell_size,
            origin,
            blocked: vec![false; (width * depth) as usize],
        }
    }

    pub fn cell_count(&self) -> i64 {
        self.width * self.depth
    }

    pub fn in_bounds(&self, x: i64, z: i64) -> bool {
        x >= 0 && x < self.width && z >= 0 && z < self.depth
    }

    pub fn is_walkable(&self, x: i64, z: i64) -> bool {
        self.in_bounds(x, z) && !self.blocked[(z * self.width + x) as usize]
    }

    /// `setBlocked(x:z:_:)` — out-of-bounds writes are ignored.
    pub fn set_blocked(&mut self, x: i64, z: i64, value: bool) {
        if !self.in_bounds(x, z) {
            return;
        }
        self.blocked[(z * self.width + x) as usize] = value;
    }

    /// Blocks the cell containing `world_position`, if it falls inside the grid.
    pub fn block_cell(&mut self, world_position: Float3) {
        if let Some((x, z)) = self.cell_at(world_position) {
            self.set_blocked(x, z, true);
        }
    }

    /// World-space center of cell `(x, z)`. Y matches the grid origin.
    pub fn cell_center(&self, x: i64, z: i64) -> Float3 {
        Float3::new(
            self.origin.x + (x as f32 + 0.5) * self.cell_size,
            self.origin.y,
            self.origin.z + (z as f32 + 0.5) * self.cell_size,
        )
    }

    /// Cell containing `world_position`, or `None` when it lies outside the grid.
    ///
    /// Only XZ participates, exactly as in Swift.
    pub fn cell_at(&self, world_position: Float3) -> Option<(i64, i64)> {
        let lx = world_position.x - self.origin.x;
        let lz = world_position.z - self.origin.z;
        if !(lx >= 0.0 && lz >= 0.0) {
            return None;
        }
        let cx = (lx / self.cell_size) as i64;
        let cz = (lz / self.cell_size) as i64;
        if self.in_bounds(cx, cz) {
            Some((cx, cz))
        } else {
            None
        }
    }
}

/// One navigation grid cell.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct NavCell {
    pub x: i64,
    pub z: i64,
}

impl NavCell {
    /// `init(_:_:)`.
    pub fn new(x: i64, z: i64) -> Self {
        NavCell { x, z }
    }
}

/// A* pathfinding over a [`NavGrid`].
pub struct NavPathfinder;

impl NavPathfinder {

    /// Finds a path between two grid cells, allowing diagonal moves.
    ///
    /// Returns the cell sequence from `start` to `goal` inclusive, or `None`
    /// if either cell is blocked/out of bounds or no route exists.
    #[inline]
    pub fn find_path(grid: &NavGrid, start: NavCell, goal: NavCell) -> Option<Vec<NavCell>> {
        NavPathfinder::find_path_with_diagonals(grid, start, goal, true)
    }

    /// `findPath(in:from:to:allowDiagonal:)`.
    ///
    /// Diagonal moves never cut blocked corners: both shared orthogonal cells
    /// must be walkable.
    pub fn find_path_with_diagonals(
        grid: &NavGrid,
        start: NavCell,
        goal: NavCell,
        allow_diagonal: bool,
    ) -> Option<Vec<NavCell>> {
        if !grid.is_walkable(start.x, start.z) || !grid.is_walkable(goal.x, goal.z) {
            return None;
        }
        if start == goal {
            return Some(vec![start]);
        }

        let sqrt2: f32 = 1.41421356;
        let mut g_score: BTreeMap<NavCell, f32> = BTreeMap::new();
        g_score.insert(start, 0.0);
        let mut came_from: BTreeMap<NavCell, NavCell> = BTreeMap::new();
        let mut open = MinHeap::new();
        open.push(start, heuristic(start, goal, allow_diagonal));
        let mut closed: BTreeSet<NavCell> = BTreeSet::new();

        while let Some(current) = open.pop() {
            if current == goal {
                return Some(reconstruct(&came_from, goal));
            }
            if closed.contains(&current) {
                continue;
            }
            closed.insert(current);

            let base_g = g_score.get(&current).copied().unwrap_or(f32::MAX);
            for (neighbor, diagonal) in neighbors(&current, grid, allow_diagonal) {
                if closed.contains(&neighbor) {
                    continue;
                }
                let tentative = base_g + if diagonal { sqrt2 } else { 1.0 };
                if tentative < g_score.get(&neighbor).copied().unwrap_or(f32::MAX) {
                    g_score.insert(neighbor, tentative);
                    came_from.insert(neighbor, current);
                    open.push(
                        neighbor,
                        tentative + heuristic(neighbor, goal, allow_diagonal),
                    );
                }
            }
        }
        None
    }

    /// World-space convenience: resolves `from`/`to` to cells and returns the
    /// path as cell-center waypoints.
    #[inline]
    pub fn find_path_world(grid: &NavGrid, from: Float3, to: Float3) -> Option<Vec<Float3>> {
        NavPathfinder::find_path_world_with_diagonals(grid, from, to, true)
    }

    /// `findPath(in:from:to:allowDiagonal:)` for world positions.
    pub fn find_path_world_with_diagonals(
        grid: &NavGrid,
        from: Float3,
        to: Float3,
        allow_diagonal: bool,
    ) -> Option<Vec<Float3>> {
        let (sx, sz) = grid.cell_at(from)?;
        let (gx, gz) = grid.cell_at(to)?;
        let cells = NavPathfinder::find_path_with_diagonals(
            grid,
            NavCell::new(sx, sz),
            NavCell::new(gx, gz),
            allow_diagonal,
        )?;
        Some(
            cells
                .into_iter()
                .map(|cell| grid.cell_center(cell.x, cell.z))
                .collect(),
        )
    }
}

/// Octile distance (admissible for 8-connected grids) or Manhattan distance.
fn heuristic(a: NavCell, b: NavCell, allow_diagonal: bool) -> f32 {
    let dx = (a.x - b.x).abs();
    let dz = (a.z - b.z).abs();
    if allow_diagonal {
        let m = dx.min(dz);
        (dx + dz) as f32 + (1.41421356_f32 - 2.0) * m as f32
    } else {
        (dx + dz) as f32
    }
}

fn neighbors(c: &NavCell, grid: &NavGrid, allow_diagonal: bool) -> Vec<(NavCell, bool)> {
    let mut result: Vec<(NavCell, bool)> = Vec::new();
    let orthogonal = [(1_i64, 0_i64), (-1, 0), (0, 1), (0, -1)];
    for (dx, dz) in orthogonal {
        if grid.is_walkable(c.x + dx, c.z + dz) {
            result.push((NavCell::new(c.x + dx, c.z + dz), false));
        }
    }
    if !allow_diagonal {
        return result;
    }
    let diagonal = [(1_i64, 1_i64), (1, -1), (-1, 1), (-1, -1)];
    for (dx, dz) in diagonal {
        if grid.is_walkable(c.x + dx, c.z + dz) {
            // No corner cutting: both shared orthogonal cells must be open.
            if grid.is_walkable(c.x + dx, c.z) && grid.is_walkable(c.x, c.z + dz) {
                result.push((NavCell::new(c.x + dx, c.z + dz), true));
            }
        }
    }
    result
}

fn reconstruct(came_from: &BTreeMap<NavCell, NavCell>, goal: NavCell) -> Vec<NavCell> {
    let mut path = vec![goal];
    let mut node = goal;
    while let Some(previous) = came_from.get(&node) {
        path.push(*previous);
        node = *previous;
    }
    path.reverse();
    path
}

/// Minimal binary min-heap keyed by priority. Stale entries (a cell pushed
/// again with a lower priority) are tolerated via the `closed` set.
struct MinHeap {
    items: Vec<(NavCell, f32)>,
}

impl MinHeap {
    fn new() -> Self {
        MinHeap { items: Vec::new() }
    }

    fn push(&mut self, cell: NavCell, priority: f32) {
        self.items.push((cell, priority));
        self.sift_up(self.items.len() - 1);
    }

    fn pop(&mut self) -> Option<NavCell> {
        if self.items.is_empty() {
            return None;
        }
        let last = self.items.len() - 1;
        self.items.swap(0, last);
        let top = self.items.pop()?;
        if !self.items.is_empty() {
            self.sift_down(0);
        }
        Some(top.0)
    }

    fn sift_up(&mut self, index: usize) {
        let mut i = index;
        while i > 0 {
            let parent = (i - 1) / 2;
            if self.items[i].1 >= self.items[parent].1 {
                break;
            }
            self.items.swap(i, parent);
            i = parent;
        }
    }

    fn sift_down(&mut self, index: usize) {
        let mut i = index;
        let count = self.items.len();
        loop {
            let left = 2 * i + 1;
            let right = 2 * i + 2;
            let mut smallest = i;
            if left < count && self.items[left].1 < self.items[smallest].1 {
                smallest = left;
            }
            if right < count && self.items[right].1 < self.items[smallest].1 {
                smallest = right;
            }
            if smallest == i {
                break;
            }
            self.items.swap(i, smallest);
            i = smallest;
        }
    }
}
