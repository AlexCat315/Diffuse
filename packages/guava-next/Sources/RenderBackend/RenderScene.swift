import Foundation
import simd

/// Renderer-facing scene description for the R2 multi-object stage.
/// One `RenderInstance` = one draw call. `meshIndex` references a mesh
/// previously registered with the renderer's mesh table.
public struct RenderInstance: Sendable {
    public var meshIndex: Int
    public var transform: simd_float4x4

    public init(meshIndex: Int, transform: simd_float4x4) {
        self.meshIndex = meshIndex
        self.transform = transform
    }
}

public struct RenderCamera: Sendable {
    public var eye: SIMD3<Float>
    public var target: SIMD3<Float>
    public var up: SIMD3<Float>
    public var fovYRadians: Float
    public var near: Float
    public var far: Float

    public init(eye: SIMD3<Float>,
                target: SIMD3<Float> = .zero,
                up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                fovYRadians: Float = .pi / 4,
                near: Float = 0.1,
                far: Float = 100.0) {
        self.eye = eye
        self.target = target
        self.up = up
        self.fovYRadians = fovYRadians
        self.near = near
        self.far = far
    }
}

public struct RenderScene: Sendable {
    public var camera: RenderCamera
    public var instances: [RenderInstance]

    public init(camera: RenderCamera, instances: [RenderInstance] = []) {
        self.camera = camera
        self.instances = instances
    }
}
