import Foundation
import SceneRuntime
import SIMDCompat

public struct PrefracturedFragmentInput: Sendable, Equatable {
    public var fragmentID: UInt32
    public var positions: [SIMD3<Float>]
    public var triangleIndices: [UInt32]
    public var localTransform: LocalTransform
    public var density: Float
    public var geometryRevision: UInt64
    public var renderMesh: RenderMeshComponent?
    public var renderMaterial: RenderMaterialComponent?

    public init(
        fragmentID: UInt32,
        positions: [SIMD3<Float>],
        triangleIndices: [UInt32],
        localTransform: LocalTransform = .identity,
        density: Float = 1,
        geometryRevision: UInt64 = 0,
        renderMesh: RenderMeshComponent? = nil,
        renderMaterial: RenderMaterialComponent? = nil
    ) {
        self.fragmentID = fragmentID
        self.positions = positions
        self.triangleIndices = triangleIndices
        self.localTransform = localTransform
        self.density = density
        self.geometryRevision = geometryRevision
        self.renderMesh = renderMesh
        self.renderMaterial = renderMaterial
    }
}

public enum DestructibleAssetBakeError: Error, Sendable, Equatable {
    case emptyAssetResourceID
    case noFragments
    case duplicateFragmentID(UInt32)
    case invalidDensity(fragmentID: UInt32)
    case invalidGeometry(fragmentID: UInt32)
    case nonClosedGeometry(fragmentID: UInt32)
    case duplicateConnectionID(UInt32)
    case invalidConnection(connectionID: UInt32)
    case disconnectedConnectionGraph(fragmentIDs: [UInt32])
    case invalidConnectionTolerance
}

public struct DestructibleAssetBakeResult: Sendable, Equatable {
    public var assetResourceID: String
    public var asset: DestructibleAsset
    public var geometryByResourceID: [String: MeshColliderGeometry]

    public init(
        assetResourceID: String,
        asset: DestructibleAsset,
        geometryByResourceID: [String: MeshColliderGeometry]
    ) {
        self.assetResourceID = assetResourceID
        self.asset = asset
        self.geometryByResourceID = geometryByResourceID
    }

    /// Installs or replaces this bake atomically at the resource level. Existing
    /// unrelated geometry and destructible assets are preserved.
    public func install(into runtime: inout SceneRuntime) {
        var assets = runtime.resource(DestructibleAssetResource.self)
            ?? DestructibleAssetResource()
        var geometries = runtime.resource(MeshColliderGeometryResource.self)
            ?? MeshColliderGeometryResource()
        let replacementGeometryIDs = Set(geometryByResourceID.keys)
        if let previous = assets.assetsByResourceID[assetResourceID] {
            let ownedPrefix = "\(assetResourceID)#convex:"
            for fragment in previous.fragments
            where fragment.colliderResourceID.hasPrefix(ownedPrefix)
                && !replacementGeometryIDs.contains(fragment.colliderResourceID) {
                geometries.geometryByResourceID.removeValue(
                    forKey: fragment.colliderResourceID
                )
            }
        }
        for (resourceID, geometry) in geometryByResourceID {
            geometries.geometryByResourceID[resourceID] = geometry
        }
        runtime.setResource(geometries)

        assets.assetsByResourceID[assetResourceID] = asset
        runtime.setResource(assets)
    }
}

public struct DestructibleAssetBaker: Sendable {
    public init() {}

