import EngineMath
import SceneRuntime
import simd

struct RenderCameraMatrices: Sendable, Equatable {
    var projection: simd_float4x4
    var view: simd_float4x4
    var viewProjection: simd_float4x4

    static func make(scene: RenderScene, drawableSize: RenderDrawableSize) -> RenderCameraMatrices {
        let aspect = Float(max(drawableSize.width, 1)) / Float(max(drawableSize.height, 1))
        let camera = scene.camera
        let projection = CameraMatrices.perspectiveRH_ZO(
            fovYRadians: camera.fovYRadians,
            aspect: aspect,
            near: camera.near,
            far: camera.far
        )
        let view = CameraMatrices.lookAtRH(eye: camera.eye, target: camera.target, up: camera.up)
        return RenderCameraMatrices(
            projection: projection,
            view: view,
            viewProjection: projection * view
        )
    }
}
