import Foundation
import SIMDCompat

public enum ClothBendType: UInt8, Sendable, Equatable, Codable, CaseIterable {
    case none
    case distance
    case dihedral
}

/// Grid topology authored for a Jolt soft-body cloth.
public struct Cloth: RuntimeComponent, Sendable, Equatable {
    public var gridSizeX: Int
    public var gridSizeZ: Int
    public var spacing: Float
    public var fixedVertexIndices: [Int]
    public var compliance: Float
    public var shearCompliance: Float
    public var bendCompliance: Float
    public var bendType: ClothBendType

    public init(
        gridSizeX: Int = 16,
        gridSizeZ: Int = 16,
        spacing: Float = 0.2,
        fixedVertexIndices: [Int] = [],
        compliance: Float = 1.0e-5,
        shearCompliance: Float = 1.0e-5,
        bendCompliance: Float = 1.0e-5,
        bendType: ClothBendType = .distance
    ) {
        self.gridSizeX = max(2, min(gridSizeX, 512))
        self.gridSizeZ = max(2, min(gridSizeZ, 512))
        self.spacing = max(0.001, spacing)
        let vertexCount = self.gridSizeX * self.gridSizeZ
        self.fixedVertexIndices = Array(Set(fixedVertexIndices.filter {
            $0 >= 0 && $0 < vertexCount
        })).sorted()
        self.compliance = max(0, compliance)
        self.shearCompliance = max(0, shearCompliance)
        self.bendCompliance = max(0, bendCompliance)
        self.bendType = bendType
    }

    public static func fixedTopEdge(
        gridSizeX: Int = 16,
        gridSizeZ: Int = 16,
        spacing: Float = 0.2
    ) -> Cloth {
        let width = max(2, min(gridSizeX, 512))
        return Cloth(
            gridSizeX: width,
            gridSizeZ: gridSizeZ,
            spacing: spacing,
            fixedVertexIndices: Array(0..<width)
        )
    }

    public var vertexCount: Int { gridSizeX * gridSizeZ }
    public var triangleIndexCount: Int { (gridSizeX - 1) * (gridSizeZ - 1) * 6 }

    public var triangleIndices: [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(triangleIndexCount)
        for z in 0..<(gridSizeZ - 1) {
            for x in 0..<(gridSizeX - 1) {
                let topLeft = UInt32(x + z * gridSizeX)
                let bottomLeft = UInt32(x + (z + 1) * gridSizeX)
                let bottomRight = UInt32(x + 1 + (z + 1) * gridSizeX)
                let topRight = UInt32(x + 1 + z * gridSizeX)
                result.append(contentsOf: [topLeft, bottomLeft, bottomRight,
                                           topLeft, bottomRight, topRight])
            }
        }
        return result
    }
}