    public func bake(
        assetResourceID: String,
        revision: UInt64 = 0,
        fragments: [PrefracturedFragmentInput],
        connections: [DestructibleConnectionAsset] = [],
        automaticallyGenerateConnections: Bool = true,
        connectionTolerance: Float = 0.001
    ) throws -> DestructibleAssetBakeResult {
        guard !assetResourceID.isEmpty else {
            throw DestructibleAssetBakeError.emptyAssetResourceID
        }
        guard !fragments.isEmpty else {
            throw DestructibleAssetBakeError.noFragments
        }

        var seenFragmentIDs: Set<UInt32> = []
        var bakedFragments: [DestructibleFragmentAsset] = []
        var geometries: [String: MeshColliderGeometry] = [:]
        bakedFragments.reserveCapacity(fragments.count)
        geometries.reserveCapacity(fragments.count)

        for input in fragments.sorted(by: { $0.fragmentID < $1.fragmentID }) {
            guard seenFragmentIDs.insert(input.fragmentID).inserted else {
                throw DestructibleAssetBakeError.duplicateFragmentID(input.fragmentID)
            }
            guard input.density.isFinite, input.density > 0 else {
                throw DestructibleAssetBakeError.invalidDensity(fragmentID: input.fragmentID)
            }
            guard isValidGeometry(input) else {
                throw DestructibleAssetBakeError.invalidGeometry(fragmentID: input.fragmentID)
            }
            let volume = signedMeshVolume(
                positions: input.positions,
                triangleIndices: input.triangleIndices
            )
            guard isClosedTriangleMesh(input.triangleIndices),
                  volume.isFinite,
                  volume > 1.0e-8 else {
                throw DestructibleAssetBakeError.nonClosedGeometry(fragmentID: input.fragmentID)
            }
            let geometryResourceID = Self.geometryResourceID(
                assetResourceID: assetResourceID,
                fragmentID: input.fragmentID
            )
            geometries[geometryResourceID] = MeshColliderGeometry(
                positions: input.positions,
                triangleIndices: input.triangleIndices,
                revision: input.geometryRevision
            )
            bakedFragments.append(DestructibleFragmentAsset(
                fragmentID: input.fragmentID,
                colliderResourceID: geometryResourceID,
                localTransform: input.localTransform,
                mass: volume * input.density,
                renderMesh: input.renderMesh,
                renderMaterial: input.renderMaterial
            ))
        }

        let finalConnections: [DestructibleConnectionAsset]
        if connections.isEmpty, automaticallyGenerateConnections {
            guard connectionTolerance.isFinite, connectionTolerance >= 0 else {
                throw DestructibleAssetBakeError.invalidConnectionTolerance
            }
            finalConnections = generateConnections(
                fragments: fragments,
                tolerance: connectionTolerance
            )
        } else {
            finalConnections = connections
        }

        let fragmentIDs = Set(bakedFragments.map(\.fragmentID))
        var seenConnectionIDs: Set<UInt32> = []
        for connection in finalConnections {
            guard seenConnectionIDs.insert(connection.connectionID).inserted else {
                throw DestructibleAssetBakeError.duplicateConnectionID(connection.connectionID)
            }
            guard connection.fragmentA != connection.fragmentB,
                  fragmentIDs.contains(connection.fragmentA),
                  fragmentIDs.contains(connection.fragmentB),
                  connection.damageThreshold.isFinite,
                  connection.damageThreshold >= 0,
                  connection.impulseThreshold.isFinite,
                  connection.impulseThreshold >= 0 else {
                throw DestructibleAssetBakeError.invalidConnection(
                    connectionID: connection.connectionID
                )
            }
        }
        if !finalConnections.isEmpty {
            let disconnected = disconnectedFragmentIDs(
                fragmentIDs: bakedFragments.map(\.fragmentID),
                connections: finalConnections
            )
            guard disconnected.isEmpty else {
                throw DestructibleAssetBakeError.disconnectedConnectionGraph(
                    fragmentIDs: disconnected
                )
            }
        }

        return DestructibleAssetBakeResult(
            assetResourceID: assetResourceID,
            asset: DestructibleAsset(
                revision: revision,
                fragments: bakedFragments,
                connections: finalConnections
            ),
            geometryByResourceID: geometries
        )
    }

    public static func geometryResourceID(
        assetResourceID: String,
        fragmentID: UInt32
    ) -> String {
        "\(assetResourceID)#convex:\(fragmentID)"
    }

