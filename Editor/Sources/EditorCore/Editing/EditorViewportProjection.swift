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

/// Production framing policy shared by every "Frame Selected" entry point.
///
/// The policy fits a conservative bounding sphere around the complete world
/// AABB. A sphere keeps the result stable as the camera rotates and lets the
/// narrower of the horizontal and vertical fields of view drive the distance.
public enum EditorViewportFraming {
    public struct Pose: Sendable, Equatable {
        public var eye: SIMD3<Float>
        public var target: SIMD3<Float>

        public init(eye: SIMD3<Float>, target: SIMD3<Float>) {
            self.eye = eye
            self.target = target
        }
    }

    public static func pose(camera: RenderCamera,
                            boundsMin: SIMD3<Float>,
                            boundsMax: SIMD3<Float>,
                            viewportAspectRatio: Float? = nil,
                            padding: Float = 1.3) -> Pose {
        let lower = simd_min(boundsMin, boundsMax)
        let upper = simd_max(boundsMin, boundsMax)
        let target = (lower + upper) * 0.5
        let halfExtents = (upper - lower) * 0.5
        let radius = max(0.25, simd_length(halfExtents))

        let requestedAspect = viewportAspectRatio ?? camera.aspectRatio
        let aspect = requestedAspect.isFinite ? max(0.05, requestedAspect) : 1
        let requestedHalfFOV = camera.fovYRadians * 0.5
        let verticalHalfFOV = min(Float.pi * 0.49,
                                  max(Float.pi / 180 * 2.5, requestedHalfFOV))
        let horizontalHalfFOV = atanf(tanf(verticalHalfFOV) * aspect)
        let limitingHalfFOV = max(Float.pi / 180 * 2.5,
                                  min(verticalHalfFOV, horizontalHalfFOV))
        let safePadding = padding.isFinite ? max(1, padding) : 1.3
        let fittedDistance = radius / max(0.04, sinf(limitingHalfFOV)) * safePadding
        let distance = max(0.5,
                           radius + max(0.05, camera.near * 2),
                           fittedDistance)

        var backward = camera.eye - camera.target
        if !backward.x.isFinite || !backward.y.isFinite || !backward.z.isFinite
            || simd_length(backward) < 1e-5 {
            backward = SIMD3<Float>(0, 0.25, 1)
        }
        backward = simd_normalize(backward)
        return Pose(eye: target + backward * distance, target: target)
    }
}
