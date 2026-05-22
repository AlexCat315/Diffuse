import EngineMath
import GuavaUICompose
import RenderBackend
import SceneRuntime
import SIMDCompat

public struct EditorViewportProjection {
    public let camera: RenderCamera
    public let frame: ViewportScreenFrame
    public let viewMatrix: simd_float4x4
    public let projectionMatrix: simd_float4x4
    public let viewProjectionMatrix: simd_float4x4
    public let cameraForward: SIMD3<Float>
    public let cameraRight: SIMD3<Float>
    public let cameraUp: SIMD3<Float>
    public let aspect: Float
    public let tanHalfFov: Float

    public init?(camera: RenderCamera, frame: ViewportScreenFrame) {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let forwardRaw = camera.target - camera.eye
        guard simd_length(forwardRaw) > 1e-5 else { return nil }
        let forward = simd_normalize(forwardRaw)
        let rightRaw = simd_cross(forward, camera.up)
        guard simd_length(rightRaw) > 1e-5 else { return nil }
        let right = simd_normalize(rightRaw)
        let up = simd_normalize(simd_cross(right, forward))
        let aspect = frame.width / frame.height
        let view = CameraMatrices.lookAtRH(eye: camera.eye, target: camera.target, up: up)
        let projection = CameraMatrices.perspectiveRH_ZO(
            fovYRadians: camera.fovYRadians,
            aspect: aspect,
            near: camera.near,
            far: camera.far
        )

        self.camera = camera
        self.frame = frame
        self.viewMatrix = view
        self.projectionMatrix = projection
        self.viewProjectionMatrix = projection * view
        self.cameraForward = forward
        self.cameraRight = right
        self.cameraUp = up
        self.aspect = aspect
        self.tanHalfFov = tanf(camera.fovYRadians * 0.5)
    }

    public func project(_ worldPoint: SIMD3<Float>) -> (x: Float, y: Float)? {
        let clip = viewProjectionMatrix * SIMD4<Float>(worldPoint, 1)
        guard clip.w > 1e-4 else { return nil }
        let ndcX = clip.x / clip.w
        let ndcY = clip.y / clip.w
        let sx = frame.x + (ndcX * 0.5 + 0.5) * frame.width
        let sy = frame.y + (1 - (ndcY * 0.5 + 0.5)) * frame.height
        return (sx, sy)
    }

    public func cursorRay(x: Float, y: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let u = (x - frame.x) / frame.width
        let v = (y - frame.y) / frame.height
        let ndcX = 2 * u - 1
        let ndcY = 1 - 2 * v
        let direction = simd_normalize(
            cameraForward
            + cameraRight * (ndcX * aspect * tanHalfFov)
            + cameraUp * (ndcY * tanHalfFov)
        )
        return (camera.eye, direction)
    }
}
