import EngineKernel
import SIMDCompat

/// A uniform navigation grid laid out on the XZ plane (Y is up). Cell `(0,0)` starts at
/// `origin` (its minimum corner); each cell is `cellSize` on a side. Cells are walkable by
/// default and can be individually blocked. Pathfinding runs over this grid via `NavPathfinder`.
public struct NavGrid: Sendable, Equatable {
    public let width: Int   // cell count along +X
    public let depth: Int   // cell count along +Z
    public let cellSize: Float
    public let origin: SIMD3<Float>
    private var blocked: [Bool]

    public init(width: Int, depth: Int, cellSize: Float = 1, origin: SIMD3<Float> = .zero) {
        self.width = max(0, width)
        self.depth = max(0, depth)
        self.cellSize = cellSize > 0 ? cellSize : 1
        self.origin = origin
        self.blocked = Array(repeating: false, count: self.width * self.depth)
    }

    public var cellCount: Int { width * depth }

    public func inBounds(x: Int, z: Int) -> Bool {
        x >= 0 && x < width && z >= 0 && z < depth
    }

    public func isWalkable(x: Int, z: Int) -> Bool {
        inBounds(x: x, z: z) && !blocked[z * width + x]
    }

    public mutating func setBlocked(x: Int, z: Int, _ value: Bool = true) {
        guard inBounds(x: x, z: z) else { return }
        blocked[z * width + x] = value
    }

    /// Blocks the cell containing `worldPosition`, if it falls inside the grid.
    public mutating func blockCell(at worldPosition: SIMD3<Float>) {
        if let c = cell(at: worldPosition) { setBlocked(x: c.x, z: c.z, true) }
    }

    /// World-space center of cell `(x,z)`. Y matches the grid origin.
    public func cellCenter(x: Int, z: Int) -> SIMD3<Float> {
        SIMD3<Float>(origin.x + (Float(x) + 0.5) * cellSize,
                     origin.y,
                     origin.z + (Float(z) + 0.5) * cellSize)
    }

    /// Cell containing `worldPosition`, or nil if it lies outside the grid (XZ only).
    public func cell(at worldPosition: SIMD3<Float>) -> (x: Int, z: Int)? {
        let lx = worldPosition.x - origin.x
        let lz = worldPosition.z - origin.z
        guard lx >= 0, lz >= 0 else { return nil }
        let cx = Int(lx / cellSize)
        let cz = Int(lz / cellSize)
        return inBounds(x: cx, z: cz) ? (cx, cz) : nil
    }
}

/// A* pathfinding over a `NavGrid`.
public enum NavPathfinder {
    public struct Cell: Hashable, Sendable {
        public var x: Int
        public var z: Int
        public init(_ x: Int, _ z: Int) { self.x = x; self.z = z }
    }

    /// Finds a path between two grid cells. Returns the cell sequence from `start` to `goal`
    /// inclusive, or nil if either cell is blocked/out of bounds or no route exists.
    /// Diagonal moves are allowed when `allowDiagonal` is true and never cut blocked corners.
    public static func findPath(in grid: NavGrid,
                                from start: Cell,
                                to goal: Cell,
                                allowDiagonal: Bool = true) -> [Cell]? {
        guard grid.isWalkable(x: start.x, z: start.z),
              grid.isWalkable(x: goal.x, z: goal.z) else { return nil }
        if start == goal { return [start] }

        let sqrt2: Float = 1.41421356
        var gScore: [Cell: Float] = [start: 0]
        var cameFrom: [Cell: Cell] = [:]
        var open = MinHeap()
        open.push(start, priority: heuristic(start, goal, allowDiagonal: allowDiagonal))
        var closed: Set<Cell> = []

        while let current = open.pop() {
            if current == goal { return reconstruct(cameFrom, goal: goal) }
            if closed.contains(current) { continue }
            closed.insert(current)

            let baseG = gScore[current] ?? .greatestFiniteMagnitude
            for (neighbor, step) in neighbors(of: current, in: grid, allowDiagonal: allowDiagonal) {
                if closed.contains(neighbor) { continue }
                let tentative = baseG + (step ? sqrt2 : 1)
                if tentative < (gScore[neighbor] ?? .greatestFiniteMagnitude) {
                    gScore[neighbor] = tentative
                    cameFrom[neighbor] = current
                    open.push(neighbor, priority: tentative + heuristic(neighbor, goal, allowDiagonal: allowDiagonal))
                }
            }
        }
        return nil
    }