    private func isValidGeometry(_ input: PrefracturedFragmentInput) -> Bool {
        let transformColumns = [
            input.localTransform.matrix.columns.0,
            input.localTransform.matrix.columns.1,
            input.localTransform.matrix.columns.2,
            input.localTransform.matrix.columns.3,
        ]
        guard input.positions.count >= 4,
              !input.triangleIndices.isEmpty,
              input.triangleIndices.count.isMultiple(of: 3),
              transformColumns.allSatisfy({ column in
                  column.x.isFinite && column.y.isFinite
                      && column.z.isFinite && column.w.isFinite
              }),
              input.positions.allSatisfy({
                  $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
              }) else { return false }
        guard input.triangleIndices.allSatisfy({ Int($0) < input.positions.count }) else {
            return false
        }
        for triangle in stride(from: 0, to: input.triangleIndices.count, by: 3) {
            let a = input.triangleIndices[triangle]
            let b = input.triangleIndices[triangle + 1]
            let c = input.triangleIndices[triangle + 2]
            guard a != b, b != c, c != a else { return false }
            let edgeAB = input.positions[Int(b)] - input.positions[Int(a)]
            let edgeAC = input.positions[Int(c)] - input.positions[Int(a)]
            guard simd_length_squared(simd_cross(edgeAB, edgeAC)) > 1.0e-12 else {
                return false
            }
        }
        return true
    }

    private func isClosedTriangleMesh(_ triangleIndices: [UInt32]) -> Bool {
        var edges: [UInt64: (count: Int, orientation: Int)] = [:]
        for triangle in stride(from: 0, to: triangleIndices.count, by: 3) {
            let vertices = [
                triangleIndices[triangle],
                triangleIndices[triangle + 1],
                triangleIndices[triangle + 2],
            ]
            for edgeIndex in 0..<3 {
                let start = vertices[edgeIndex]
                let end = vertices[(edgeIndex + 1) % 3]
                let lower = min(start, end)
                let upper = max(start, end)
                let key = UInt64(lower) << 32 | UInt64(upper)
                var edge = edges[key] ?? (count: 0, orientation: 0)
                edge.count += 1
                edge.orientation += start < end ? 1 : -1
                edges[key] = edge
            }
        }
        return !edges.isEmpty && edges.values.allSatisfy {
            $0.count == 2 && $0.orientation == 0
        }
    }

    private func signedMeshVolume(
        positions: [SIMD3<Float>],
        triangleIndices: [UInt32]
    ) -> Float {
        var signedSixVolume: Double = 0
        for triangle in stride(from: 0, to: triangleIndices.count, by: 3) {
            let a = positions[Int(triangleIndices[triangle])]
            let b = positions[Int(triangleIndices[triangle + 1])]
            let c = positions[Int(triangleIndices[triangle + 2])]
            signedSixVolume += Double(simd_dot(a, simd_cross(b, c)))
        }
        return Float(abs(signedSixVolume) / 6)
    }

    /// Builds a stable import-time graph from fragments whose transformed surfaces are
    /// within `tolerance`. Explicit `connections` passed to `bake` take precedence.
    private func generateConnections(
        fragments: [PrefracturedFragmentInput],
        tolerance: Float
    ) -> [DestructibleConnectionAsset] {
        struct Surface {
            var fragmentID: UInt32
            var positions: [SIMD3<Float>]
            var triangleIndices: [UInt32]
            var minimum: SIMD3<Float>
            var maximum: SIMD3<Float>
        }

        let surfaces = fragments
            .sorted { $0.fragmentID < $1.fragmentID }
            .map { fragment -> Surface in
                let matrix = fragment.localTransform.matrix
                let positions = fragment.positions.map { position in
                    let transformed = matrix * SIMD4<Float>(position.x, position.y, position.z, 1)
                    return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
                }
                var minimum = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
                var maximum = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
                for position in positions {
                    minimum = SIMD3<Float>(
                        min(minimum.x, position.x),
                        min(minimum.y, position.y),
                        min(minimum.z, position.z)
                    )
                    maximum = SIMD3<Float>(
                        max(maximum.x, position.x),
                        max(maximum.y, position.y),
                        max(maximum.z, position.z)
                    )
                }
                return Surface(
                    fragmentID: fragment.fragmentID,
                    positions: positions,
                    triangleIndices: fragment.triangleIndices,
                    minimum: minimum,
                    maximum: maximum
                )
            }

        var result: [DestructibleConnectionAsset] = []
        for firstIndex in surfaces.indices {
            guard firstIndex + 1 < surfaces.count else { continue }
            for secondIndex in (firstIndex + 1)..<surfaces.count {
                let first = surfaces[firstIndex]
                let second = surfaces[secondIndex]
                guard aabbSquaredDistance(
                    minimumA: first.minimum,
                    maximumA: first.maximum,
                    minimumB: second.minimum,
                    maximumB: second.maximum
                ) <= tolerance * tolerance,
                surfacesAreAdjacent(
                    positionsA: first.positions,
                    trianglesA: first.triangleIndices,
                    positionsB: second.positions,
                    trianglesB: second.triangleIndices,
                    toleranceSquared: tolerance * tolerance
                ) else { continue }

                result.append(DestructibleConnectionAsset(
                    connectionID: UInt32(result.count),
                    fragmentA: first.fragmentID,
                    fragmentB: second.fragmentID
                ))
            }
        }
        return result
    }

