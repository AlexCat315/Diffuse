import simd

public struct Transform3D: Sendable, Equatable {
    public var translation: SIMD3<Float>
    public var rotation: simd_quatf
    public var scale: SIMD3<Float>

    public init(translation: SIMD3<Float> = .zero,
                rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                scale: SIMD3<Float> = SIMD3<Float>(repeating: 1)) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = Transform3D()

    public var matrix: simd_float4x4 {
        MatrixTransforms.translation(translation)
            * simd_float4x4(rotation)
            * MatrixTransforms.scale(scale)
    }
}