    /// World-space convenience: resolves `from`/`to` to cells and returns the path as
    /// cell-center waypoints. Returns nil if either point lies outside the grid or no route exists.
    public static func findPath(in grid: NavGrid,
                                from: SIMD3<Float>,
                                to: SIMD3<Float>,
                                allowDiagonal: Bool = true) -> [SIMD3<Float>]? {
        guard let s = grid.cell(at: from), let g = grid.cell(at: to) else { return nil }
        guard let cells = findPath(in: grid, from: Cell(s.x, s.z), to: Cell(g.x, g.z),
                                   allowDiagonal: allowDiagonal) else { return nil }
        return cells.map { grid.cellCenter(x: $0.x, z: $0.z) }
    }

    // MARK: - Internals

    private static func heuristic(_ a: Cell, _ b: Cell, allowDiagonal: Bool) -> Float {
        let dx = abs(a.x - b.x), dz = abs(a.z - b.z)
        if allowDiagonal {
            // Octile distance — admissible for 8-connected grids.
            let m = min(dx, dz)
            return Float(dx + dz) + (1.41421356 - 2) * Float(m)
        }
        return Float(dx + dz) // Manhattan
    }

    private static func neighbors(of c: Cell, in grid: NavGrid, allowDiagonal: Bool) -> [(Cell, diagonal: Bool)] {
        var result: [(Cell, Bool)] = []
        let orthogonal = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        for (dx, dz) in orthogonal where grid.isWalkable(x: c.x + dx, z: c.z + dz) {
            result.append((Cell(c.x + dx, c.z + dz), false))
        }
        guard allowDiagonal else { return result }
        let diagonal = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
        for (dx, dz) in diagonal where grid.isWalkable(x: c.x + dx, z: c.z + dz) {
            // No corner cutting: both shared orthogonal cells must be open.
            if grid.isWalkable(x: c.x + dx, z: c.z) && grid.isWalkable(x: c.x, z: c.z + dz) {
                result.append((Cell(c.x + dx, c.z + dz), true))
            }
        }
        return result
    }

    private static func reconstruct(_ cameFrom: [Cell: Cell], goal: Cell) -> [Cell] {
        var path = [goal]
        var node = goal
        while let prev = cameFrom[node] {
            path.append(prev)
            node = prev
        }
        return path.reversed()
    }

    /// Minimal binary min-heap keyed by priority. Stale entries (a cell pushed again with a
    /// lower priority) are tolerated via the `closed` set in the search loop.
    private struct MinHeap {
        private var items: [(cell: Cell, priority: Float)] = []

        mutating func push(_ cell: Cell, priority: Float) {
            items.append((cell, priority))
            siftUp(items.count - 1)
        }

        mutating func pop() -> Cell? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            if !items.isEmpty { siftDown(0) }
            return top.cell
        }

        private mutating func siftUp(_ index: Int) {
            var i = index
            while i > 0 {
                let parent = (i - 1) / 2
                if items[i].priority >= items[parent].priority { break }
                items.swapAt(i, parent)
                i = parent
            }
        }

        private mutating func siftDown(_ index: Int) {
            var i = index
            let count = items.count
            while true {
                let left = 2 * i + 1, right = 2 * i + 2
                var smallest = i
                if left < count && items[left].priority < items[smallest].priority { smallest = left }
                if right < count && items[right].priority < items[smallest].priority { smallest = right }
                if smallest == i { break }
                items.swapAt(i, smallest)
                i = smallest
            }
        }
    }
}
