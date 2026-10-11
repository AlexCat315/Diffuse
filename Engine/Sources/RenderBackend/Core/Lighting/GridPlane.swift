import SceneRuntime
import SIMDCompat

/// Axis-aligned reference plane facing an orthographic editor view.
public struct EditorGridPlane {
    public let u: SIMD3<Float>
    public let v: SIMD3<Float>
    public let uAxis: Float
    public let vAxis: Float
    public var normal: SIMD3<Float> { simd_cross(u, v) }

    public static func make(camera: RenderCamera) -> EditorGridPlane {
        let forward = simd_abs(camera.target - camera.eye)
        if camera.projection == .orthographic {
            if forward.z >= forward.x, forward.z >= forward.y {
                return EditorGridPlane(u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 1, 0), uAxis: 0, vAxis: 1)
            }
            if forward.x >= forward.y {
                return EditorGridPlane(u: SIMD3<Float>(0, 0, 1), v: SIMD3<Float>(0, 1, 0), uAxis: 2, vAxis: 1)
            }
        }
        return EditorGridPlane(u: SIMD3<Float>(1, 0, 0), v: SIMD3<Float>(0, 0, 1), uAxis: 0, vAxis: 2)
    }
}