    private func aabbSquaredDistance(
        minimumA: SIMD3<Float>,
        maximumA: SIMD3<Float>,
        minimumB: SIMD3<Float>,
        maximumB: SIMD3<Float>
    ) -> Float {
        let separation = SIMD3<Float>(
            max(0, max(minimumA.x - maximumB.x, minimumB.x - maximumA.x)),
            max(0, max(minimumA.y - maximumB.y, minimumB.y - maximumA.y)),
            max(0, max(minimumA.z - maximumB.z, minimumB.z - maximumA.z))
        )
        return simd_length_squared(separation)
    }

    private func disconnectedFragmentIDs(
        fragmentIDs: [UInt32],
        connections: [DestructibleConnectionAsset]
    ) -> [UInt32] {
        guard let root = fragmentIDs.min() else { return [] }
        var adjacency: [UInt32: [UInt32]] = [:]
        for connection in connections.sorted(by: { $0.connectionID < $1.connectionID }) {
            adjacency[connection.fragmentA, default: []].append(connection.fragmentB)
            adjacency[connection.fragmentB, default: []].append(connection.fragmentA)
        }
        var visited: Set<UInt32> = [root]
        var queue = [root]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            for neighbor in (adjacency[current] ?? []).sorted()
            where visited.insert(neighbor).inserted {
                queue.append(neighbor)
            }
        }
        return fragmentIDs.sorted().filter { !visited.contains($0) }
    }

    private func surfacesAreAdjacent(
        positionsA: [SIMD3<Float>],
        trianglesA: [UInt32],
        positionsB: [SIMD3<Float>],
        trianglesB: [UInt32],
        toleranceSquared: Float
    ) -> Bool {
        points(positionsA, areWithin: toleranceSquared, of: positionsB, trianglesB)
            || points(positionsB, areWithin: toleranceSquared, of: positionsA, trianglesA)
    }

    private func points(
        _ points: [SIMD3<Float>],
        areWithin toleranceSquared: Float,
        of positions: [SIMD3<Float>],
        _ triangleIndices: [UInt32]
    ) -> Bool {
        for point in points {
            for triangle in stride(from: 0, to: triangleIndices.count, by: 3) {
                let a = positions[Int(triangleIndices[triangle])]
                let b = positions[Int(triangleIndices[triangle + 1])]
                let c = positions[Int(triangleIndices[triangle + 2])]
                if pointTriangleSquaredDistance(point, a, b, c) <= toleranceSquared {
                    return true
                }
            }
        }
        return false
    }

    /// Closest-point regions from Real-Time Collision Detection, kept local to the
    /// importer so runtime physics does not participate in asset graph generation.
    private func pointTriangleSquaredDistance(
        _ point: SIMD3<Float>,
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) -> Float {
        let ab = b - a
        let ac = c - a
        let ap = point - a
        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0, d2 <= 0 { return simd_length_squared(ap) }

        let bp = point - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0, d4 <= d3 { return simd_length_squared(bp) }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            return simd_length_squared(point - (a + v * ab))
        }

        let cp = point - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0, d5 <= d6 { return simd_length_squared(cp) }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            return simd_length_squared(point - (a + w * ac))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let edge = c - b
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length_squared(point - (b + w * edge))
        }

        let denominator = 1 / (va + vb + vc)
        let v = vb * denominator
        let w = vc * denominator
        return simd_length_squared(point - (a + ab * v + ac * w))
    }
}
