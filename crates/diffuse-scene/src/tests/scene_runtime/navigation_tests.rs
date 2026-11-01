//! Ported from `Engine/Tests/SceneRuntimeTests/NavigationTests.swift`.
//!
//! Swift's `NavPathfinder.Cell` is `NavCell` in Rust and `simd_distance` lives in
//! `diffuse_math::simd::simd_compat`.

use diffuse_math::simd::simd_compat::{Float3, simd_distance};

use crate::scene_graph::navigation::{NavCell, NavGrid, NavPathfinder};

/// Straight path on an empty grid.
#[test]
fn straight_path() {
    let grid = NavGrid::new(5, 1);
    let path = NavPathfinder::find_path(&grid, NavCell::new(0, 0), NavCell::new(4, 0));
    assert_eq!(
        path,
        Some(vec![
            NavCell::new(0, 0),
            NavCell::new(1, 0),
            NavCell::new(2, 0),
            NavCell::new(3, 0),
            NavCell::new(4, 0),
        ])
    );
}

/// Start equals goal yields a single waypoint.
#[test]
fn start_equals_goal() {
    let grid = NavGrid::new(4, 4);
    assert_eq!(
        NavPathfinder::find_path(&grid, NavCell::new(2, 2), NavCell::new(2, 2)),
        Some(vec![NavCell::new(2, 2)])
    );
}

/// Path routes around a wall.
#[test]
fn routes_around_wall() {
    // 5x5 grid; vertical wall at x=2 for z=0..3, leaving a gap at z=4.
    let mut grid = NavGrid::new(5, 5);
    for z in 0..4 {
        grid.set_blocked(2, z, true);
    }
    let path =
        NavPathfinder::find_path(&grid, NavCell::new(0, 0), NavCell::new(4, 0)).expect("path");
    // No waypoint may sit on the wall.
    assert!(path.iter().all(|cell| !(cell.x == 2 && cell.z < 4)));
    // Must reach through the gap row.
    assert!(path.iter().any(|cell| cell.z == 4));
}

/// Blocked goal or start is unreachable.
#[test]
fn blocked_endpoints() {
    let mut grid = NavGrid::new(4, 4);
    grid.set_blocked(3, 3, true);
    assert_eq!(
        NavPathfinder::find_path(&grid, NavCell::new(0, 0), NavCell::new(3, 3)),
        None
    );
    assert_eq!(
        NavPathfinder::find_path(&grid, NavCell::new(3, 3), NavCell::new(0, 0)),
        None
    );
}

/// Fully walled-off goal returns `None`.
#[test]
fn unreachable_goal() {
    let mut grid = NavGrid::new(5, 5);
    // Enclose cell (4,4) on its two interior sides.
    grid.set_blocked(3, 4, true);
    grid.set_blocked(4, 3, true);
    grid.set_blocked(3, 3, true); // block the diagonal corner too
    assert_eq!(
        NavPathfinder::find_path(&grid, NavCell::new(0, 0), NavCell::new(4, 4)),
        None
    );
}

/// Diagonals never cut blocked corners.
#[test]
fn no_corner_cutting() {
    // Block (1,0) and (0,1); the diagonal (0,0)->(1,1) must not be taken directly.
    let mut grid = NavGrid::new(2, 2);
    grid.set_blocked(1, 0, true);
    grid.set_blocked(0, 1, true);
    // (1,1) is now isolated from (0,0): all routes pass through a blocked cell.
    assert_eq!(
        NavPathfinder::find_path(&grid, NavCell::new(0, 0), NavCell::new(1, 1)),
        None
    );
}

/// Diagonal search produces a shorter route than orthogonal-only.
#[test]
fn diagonal_shorter_than_orthogonal() {
    let grid = NavGrid::new(5, 5);
    let diagonal = NavPathfinder::find_path_with_diagonals(
        &grid,
        NavCell::new(0, 0),
        NavCell::new(4, 4),
        true,
    );
    let orthogonal = NavPathfinder::find_path_with_diagonals(
        &grid,
        NavCell::new(0, 0),
        NavCell::new(4, 4),
        false,
    );
    assert!(diagonal.is_some() && orthogonal.is_some());
    // Pure diagonal: 5 cells including both endpoints.
    assert_eq!(diagonal.map(|path| path.len()), Some(5));
    // Manhattan staircase: 9 cells.
    assert_eq!(orthogonal.map(|path| path.len()), Some(9));
}

/// World-space mapping round-trips through cell centers.
#[test]
fn world_space_mapping() {
    let grid = NavGrid::with_cell_size_origin(10, 10, 2.0, Float3::new(-10.0, 0.0, -10.0));
    let path = NavPathfinder::find_path_world(
        &grid,
        // Cell (0,0).
        Float3::new(-9.0, 0.0, -9.0),
        // Cell (9,9).
        Float3::new(8.5, 0.0, 8.5),
    )
    .expect("path");
    // First waypoint is the center of cell (0,0): origin + 0.5*cellSize.
    assert!(
        simd_distance(
            *path.first().expect("first waypoint"),
            Float3::new(-9.0, 0.0, -9.0)
        ) < 1e-4
    );
    assert!(
        simd_distance(
            *path.last().expect("last waypoint"),
            Float3::new(9.0, 0.0, 9.0)
        ) < 1e-4
    );
}

/// Points outside the grid return `None`.
#[test]
fn outside_grid() {
    let grid = NavGrid::with_cell_size_origin(4, 4, 1.0, Float3::ZERO);
    assert_eq!(grid.cell_at(Float3::new(-1.0, 0.0, 0.0)), None);
    assert_eq!(grid.cell_at(Float3::new(100.0, 0.0, 0.0)), None);
    assert_eq!(
        NavPathfinder::find_path_world(
            &grid,
            Float3::new(-5.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 1.0)
        ),
        None
    );
}
