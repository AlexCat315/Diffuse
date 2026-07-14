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
        var geometries = runtime.resource(MeshColliderGeometryResource.self)
            ?? MeshColliderGeometryResource()
        for (resourceID, geometry) in geometryByResourceID {
            geometries.geometryByResourceID[resourceID] = geometry
        }
        runtime.setResource(geometries)

        var assets = runtime.resource(DestructibleAssetResource.self)
            ?? DestructibleAssetResource()
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
        connections: [DestructibleConnectionAsset] = []
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

        let fragmentIDs = Set(bakedFragments.map(\.fragmentID))
        var seenConnectionIDs: Set<UInt32> = []
        for connection in connections {
            guard seenConnectionIDs.insert(connection.connectionID).inserted else {
                throw DestructibleAssetBakeError.duplicateConnectionID(connection.connectionID)
            }
            guard connection.fragmentA != connection.fragmentB,
                  fragmentIDs.contains(connection.fragmentA),
                  fragmentIDs.contains(connection.fragmentB) else {
                throw DestructibleAssetBakeError.invalidConnection(
                    connectionID: connection.connectionID
                )
            }
        }

        return DestructibleAssetBakeResult(
            assetResourceID: assetResourceID,
            asset: DestructibleAsset(
                revision: revision,
                fragments: bakedFragments,
                connections: connections
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
        guard input.positions.count >= 4,
              !input.triangleIndices.isEmpty,
              input.triangleIndices.count.isMultiple(of: 3),
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
}
