import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestVector3: Codable, Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ value: SIMD3<Float>) {
        self.init(x: value.x, y: value.y, z: value.z)
    }

    var simdValue: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

public struct EditorSceneManifestVector4: Codable, Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public init(_ value: SIMD4<Float>) {
        self.init(x: value.x, y: value.y, z: value.z, w: value.w)
    }

    var simdValue: SIMD4<Float> {
        SIMD4<Float>(x, y, z, w)
    }
}

public struct EditorSceneManifestMatrix: Codable, Sendable, Equatable {
    public let rows: [Float]

    public init(rows: [Float]) {
        self.rows = rows
    }

    public init(_ matrix: simd_float4x4) {
        let c0 = matrix.columns.0
        let c1 = matrix.columns.1
        let c2 = matrix.columns.2
        let c3 = matrix.columns.3
        self.rows = [
            c0.x, c1.x, c2.x, c3.x,
            c0.y, c1.y, c2.y, c3.y,
            c0.z, c1.z, c2.z, c3.z,
            c0.w, c1.w, c2.w, c3.w,
        ]
    }

    var simdValue: simd_float4x4? {
        guard rows.count == 16 else { return nil }
        return simd_float4x4(rows: [
            SIMD4<Float>(rows[0], rows[1], rows[2], rows[3]),
            SIMD4<Float>(rows[4], rows[5], rows[6], rows[7]),
            SIMD4<Float>(rows[8], rows[9], rows[10], rows[11]),
            SIMD4<Float>(rows[12], rows[13], rows[14], rows[15]),
        ])
    }

    var localTransform: LocalTransform? {
        simdValue.map(LocalTransform.init(matrix:))
    }
}
