import SceneRuntime
import Testing
import Foundation
import SIMDCompat

@Suite("Navigation")
struct NavigationTests {
    typealias Cell = NavPathfinder.Cell

    @Test("straight path on an empty grid")
    func straightPath() {
        let grid = NavGrid(width: 5, depth: 1)
        let path = NavPathfinder.findPath(in: grid, from: Cell(0, 0), to: Cell(4, 0))
        #expect(path == [Cell(0, 0), Cell(1, 0), Cell(2, 0), Cell(3, 0), Cell(4, 0)])
    }

    @Test("start equals goal yields a single waypoint")
    func startEqualsGoal() {
        let grid = NavGrid(width: 4, depth: 4)
        #expect(NavPathfinder.findPath(in: grid, from: Cell(2, 2), to: Cell(2, 2)) == [Cell(2, 2)])
    }

    @Test("path routes around a wall")
    func routesAroundWall() {
        // 5x5 grid; vertical wall at x=2 for z=0..3, leaving a gap at z=4.
        var grid = NavGrid(width: 5, depth: 5)
        for z in 0..<4 { grid.setBlocked(x: 2, z: z) }
        let path = NavPathfinder.findPath(in: grid, from: Cell(0, 0), to: Cell(4, 0))
        #expect(path != nil)
        // No waypoint may sit on the wall.
        #expect(path!.allSatisfy { !($0.x == 2 && $0.z < 4) })
        // Must reach through the gap row.
        #expect(path!.contains { $0.z == 4 })
    }

    @Test("blocked goal or start is unreachable")
    func blockedEndpoints() {
        var grid = NavGrid(width: 4, depth: 4)
        grid.setBlocked(x: 3, z: 3)
        #expect(NavPathfinder.findPath(in: grid, from: Cell(0, 0), to: Cell(3, 3)) == nil)
        #expect(NavPathfinder.findPath(in: grid, from: Cell(3, 3), to: Cell(0, 0)) == nil)
    }

    @Test("fully walled-off goal returns nil")
    func unreachableGoal() {
        var grid = NavGrid(width: 5, depth: 5)
        // Enclose cell (4,4) on its two interior sides.
        grid.setBlocked(x: 3, z: 4)
        grid.setBlocked(x: 4, z: 3)
        grid.setBlocked(x: 3, z: 3) // block the diagonal corner too
        #expect(NavPathfinder.findPath(in: grid, from: Cell(0, 0), to: Cell(4, 4)) == nil)
    }

    @Test("diagonals never cut blocked corners")
    func noCornerCutting() {
        // Block (1,0) and (0,1); the diagonal (0,0)->(1,1) must not be taken directly.
        var grid = NavGrid(width: 2, depth: 2)
        grid.setBlocked(x: 1, z: 0)
        grid.setBlocked(x: 0, z: 1)
        // (1,1) is now isolated from (0,0): all routes pass through a blocked cell.
        #expect(NavPathfinder.findPath(in: grid, from: Cell(0, 0), to: Cell(1, 1)) == nil)
    }

    @Test("diagonal search produces a shorter route than orthogonal-only")
    func diagonalShorterThanOrthogonal() {
        let grid = NavGrid(width: 5, depth: 5)
        let diag = NavPathfinder.findPath(in: grid, from: Cell(0, 0), to: Cell(4, 4), allowDiagonal: true)
        let ortho = NavPathfinder.findPath(in: grid, from: Cell(0, 0), to: Cell(4, 4), allowDiagonal: false)
        #expect(diag != nil && ortho != nil)
        #expect(diag!.count == 5)   // pure diagonal: 5 cells incl. endpoints
        #expect(ortho!.count == 9)  // manhattan staircase: 9 cells
    }

    @Test("world-space mapping round-trips through cell centers")
    func worldSpaceMapping() {
        let grid = NavGrid(width: 10, depth: 10, cellSize: 2, origin: SIMD3<Float>(-10, 0, -10))
        let path = NavPathfinder.findPath(in: grid,
                                          from: SIMD3<Float>(-9, 0, -9),   // cell (0,0)
                                          to: SIMD3<Float>(8.5, 0, 8.5))   // cell (9,9)
        #expect(path != nil)
        // First waypoint is the center of cell (0,0): origin + 0.5*cellSize.
        #expect(simd_distance(path!.first!, SIMD3<Float>(-9, 0, -9)) < 1e-4)
        #expect(simd_distance(path!.last!, SIMD3<Float>(9, 0, 9)) < 1e-4)
    }

    @Test("points outside the grid return nil")
    func outsideGrid() {
        let grid = NavGrid(width: 4, depth: 4, cellSize: 1, origin: .zero)
        #expect(grid.cell(at: SIMD3<Float>(-1, 0, 0)) == nil)
        #expect(grid.cell(at: SIMD3<Float>(100, 0, 0)) == nil)
        #expect(NavPathfinder.findPath(in: grid,
                                       from: SIMD3<Float>(-5, 0, 0),
                                       to: SIMD3<Float>(1, 0, 1)) == nil)
    }
}
