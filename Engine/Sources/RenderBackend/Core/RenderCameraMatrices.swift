import EngineMath
import SceneRuntime
import SIMDCompat

public extension RenderCamera {
    /// Shared by rendering, editor picking, and transform handles.
    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        switch projection {
        case .perspective:
            return CameraMatrices.perspectiveRH_ZO(fovYRadians: fovYRadians,
                                                   aspect: aspect, near: near, far: far)
        case .orthographic:
            return CameraMatrices.orthographicRH_ZO(
                height: Self.sanitizedOrthographicHeight(orthographicHeight),
                aspect: aspect, near: near, far: far)
        }
    }
}

struct RenderCameraMatrices: Sendable, Equatable {
    var projection: simd_float4x4
    var view: simd_float4x4
    var viewProjection: simd_float4x4

    static func make(scene: RenderScene, drawableSize: RenderDrawableSize) -> RenderCameraMatrices {
        let aspect = Float(max(drawableSize.width, 1)) / Float(max(drawableSize.height, 1))
        let camera = scene.camera
        let projection = camera.projectionMatrix(aspect: aspect)
        let view = CameraMatrices.lookAtRH(eye: camera.eye, target: camera.target, up: camera.up)
        return RenderCameraMatrices(
            projection: projection,
            view: view,
            viewProjection: projection * view
        )
    }
}
